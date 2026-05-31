```dart
// ============================
// 100Hz 科研级 BLE Manager
// 固定100Hz采样
// 压力25Hz线性插值
// Stopwatch时间轴
// 四模块同步
// ============================

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../models/gait_data.dart';

class BleUuids {
  static final Guid pressureService =
      Guid('0000FFE0-0000-1000-8000-00805F9B34FB');

  static final Guid pressureNotify =
      Guid('0000FFE1-0000-1000-8000-00805F9B34FB');

  static final Guid imuService =
      Guid('0000FFE5-0000-1000-8000-00805F9A34FB');

  static final Guid imuNotify =
      Guid('0000FFE4-0000-1000-8000-00805F9A34FB');

  static final Guid imuWrite =
      Guid('0000FFE9-0000-1000-8000-00805F9A34FB');
}

class DeviceContext {
  DeviceRole role;

  BluetoothDevice? device;

  ConnectionStatus status =
      ConnectionStatus.disconnected;

  StreamSubscription<
      BluetoothConnectionState>? connSub;

  StreamSubscription<List<int>>? notifySub;

  PressureData pressure = PressureData();

  ImuData imu = ImuData();

  final List<int> imuBuf = [];

  String pressureBuf = '';

  String deviceName = '';

  String deviceId = '';

  DateTime? lastUpdate;

  int dataPacketsProcessed = 0;

  DeviceContext(this.role);

  void resetData() {
    pressure = PressureData();
    imu = ImuData();

    imuBuf.clear();

    pressureBuf = '';

    dataPacketsProcessed = 0;
  }
}

class BleManager extends ChangeNotifier {

  // =========================
  // Context
  // =========================

  final Map<DeviceRole, DeviceContext>
      _contexts = {

    DeviceRole.pressureLeft:
        DeviceContext(
            DeviceRole.pressureLeft),

    DeviceRole.pressureRight:
        DeviceContext(
            DeviceRole.pressureRight),

    DeviceRole.imuLeft:
        DeviceContext(
            DeviceRole.imuLeft),

    DeviceRole.imuRight:
        DeviceContext(
            DeviceRole.imuRight),
  };

  DeviceContext getContext(
      DeviceRole role) =>
      _contexts[role]!;

  // =========================
  // Scan
  // =========================

  final List<ScanResult>
      _scanResults = [];

  bool _scanning = false;

  StreamSubscription<
      List<ScanResult>>? _scanSub;

  bool get isScanning => _scanning;

  List<ScanResult> get scanResults =>
      List.unmodifiable(_scanResults);

  // =========================
  // Record
  // =========================

  bool _recording = false;

  bool get isRecording => _recording;

  final List<GaitRecord>
      _records = [];

  List<GaitRecord> get records =>
      List.unmodifiable(_records);

  int get recordCount =>
      _records.length;

  String _currentLabel = '0';

  String get currentLabel =>
      _currentLabel;

  // =========================
  // Fixed 100Hz
  // =========================

  Timer? _sampleTimer;

  late Stopwatch _recordWatch;

  late DateTime _recordStartTime;

  int _sampleIndex = 0;

  // =========================
  // UI Refresh
  // =========================

  final Map<DeviceRole, DateTime>
      _lastNotifyTime = {};

  static const Duration
      _notifyThrottle =
      Duration(milliseconds: 50);

  // =========================
  // Data Queue
  // =========================

  final Map<
      DeviceRole,
      Queue<Map<String, dynamic>>>
      _dataQueue = {

    for (final role in DeviceRole.values)
      role: Queue<Map<String, dynamic>>(),
  };

  Timer? _dataProcessTimer;

  static const Duration
      _processingInterval =
      Duration(milliseconds: 5);

  // =========================
  // Pressure Interpolation
  // =========================

  PressureData _prevPressureLeft =
      PressureData();

  PressureData _currPressureLeft =
      PressureData();

  PressureData _prevPressureRight =
      PressureData();

  PressureData _currPressureRight =
      PressureData();

  DateTime? _prevPressureLeftTime;

  DateTime? _currPressureLeftTime;

  DateTime? _prevPressureRightTime;

  DateTime? _currPressureRightTime;

  // =========================
  // Constructor
  // =========================

  BleManager() {
    for (final role
        in DeviceRole.values) {

      _lastNotifyTime[role] =
          DateTime.now();
    }
  }

  // =========================
  // Scan
  // =========================

  Future<void> startScan({
    int timeoutSec = 10,
  }) async {

    if (_scanning) return;

    _scanResults.clear();

    _scanning = true;

    notifyListeners();

    try {

      if (await FlutterBluePlus
              .isSupported ==
          false) {

        debugPrint(
            '[BLE] 不支持蓝牙');

        return;
      }

      await _scanSub?.cancel();

      _scanSub =
          FlutterBluePlus.scanResults
              .listen((results) {

        _scanResults
          ..clear()
          ..addAll(results);

        notifyListeners();

      });

      await FlutterBluePlus.startScan(
        timeout:
            Duration(seconds: timeoutSec),
        androidUsesFineLocation:
            true,
      );

      await Future.delayed(
          Duration(seconds: timeoutSec));

    } catch (e) {

      debugPrint(
          '[BLE] 扫描失败: $e');

    } finally {

      _scanning = false;

      await _scanSub?.cancel();

      _scanSub = null;

      notifyListeners();
    }
  }

  Future<void> stopScan() async {

    try {

      await FlutterBluePlus.stopScan();

    } catch (_) {}

    _scanning = false;

    await _scanSub?.cancel();

    _scanSub = null;

    notifyListeners();
  }

  // =========================
  // Connect
  // =========================

  Future<bool> connectDevice(
      BluetoothDevice device,
      DeviceRole role) async {

    final ctx = _contexts[role]!;

    try {

      ctx.device = device;

      ctx.status =
          ConnectionStatus.connecting;

      notifyListeners();

      await device.connect(
        timeout:
            const Duration(seconds: 15),
        autoConnect: false,
      );

      try {
        await device.requestMtu(247);
      } catch (_) {}

      final services =
          await device.discoverServices();

      if (role.isPressure) {

        await _setupPressure(
            ctx,
            services);

      } else {

        await _setupIMU(
            ctx,
            services);
      }

      ctx.status =
          ConnectionStatus.connected;

      notifyListeners();

      _startDataProcessor();

      return true;

    } catch (e) {

      debugPrint(
          '[BLE] 连接失败: $e');

      ctx.status =
          ConnectionStatus.failed;

      notifyListeners();

      return false;
    }
  }

  // =========================
  // Setup Pressure
  // =========================

  Future<void> _setupPressure(
      DeviceContext ctx,
      List<BluetoothService>
          services) async {

    BluetoothCharacteristic?
        notifyChar;

    for (final s in services) {

      if (s.uuid.str
          .toUpperCase()
          .contains('FFE0')) {

        for (final c
            in s.characteristics) {

          if (c.uuid.str
                  .toUpperCase()
                  .contains('FFE1') &&
              c.properties.notify) {

            notifyChar = c;

            break;
          }
        }
      }
    }

    if (notifyChar == null) {
      throw Exception(
          '压力Notify不存在');
    }

    await notifyChar.setNotifyValue(true);

    ctx.notifySub =
        notifyChar.lastValueStream
            .listen((data) {

      _queuePressureData(
          ctx,
          data);
    });
  }

  // =========================
  // Setup IMU
  // =========================

  Future<void> _setupIMU(
      DeviceContext ctx,
      List<BluetoothService>
          services) async {

    BluetoothCharacteristic?
        notifyChar;

    for (final s in services) {

      if (s.uuid.str
          .toUpperCase()
          .contains('FFE5')) {

        for (final c
            in s.characteristics) {

          if (c.uuid.str
                  .toUpperCase()
                  .contains('FFE4') &&
              c.properties.notify) {

            notifyChar = c;

            break;
          }
        }
      }
    }

    if (notifyChar == null) {
      throw Exception(
          'IMU Notify不存在');
    }

    await notifyChar.setNotifyValue(true);

    ctx.notifySub =
        notifyChar.lastValueStream
            .listen((data) {

      _queueImuData(
          ctx,
          data);
    });
  }

  // =========================
  // Queue
  // =========================

  void _queuePressureData(
      DeviceContext ctx,
      List<int> data) {

    final queue =
        _dataQueue[ctx.role]!;

    if (queue.length < 500) {

      queue.add({
        'type': 'pressure',
        'data': data,
      });
    }
  }

  void _queueImuData(
      DeviceContext ctx,
      List<int> data) {

    final queue =
        _dataQueue[ctx.role]!;

    if (queue.length < 500) {

      queue.add({
        'type': 'imu',
        'data': data,
      });
    }
  }

  // =========================
  // Data Processor
  // =========================

  void _startDataProcessor() {

    _dataProcessTimer ??=
        Timer.periodic(
      _processingInterval,
      (_) {

        _processAllDataQueues();
      },
    );
  }

  void _processAllDataQueues() {

    bool shouldNotify = false;

    for (final role
        in DeviceRole.values) {

      final queue =
          _dataQueue[role]!;

      final ctx =
          _contexts[role]!;

      while (queue.isNotEmpty) {

        final item =
            queue.removeFirst();

        final data =
            item['data']
                as List<int>;

        if (item['type']
            == 'pressure') {

          _handlePressureData(
              ctx,
              data);

        } else {

          _handleImuData(
              ctx,
              data);
        }
      }

      final now =
          DateTime.now();

      final last =
          _lastNotifyTime[role]!;

      if (now.difference(last) >=
          _notifyThrottle) {

        _lastNotifyTime[role] =
            now;

        shouldNotify = true;
      }
    }

    if (shouldNotify) {
      notifyListeners();
    }
  }

  // =========================
  // Pressure Parse
  // =========================

  void _handlePressureData(
      DeviceContext ctx,
      List<int> data) {

    try {

      final text =
          ascii.decode(
        data,
        allowInvalid: true,
      );

      ctx.pressureBuf += text;

      int start = 0;

      while (start <
          ctx.pressureBuf.length) {

        final dollarIdx =
            ctx.pressureBuf.indexOf(
                r'$',
                start);

        if (dollarIdx < 0) {
          break;
        }

        final semiIdx =
            ctx.pressureBuf.indexOf(
                ';',
                dollarIdx);

        if (semiIdx < 0) {
          break;
        }

        final frame =
            ctx.pressureBuf.substring(
          dollarIdx + 1,
          semiIdx,
        );

        final fields =
            frame.split(',');

        if (fields.length >= 3) {

          ctx.pressure.p1 =
              double.tryParse(
                      fields[0])
                  ?? 0;

          ctx.pressure.p2 =
              double.tryParse(
                      fields[1])
                  ?? 0;

          ctx.pressure.p3 =
              double.tryParse(
                      fields[2])
                  ?? 0;

          ctx.lastUpdate =
              DateTime.now();

          // LEFT

          if (ctx.role ==
              DeviceRole
                  .pressureLeft) {

            _prevPressureLeft =
                _currPressureLeft
                    .copy();

            _prevPressureLeftTime =
                _currPressureLeftTime;

            _currPressureLeft =
                ctx.pressure.copy();

            _currPressureLeftTime =
                DateTime.now();
          }

          // RIGHT

          if (ctx.role ==
              DeviceRole
                  .pressureRight) {

            _prevPressureRight =
                _currPressureRight
                    .copy();

            _prevPressureRightTime =
                _currPressureRightTime;

            _currPressureRight =
                ctx.pressure.copy();

            _currPressureRightTime =
                DateTime.now();
          }
        }

        start = semiIdx + 1;
      }

      if (start > 0 &&
          start <
              ctx.pressureBuf.length) {

        ctx.pressureBuf =
            ctx.pressureBuf
                .substring(start);
      }

    } catch (e) {

      debugPrint(
          '[Pressure] 解析错误: $e');
    }
  }

  // =========================
  // IMU Parse
  // =========================

  void _handleImuData(
      DeviceContext ctx,
      List<int> data) {

    try {

      ctx.imuBuf.addAll(data);

      while (ctx.imuBuf.length >=
          20) {

        int idx =
            _findFrameHeader(
                ctx.imuBuf);

        if (idx < 0) break;

        if (idx > 0) {
          ctx.imuBuf.removeRange(
              0,
              idx);
        }

        if (ctx.imuBuf.length < 20) {
          break;
        }

        _parseImuFrame(
          ctx,
          ctx.imuBuf.sublist(0, 20),
        );

        ctx.imuBuf.removeRange(
            0,
            20);
      }

    } catch (e) {

      debugPrint(
          '[IMU] 解析错误: $e');
    }
  }

  int _findFrameHeader(
      List<int> buf) {

    for (int i = 0;
        i < buf.length - 1;
        i++) {

      if (buf[i] == 0x55 &&
          buf[i + 1] == 0x61) {

        return i;
      }
    }

    return -1;
  }

  void _parseImuFrame(
      DeviceContext ctx,
      List<int> frameBytes) {

    final bytes =
        Uint8List.fromList(
            frameBytes);

    final bd =
        ByteData.sublistView(bytes);

    ctx.imu.accX =
        bd.getInt16(
                2,
                Endian.little) /
            32768.0 *
            16.0;

    ctx.imu.accY =
        bd.getInt16(
                4,
                Endian.little) /
            32768.0 *
            16.0;

    ctx.imu.accZ =
        bd.getInt16(
                6,
                Endian.little) /
            32768.0 *
            16.0;

    ctx.imu.gyroX =
        bd.getInt16(
                8,
                Endian.little) /
            32768.0 *
            2000.0;

    ctx.imu.gyroY =
        bd.getInt16(
                10,
                Endian.little) /
            32768.0 *
            2000.0;

    ctx.imu.gyroZ =
        bd.getInt16(
                12,
                Endian.little) /
            32768.0 *
            2000.0;

    ctx.imu.roll =
        bd.getInt16(
                14,
                Endian.little) /
            32768.0 *
            180.0;

    ctx.imu.pitch =
        bd.getInt16(
                16,
                Endian.little) /
            32768.0 *
            180.0;

    ctx.imu.yaw =
        bd.getInt16(
                18,
                Endian.little) /
            32768.0 *
            180.0;

    ctx.lastUpdate =
        DateTime.now();
  }

  // =========================
  // Recording
  // =========================

  void startRecording() {

    if (_recording) return;

    _records.clear();

    _recording = true;

    _sampleIndex = 0;

    _recordStartTime =
        DateTime.now();

    _recordWatch =
        Stopwatch()..start();

    _sampleTimer?.cancel();

    _sampleTimer =
        Timer.periodic(
      const Duration(
          milliseconds: 10),
      (_) {

        if (_recording) {
          _captureOneRecord();
        }
      },
    );

    notifyListeners();

    debugPrint(
        '[Record] 固定100Hz开始');
  }

  void stopRecording() {

    _recording = false;

    _sampleTimer?.cancel();

    _sampleTimer = null;

    notifyListeners();

    debugPrint(
        '[Record] 停止录制');
  }

  // =========================
  // Pressure Interpolation
  // =========================

  PressureData _interpolatePressure(
    PressureData prevPressure,
    PressureData currPressure,
    DateTime prevTime,
    DateTime currTime,
    DateTime targetTime,
  ) {

    final duration =
        currTime
            .difference(prevTime)
            .inMilliseconds;

    if (duration <= 0) {
      return currPressure;
    }

    final progress =
        targetTime
                .difference(prevTime)
                .inMilliseconds /
            duration;

    final t =
        progress.clamp(0.0, 1.0);

    return PressureData()
      ..p1 =
          prevPressure.p1 +
              (currPressure.p1 -
                      prevPressure.p1) *
                  t
      ..p2 =
          prevPressure.p2 +
              (currPressure.p2 -
                      prevPressure.p2) *
                  t
      ..p3 =
          prevPressure.p3 +
              (currPressure.p3 -
                      prevPressure.p3) *
                  t;
  }

  // =========================
  // Capture Record
  // =========================

  void _captureOneRecord() {

    final timestamp =
        _recordStartTime.add(
      Duration(
        milliseconds:
            _sampleIndex * 10,
      ),
    );

    _sampleIndex++;

    final imuL =
        _contexts[
                DeviceRole.imuLeft]!
            .imu
            .copy();

    final imuR =
        _contexts[
                DeviceRole.imuRight]!
            .imu
            .copy();

    final now =
        DateTime.now();

    PressureData pressureL =
        _contexts[
                DeviceRole
                    .pressureLeft]!
            .pressure
            .copy();

    PressureData pressureR =
        _contexts[
                DeviceRole
                    .pressureRight]!
            .pressure
            .copy();

    // LEFT interpolate

    if (_prevPressureLeftTime !=
            null &&
        _currPressureLeftTime !=
            null) {

      pressureL =
          _interpolatePressure(
        _prevPressureLeft,
        _currPressureLeft,
        _prevPressureLeftTime!,
        _currPressureLeftTime!,
        now,
      );
    }

    // RIGHT interpolate

    if (_prevPressureRightTime !=
            null &&
        _currPressureRightTime !=
            null) {

      pressureR =
          _interpolatePressure(
        _prevPressureRight,
        _currPressureRight,
        _prevPressureRightTime!,
        _currPressureRightTime!,
        now,
      );
    }

    final rec = GaitRecord(
      timestamp:
          timestamp.toIso8601String(),

      pressureR: pressureR,

      imuR: imuR,

      pressureL: pressureL,

      imuL: imuL,

      label: _currentLabel,
    );

    _records.add(rec);
  }

  // =========================
  // Disconnect
  // =========================

  Future<void> disconnectAll()
      async {

    for (final ctx
        in _contexts.values) {

      await ctx.notifySub?.cancel();

      await ctx.connSub?.cancel();

      try {

        await ctx.device
            ?.disconnect();

      } catch (_) {}
    }

    _sampleTimer?.cancel();

    _dataProcessTimer?.cancel();

    notifyListeners();
  }

  // =========================
  // Label
  // =========================

  void setLabel(String label) {

    _currentLabel = label;

    notifyListeners();
  }

  void clearRecords() {

    _records.clear();

    notifyListeners();
  }

  // =========================
  // Dispose
  // =========================

  @override
  void dispose() {

    _sampleTimer?.cancel();

    _dataProcessTimer?.cancel();

    _scanSub?.cancel();

    disconnectAll();

    super.dispose();
  }
}
```
