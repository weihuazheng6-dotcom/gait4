import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../models/gait_data.dart';

/// BLE UUID常量
class BleUuids {
  static final Guid pressureService = Guid('0000FFE0-0000-1000-8000-00805F9B34FB');
  static final Guid pressureNotify  = Guid('0000FFE1-0000-1000-8000-00805F9B34FB');
  static final Guid imuService = Guid('0000FFE5-0000-1000-8000-00805F9A34FB');
  static final Guid imuNotify  = Guid('0000FFE4-0000-1000-8000-00805F9A34FB');
  static final Guid imuWrite   = Guid('0000FFE9-0000-1000-8000-00805F9A34FB');
}

class DeviceContext {
  DeviceRole role;
  BluetoothDevice? device;
  ConnectionStatus status = ConnectionStatus.disconnected;
  StreamSubscription<BluetoothConnectionState>? connSub;
  StreamSubscription<List<int>>? notifySub;

  PressureData pressure = PressureData();
  ImuData imu = ImuData();

  final List<int> _imuBuf = [];
  String _pressureBuf = '';

  String deviceName = '';
  String deviceId = '';
  DateTime? lastUpdate;

  int _dataPacketsProcessed = 0;
  int _skippedNotifications = 0;

  DeviceContext(this.role);

  void resetData() {
    pressure = PressureData();
    imu = ImuData();
    _imuBuf.clear();
    _pressureBuf = '';
    _dataPacketsProcessed = 0;
    _skippedNotifications = 0;
  }
}

class BleManager extends ChangeNotifier {
  final Map<DeviceRole, DeviceContext> _contexts = {
    DeviceRole.pressureLeft:  DeviceContext(DeviceRole.pressureLeft),
    DeviceRole.pressureRight: DeviceContext(DeviceRole.pressureRight),
    DeviceRole.imuLeft:       DeviceContext(DeviceRole.imuLeft),
    DeviceRole.imuRight:      DeviceContext(DeviceRole.imuRight),
  };

  final List<ScanResult> _scanResults = [];
  bool _scanning = false;
  StreamSubscription<List<ScanResult>>? _scanSub;

  bool _recording = false;
  String _currentLabel = '0';
  final List<GaitRecord> _records = [];

  // ===== 录制时间轴 =====
  DateTime? _recordStartTime;
  Stopwatch? _stopwatch;
  int _sampleIndex = 0;

  // ===== 压力插值状态（时间为 stopwatch 毫秒）=====
  PressureData _prevPressureLeft = PressureData();
  PressureData _currPressureLeft = PressureData();
  int _prevPressureLeftTime = 0;
  int _currPressureLeftTime = 0;

  PressureData _prevPressureRight = PressureData();
  PressureData _currPressureRight = PressureData();
  int _prevPressureRightTime = 0;
  int _currPressureRightTime = 0;

  // ===== 数据队列 (Queue 而不是 List) =====
  final Map<DeviceRole, Queue<Map<String, dynamic>>> _dataQueue = {
    for (final role in DeviceRole.values) role: Queue<Map<String, dynamic>>(),
  };

  // ===== 主定时器（10ms 处理 + 采样）=====
  Timer? _mainTimer;
  static const Duration _tickInterval = Duration(milliseconds: 10);

  // 等待两侧压力都越过 target 才出样本，最多宽限 500ms（防止单边掉线时卡住）
  static const int _interpGraceMs = 500;

  // ===== UI 刷新限频（20Hz）=====
  DateTime _lastUiNotify = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _uiThrottle = Duration(milliseconds: 50);

  // ===== 公开 getter（不可改名）=====
  DeviceContext getContext(DeviceRole role) => _contexts[role]!;
  List<ScanResult> get scanResults => List.unmodifiable(_scanResults);
  bool get isScanning => _scanning;
  bool get isRecording => _recording;
  String get currentLabel => _currentLabel;
  int get recordCount => _records.length;
  List<GaitRecord> get records => List.unmodifiable(_records);

  int get connectedCount => _contexts.values
      .where((c) => c.status == ConnectionStatus.connected)
      .length;

  BleManager();

  // ============================================================
  // 扫描
  // ============================================================
  Future<void> startScan({int timeoutSec = 12}) async {
    if (_scanning) return;
    _scanResults.clear();
    _scanning = true;
    notifyListeners();

    try {
      if (await FlutterBluePlus.isSupported == false) {
        debugPrint('[BLE] 设备不支持蓝牙');
        _scanning = false;
        notifyListeners();
        return;
      }

      await _scanSub?.cancel();
      _scanSub = FlutterBluePlus.scanResults.listen((results) {
        _scanResults
          ..clear()
          ..addAll(results);
        notifyListeners();
      }, onError: (e) {
        debugPrint('[BLE] 扫描流错误: $e');
      });

      await FlutterBluePlus.startScan(
        timeout: Duration(seconds: timeoutSec),
        androidUsesFineLocation: true,
      );

      await Future.delayed(Duration(seconds: timeoutSec));
    } catch (e) {
      debugPrint('[BLE] 启动扫描失败: $e');
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
    } catch (e) {
      debugPrint('[BLE] 停止扫描失败: $e');
    }
    _scanning = false;
    await _scanSub?.cancel();
    _scanSub = null;
    notifyListeners();
  }

  // ============================================================
  // 连接
  // ============================================================
  Future<bool> connectDevice(BluetoothDevice device, DeviceRole role) async {
    final ctx = _contexts[role]!;

    if (ctx.device != null) {
      await _disconnectInternal(ctx);
    }

    ctx.device = device;
    ctx.deviceName = device.platformName.isNotEmpty
        ? device.platformName
        : (device.advName.isNotEmpty ? device.advName : '未知设备');
    ctx.deviceId = device.remoteId.str;
    ctx.status = ConnectionStatus.connecting;
    notifyListeners();
    _log(role, '开始连接 ${ctx.deviceName} (${ctx.deviceId})');

    try {
      await ctx.connSub?.cancel();
      ctx.connSub = device.connectionState.listen((state) {
        _log(role, '连接状态: $state');
        if (state == BluetoothConnectionState.disconnected) {
          ctx.status = ConnectionStatus.disconnected;
          ctx.resetData();
          notifyListeners();
        }
      });

      await device.connect(
        timeout: const Duration(seconds: 15),
        autoConnect: false,
      );

      try {
        await device.requestMtu(247);
      } catch (_) {}

      final services = await device.discoverServices();
      _log(role, '发现 ${services.length} 个服务');

      if (role.isPressure) {
        await _setupPressure(ctx, services);
      } else {
        await _setupIMU(ctx, services);
      }

      ctx.status = ConnectionStatus.connected;
      ctx.lastUpdate = DateTime.now();
      notifyListeners();
      _log(role, '✅ 连接成功');

      _startMainTimer();
      return true;
    } catch (e) {
      _log(role, '❌ 连接失败: $e');
      ctx.status = ConnectionStatus.failed;
      notifyListeners();
      try {
        await device.disconnect();
      } catch (_) {}
      return false;
    }
  }

  Future<void> _setupPressure(
      DeviceContext ctx, List<BluetoothService> services) async {
    BluetoothCharacteristic? notifyChar;
    for (final s in services) {
      if (s.uuid.str.toUpperCase().contains('FFE0')) {
        for (final c in s.characteristics) {
          if (c.uuid.str.toUpperCase().contains('FFE1') && c.properties.notify) {
            notifyChar = c;
            break;
          }
        }
      }
      if (notifyChar != null) break;
    }
    if (notifyChar == null) throw Exception('未找到压力传感器FFE1特征');

    await _enableNotifyWithRetry(notifyChar);

    await ctx.notifySub?.cancel();
    ctx.notifySub = notifyChar.lastValueStream.listen((data) {
      _queuePressureData(ctx, data);
    }, onError: (e) {
      _log(ctx.role, 'Notify错误: $e');
    });

    _log(ctx.role, '✅ 压力Notify已开启');
  }

  Future<void> _setupIMU(
      DeviceContext ctx, List<BluetoothService> services) async {
    BluetoothCharacteristic? notifyChar;
    for (final s in services) {
      if (s.uuid.str.toUpperCase().contains('FFE5')) {
        for (final c in s.characteristics) {
          if (c.uuid.str.toUpperCase().contains('FFE4') && c.properties.notify) {
            notifyChar = c;
            break;
          }
        }
      }
      if (notifyChar != null) break;
    }
    if (notifyChar == null) throw Exception('未找到IMU FFE4特征');

    await _enableNotifyWithRetry(notifyChar);

    await ctx.notifySub?.cancel();
    ctx.notifySub = notifyChar.lastValueStream.listen((data) {
      _queueImuData(ctx, data);
    }, onError: (e) {
      _log(ctx.role, 'Notify错误: $e');
    });

    _log(ctx.role, '✅ IMU Notify已开启');
  }

  Future<void> _enableNotifyWithRetry(
      BluetoothCharacteristic char, {int retries = 3}) async {
    Exception? lastErr;
    for (int i = 0; i < retries; i++) {
      try {
        await char.setNotifyValue(true);
        await Future.delayed(const Duration(milliseconds: 200));
        return;
      } catch (e) {
        lastErr = e is Exception ? e : Exception(e.toString());
        debugPrint('[BLE] setNotifyValue重试 ${i + 1}/$retries: $e');
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
    throw lastErr ?? Exception('setNotifyValue失败');
  }

  // ============================================================
  // 入队（不在这里采样）
  // ============================================================
  void _queuePressureData(DeviceContext ctx, List<int> data) {
    final queue = _dataQueue[ctx.role]!;
    if (queue.length < 200) {
      queue.add({'type': 'pressure', 'data': data});
    } else {
      ctx._skippedNotifications++;
    }
  }

  void _queueImuData(DeviceContext ctx, List<int> data) {
    final queue = _dataQueue[ctx.role]!;
    if (queue.length < 200) {
      queue.add({'type': 'imu', 'data': data});
    } else {
      ctx._skippedNotifications++;
    }
  }

  // ============================================================
  // 主定时器：10ms 处理队列 + 采样 + 限频通知
  // ============================================================
  void _startMainTimer() {
    _mainTimer ??= Timer.periodic(_tickInterval, (_) => _onTick());
  }

  void _stopMainTimerIfIdle() {
    if (_recording) return;
    if (connectedCount > 0) return;
    _mainTimer?.cancel();
    _mainTimer = null;
  }

  void _onTick() {
    _processAllDataQueues();
    if (_recording) {
      _runSamplingTick();
    }
    _throttledNotify();
  }

  void _processAllDataQueues() {
    for (final role in DeviceRole.values) {
      final queue = _dataQueue[role]!;
      if (queue.isEmpty) continue;
      final ctx = _contexts[role]!;
      while (queue.isNotEmpty) {
        final item = queue.removeFirst();
        final data = item['data'] as List<int>;
        if (item['type'] == 'pressure') {
          _handlePressureData(ctx, data);
        } else {
          _handleImuData(ctx, data);
        }
      }
    }
  }

  /// 仅当两侧压力 curr 都已越过 target，或宽限期到，才出样本。
  /// 保证大多数样本是真正插值得到，而不是退化成 ZOH。
  void _runSamplingTick() {
    if (_stopwatch == null || _recordStartTime == null) return;
    final elapsedMs = _stopwatch!.elapsedMilliseconds;

    while (_sampleIndex * 10 <= elapsedMs) {
      final target = _sampleIndex * 10;
      final stale = elapsedMs - target;
      final leftReady =
          _currPressureLeftTime >= target || stale > _interpGraceMs;
      final rightReady =
          _currPressureRightTime >= target || stale > _interpGraceMs;
      if (!leftReady || !rightReady) break;

      _captureOneRecord(target);
      _sampleIndex++;
    }
  }

  void _throttledNotify() {
    final now = DateTime.now();
    if (now.difference(_lastUiNotify) >= _uiThrottle) {
      _lastUiNotify = now;
      notifyListeners();
    }
  }

  // ============================================================
  // 压力解析（事件驱动只更新 prev/curr，不再触发采样）
  // ============================================================
  void _handlePressureData(DeviceContext ctx, List<int> data) {
    try {
      final text = ascii.decode(data, allowInvalid: true);
      ctx._pressureBuf += text;

      if (ctx._pressureBuf.length > 1024) {
        final lastDollar = ctx._pressureBuf.lastIndexOf(r'$');
        ctx._pressureBuf = lastDollar > 0
            ? ctx._pressureBuf.substring(lastDollar)
            : '';
      }

      int start = 0;
      while (start < ctx._pressureBuf.length) {
        final dollarIdx = ctx._pressureBuf.indexOf(r'$', start);
        if (dollarIdx < 0) {
          ctx._pressureBuf = '';
          break;
        }
        final semiIdx = ctx._pressureBuf.indexOf(';', dollarIdx);
        if (semiIdx < 0) {
          ctx._pressureBuf = ctx._pressureBuf.substring(dollarIdx);
          break;
        }
        final frame = ctx._pressureBuf.substring(dollarIdx + 1, semiIdx);
        final fields = frame.split(',');
        if (fields.length >= 3) {
          ctx.pressure.p1 =
              double.tryParse(fields[0].trim()) ?? ctx.pressure.p1;
          ctx.pressure.p2 =
              double.tryParse(fields[1].trim()) ?? ctx.pressure.p2;
          ctx.pressure.p3 =
              double.tryParse(fields[2].trim()) ?? ctx.pressure.p3;
          ctx.lastUpdate = DateTime.now();
          ctx._dataPacketsProcessed++;

          _onPressureUpdated(ctx);
        }
        start = semiIdx + 1;
      }

      if (start > 0 && start < ctx._pressureBuf.length) {
        ctx._pressureBuf = ctx._pressureBuf.substring(start);
      } else if (start > 0) {
        ctx._pressureBuf = '';
      }
    } catch (e) {
      _log(ctx.role, '压力解析异常: $e');
    }
  }

  /// 新压力到达：prev <- curr; curr <- new
  void _onPressureUpdated(DeviceContext ctx) {
    if (!_recording || _stopwatch == null) return;
    final ms = _stopwatch!.elapsedMilliseconds;
    if (ctx.role == DeviceRole.pressureLeft) {
      _prevPressureLeft = _currPressureLeft;
      _prevPressureLeftTime = _currPressureLeftTime;
      _currPressureLeft = ctx.pressure.copy();
      _currPressureLeftTime = ms;
    } else if (ctx.role == DeviceRole.pressureRight) {
      _prevPressureRight = _currPressureRight;
      _prevPressureRightTime = _currPressureRightTime;
      _currPressureRight = ctx.pressure.copy();
      _currPressureRightTime = ms;
    }
  }

  // ============================================================
  // IMU 解析（不采样，仅更新 ctx.imu，由 ZOH 在采样时使用）
  // ============================================================
  void _handleImuData(DeviceContext ctx, List<int> data) {
    try {
      ctx._imuBuf.addAll(data);
      if (ctx._imuBuf.length > 2048) {
        ctx._imuBuf.removeRange(0, ctx._imuBuf.length - 1024);
      }

      int frameCount = 0;
      while (ctx._imuBuf.length >= 20 && frameCount < 5) {
        int idx = _findFrameHeader(ctx._imuBuf);
        if (idx < 0) {
          if (ctx._imuBuf.length > 1) {
            ctx._imuBuf.removeRange(0, ctx._imuBuf.length - 1);
          }
          break;
        }
        if (idx > 0) ctx._imuBuf.removeRange(0, idx);
        if (ctx._imuBuf.length < 20) break;

        try {
          _parseImuFrame(ctx, ctx._imuBuf.sublist(0, 20));
          ctx._dataPacketsProcessed++;
        } catch (_) {
          if (ctx._imuBuf.length > 1) {
            ctx._imuBuf.removeRange(0, 1);
          } else {
            break;
          }
          continue;
        }
        ctx._imuBuf.removeRange(0, 20);
        frameCount++;
      }
    } catch (e) {
      _log(ctx.role, 'IMU解析异常: $e');
    }
  }

  int _findFrameHeader(List<int> buf) {
    for (int i = 0; i < buf.length - 1; i++) {
      if (buf[i] == 0x55 && buf[i + 1] == 0x61) return i;
    }
    return -1;
  }

  void _parseImuFrame(DeviceContext ctx, List<int> frameBytes) {
    final bd = ByteData.sublistView(Uint8List.fromList(frameBytes));
    final accX = bd.getInt16(2, Endian.little);
    final accY = bd.getInt16(4, Endian.little);
    final accZ = bd.getInt16(6, Endian.little);
    final gyroX = bd.getInt16(8, Endian.little);
    final gyroY = bd.getInt16(10, Endian.little);
    final gyroZ = bd.getInt16(12, Endian.little);
    final roll = bd.getInt16(14, Endian.little);
    final pitch = bd.getInt16(16, Endian.little);
    final yaw = bd.getInt16(18, Endian.little);

    ctx.imu.accX = accX / 32768.0 * 16.0;
    ctx.imu.accY = accY / 32768.0 * 16.0;
    ctx.imu.accZ = accZ / 32768.0 * 16.0;
    ctx.imu.gyroX = gyroX / 32768.0 * 2000.0;
    ctx.imu.gyroY = gyroY / 32768.0 * 2000.0;
    ctx.imu.gyroZ = gyroZ / 32768.0 * 2000.0;
    ctx.imu.roll = roll / 32768.0 * 180.0;
    ctx.imu.pitch = pitch / 32768.0 * 180.0;
    ctx.imu.yaw = yaw / 32768.0 * 180.0;
    ctx.lastUpdate = DateTime.now();
  }

  // ============================================================
  // 断开
  // ============================================================
  Future<void> disconnectRole(DeviceRole role) async {
    final ctx = _contexts[role]!;
    await _disconnectInternal(ctx);
    _stopMainTimerIfIdle();
    notifyListeners();
  }

  Future<void> disconnectAll() async {
    if (_recording) stopRecording();
    for (final ctx in _contexts.values) {
      await _disconnectInternal(ctx);
    }
    _stopMainTimerIfIdle();
    notifyListeners();
  }

  Future<void> _disconnectInternal(DeviceContext ctx) async {
    try {
      await ctx.notifySub?.cancel();
      await ctx.connSub?.cancel();
      ctx.notifySub = null;
      ctx.connSub = null;
      if (ctx.device != null) {
        try {
          await ctx.device!.disconnect();
        } catch (e) {
          debugPrint('[BLE] 断开异常: $e');
        }
      }
    } catch (e) {
      debugPrint('[BLE] 清理异常: $e');
    }
    ctx.device = null;
    ctx.status = ConnectionStatus.disconnected;
    ctx.deviceName = '';
    ctx.deviceId = '';
    ctx.resetData();
    _dataQueue[ctx.role]?.clear();
  }

  // ============================================================
  // 录制控制
  // ============================================================
  void startRecording() {
    if (_recording) return;
    _records.clear();

    _recordStartTime = DateTime.now();
    _stopwatch = Stopwatch()..start();
    _sampleIndex = 0;

    // 用当前实时压力做种子，避免开局前几条全为 0
    final pl = _contexts[DeviceRole.pressureLeft]!.pressure.copy();
    final pr = _contexts[DeviceRole.pressureRight]!.pressure.copy();
    _prevPressureLeft = pl;
    _currPressureLeft = pl.copy();
    _prevPressureLeftTime = 0;
    _currPressureLeftTime = 0;
    _prevPressureRight = pr;
    _currPressureRight = pr.copy();
    _prevPressureRightTime = 0;
    _currPressureRightTime = 0;

    _recording = true;
    _startMainTimer();
    notifyListeners();
    debugPrint('[Record] 开始录制 - 100Hz 固定采样 + 压力线性插值');
  }

  void stopRecording() {
    if (!_recording) return;
    _recording = false;
    _stopwatch?.stop();
    notifyListeners();
    debugPrint(
        '[Record] 停止录制，共 ${_records.length} 条 (期望 $_sampleIndex)');
  }

  void setLabel(String label) {
    _currentLabel = label;
    notifyListeners();
  }

  void clearRecords() {
    _records.clear();
    notifyListeners();
  }

  // ============================================================
  // 采样：固定时间戳 + 压力插值 + IMU ZOH
  // ============================================================
  void _captureOneRecord(int targetMs) {
    if (_recordStartTime == null) return;

    final timestamp =
        _recordStartTime!.add(Duration(milliseconds: targetMs));

    final pL = _interpolatePressureAt(
      targetMs,
      _prevPressureLeft, _currPressureLeft,
      _prevPressureLeftTime, _currPressureLeftTime,
    );
    final pR = _interpolatePressureAt(
      targetMs,
      _prevPressureRight, _currPressureRight,
      _prevPressureRightTime, _currPressureRightTime,
    );
    final iL = _contexts[DeviceRole.imuLeft]!.imu.copy();
    final iR = _contexts[DeviceRole.imuRight]!.imu.copy();

    _records.add(GaitRecord(
      timestamp: timestamp.toIso8601String(),
      pressureR: pR,
      imuR: iR,
      pressureL: pL,
      imuL: iL,
      label: _currentLabel,
    ));
  }

  /// 线性插值：P = prev + (curr - prev) * (target - prevT) / (currT - prevT)
  /// 边界：未拿到第二个样本时退化为最新值；target 在区间外按端点截断（ZOH）。
  PressureData _interpolatePressureAt(
    int targetMs,
    PressureData prev,
    PressureData curr,
    int prevT,
    int currT,
  ) {
    if (currT <= prevT) return curr.copy();
    if (targetMs <= prevT) return prev.copy();
    if (targetMs >= currT) return curr.copy();

    final ratio = (targetMs - prevT) / (currT - prevT);
    return PressureData()
      ..p1 = prev.p1 + (curr.p1 - prev.p1) * ratio
      ..p2 = prev.p2 + (curr.p2 - prev.p2) * ratio
      ..p3 = prev.p3 + (curr.p3 - prev.p3) * ratio;
  }

  void _log(DeviceRole role, String msg) {
    final ts = DateTime.now().toIso8601String();
    debugPrint('[$ts][${role.label}] $msg');
  }

  @override
  void dispose() {
    _mainTimer?.cancel();
    _scanSub?.cancel();
    for (final ctx in _contexts.values) {
      ctx.notifySub?.cancel();
      ctx.connSub?.cancel();
      try {
        ctx.device?.disconnect();
      } catch (_) {}
    }
    super.dispose();
  }
}
