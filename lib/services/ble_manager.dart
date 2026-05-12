import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../models/gait_data.dart';

/// BLE UUID常量
class BleUuids {
  // 压力传感器 JDY-10-V2.5
  static final Guid pressureService = Guid('0000FFE0-0000-1000-8000-00805F9B34FB');
  static final Guid pressureNotify  = Guid('0000FFE1-0000-1000-8000-00805F9B34FB');

  // IMU WT9011DCL
  static final Guid imuService = Guid('0000FFE5-0000-1000-8000-00805F9A34FB');
  static final Guid imuNotify  = Guid('0000FFE4-0000-1000-8000-00805F9A34FB');
  static final Guid imuWrite   = Guid('0000FFE9-0000-1000-8000-00805F9A34FB');
}

/// 单个设备连接的上下文
class DeviceContext {
  DeviceRole role;
  BluetoothDevice? device;
  ConnectionStatus status = ConnectionStatus.disconnected;
  StreamSubscription<BluetoothConnectionState>? connSub;
  StreamSubscription<List<int>>? notifySub;

  // 数据
  PressureData pressure = PressureData();
  ImuData imu = ImuData();

  // 缓冲区
  final List<int> _imuBuf = [];
  String _pressureBuf = '';

  // 元信息
  String deviceName = '';
  String deviceId = '';
  DateTime? lastUpdate;

  DeviceContext(this.role);

  void resetData() {
    pressure = PressureData();
    imu = ImuData();
    _imuBuf.clear();
    _pressureBuf = '';
  }
}

class BleManager extends ChangeNotifier {
  // 4个角色的设备上下文
  final Map<DeviceRole, DeviceContext> _contexts = {
    DeviceRole.pressureLeft:  DeviceContext(DeviceRole.pressureLeft),
    DeviceRole.pressureRight: DeviceContext(DeviceRole.pressureRight),
    DeviceRole.imuLeft:       DeviceContext(DeviceRole.imuLeft),
    DeviceRole.imuRight:      DeviceContext(DeviceRole.imuRight),
  };

  // 扫描结果
  final List<ScanResult> _scanResults = [];
  bool _scanning = false;
  StreamSubscription<List<ScanResult>>? _scanSub;

  // 录制
  bool _recording = false;
  String _currentLabel = '0';
  final List<GaitRecord> _records = [];
  Timer? _recordTimer;

  // 公开getters
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

  // ─────────────────────────── 扫描 ───────────────────────────

  Future<void> startScan({int timeoutSec = 12}) async {
    if (_scanning) return;
    _scanResults.clear();
    _scanning = true;
    notifyListeners();

    try {
      // 确保蓝牙开启
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

      // 等待扫描结束
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

  // ─────────────────────────── 连接 ───────────────────────────

  Future<bool> connectDevice(BluetoothDevice device, DeviceRole role) async {
    final ctx = _contexts[role]!;

    // 如果原来有连接，先断开
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
    _log(role, '开始连接 $ctx.deviceName (${ctx.deviceId})');

    try {
      // 监听连接状态
      await ctx.connSub?.cancel();
      ctx.connSub = device.connectionState.listen((state) {
        _log(role, '连接状态: $state');
        if (state == BluetoothConnectionState.disconnected) {
          ctx.status = ConnectionStatus.disconnected;
          ctx.resetData();
          notifyListeners();
        }
      });

      // 连接
      await device.connect(
        timeout: const Duration(seconds: 15),
        autoConnect: false,
      );

      // 请求更大MTU（Android）
      try {
        await device.requestMtu(247);
      } catch (_) {}

      // 发现服务
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

  /// 配置压力传感器Notify
  Future<void> _setupPressure(
      DeviceContext ctx, List<BluetoothService> services) async {
    BluetoothCharacteristic? notifyChar;

    for (final s in services) {
      // 匹配服务（兼容短UUID FFE0）
      final serviceUuidStr = s.uuid.str.toUpperCase();
      if (serviceUuidStr.contains('FFE0')) {
        for (final c in s.characteristics) {
          final charUuidStr = c.uuid.str.toUpperCase();
          if (charUuidStr.contains('FFE1') && c.properties.notify) {
            notifyChar = c;
            break;
          }
        }
      }
      if (notifyChar != null) break;
    }

    if (notifyChar == null) {
      throw Exception('未找到压力传感器FFE1特征');
    }

    // 开启notify（带重试，兼容鸿蒙）
    await _enableNotifyWithRetry(notifyChar);

    await ctx.notifySub?.cancel();
    ctx.notifySub = notifyChar.lastValueStream.listen((data) {
      _handlePressureData(ctx, data);
    }, onError: (e) {
      _log(ctx.role, 'Notify错误: $e');
    });

    _log(ctx.role, '✅ 压力Notify已开启');
  }

  /// 配置IMU Notify
  Future<void> _setupIMU(
      DeviceContext ctx, List<BluetoothService> services) async {
    BluetoothCharacteristic? notifyChar;

    for (final s in services) {
      final serviceUuidStr = s.uuid.str.toUpperCase();
      if (serviceUuidStr.contains('FFE5')) {
        for (final c in s.characteristics) {
          final charUuidStr = c.uuid.str.toUpperCase();
          if (charUuidStr.contains('FFE4') && c.properties.notify) {
            notifyChar = c;
            break;
          }
        }
      }
      if (notifyChar != null) break;
    }

    if (notifyChar == null) {
      throw Exception('未找到IMU FFE4特征');
    }

    // 开启notify（带重试）
    await _enableNotifyWithRetry(notifyChar);

    await ctx.notifySub?.cancel();
    ctx.notifySub = notifyChar.lastValueStream.listen((data) {
      _handleImuData(ctx, data);
    }, onError: (e) {
      _log(ctx.role, 'Notify错误: $e');
    });

    _log(ctx.role, '✅ IMU Notify已开启');
  }

  /// 开启Notify（带重试，兼容鸿蒙CCCD写入问题）
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

  // ─────────────────────────── 数据解析 ───────────────────────────

  /// 压力数据：ASCII "$P1,P2,P3,...;"
  void _handlePressureData(DeviceContext ctx, List<int> data) {
    try {
      final text = ascii.decode(data, allowInvalid: true);
      ctx._pressureBuf += text;

      // 防止缓冲区过大
      if (ctx._pressureBuf.length > 512) {
        final lastDollar = ctx._pressureBuf.lastIndexOf(r'$');
        if (lastDollar > 0) {
          ctx._pressureBuf = ctx._pressureBuf.substring(lastDollar);
        } else {
          ctx._pressureBuf = '';
        }
      }

      while (true) {
        final start = ctx._pressureBuf.indexOf(r'$');
        if (start < 0) {
          ctx._pressureBuf = '';
          break;
        }
        final end = ctx._pressureBuf.indexOf(';', start);
        if (end < 0) {
          if (start > 0) {
            ctx._pressureBuf = ctx._pressureBuf.substring(start);
          }
          break;
        }

        final frame = ctx._pressureBuf.substring(start + 1, end);
        ctx._pressureBuf = ctx._pressureBuf.substring(end + 1);

        final fields = frame.split(',');
        if (fields.length >= 3) {
          final p1 = double.tryParse(fields[0].trim()) ?? 0;
          final p2 = double.tryParse(fields[1].trim()) ?? 0;
          final p3 = double.tryParse(fields[2].trim()) ?? 0;
          ctx.pressure.p1 = p1;
          ctx.pressure.p2 = p2;
          ctx.pressure.p3 = p3;
          ctx.lastUpdate = DateTime.now();
          notifyListeners();
        }
      }
    } catch (e) {
      _log(ctx.role, '压力解析异常: $e');
    }
  }

  /// IMU数据：20字节二进制帧，帧头0x55 0x61
  void _handleImuData(DeviceContext ctx, List<int> data) {
    try {
      ctx._imuBuf.addAll(data);

      // 防止缓冲区过大
      if (ctx._imuBuf.length > 256) {
        ctx._imuBuf.removeRange(0, ctx._imuBuf.length - 64);
      }

      while (ctx._imuBuf.length >= 20) {
        // 查找帧头 0x55 0x61
        int idx = -1;
        for (int i = 0; i < ctx._imuBuf.length - 1; i++) {
          if (ctx._imuBuf[i] == 0x55 && ctx._imuBuf[i + 1] == 0x61) {
            idx = i;
            break;
          }
        }
        if (idx < 0) {
          // 没找到帧头，保留最后1字节以防帧头被切断
          if (ctx._imuBuf.length > 1) {
            ctx._imuBuf.removeRange(0, ctx._imuBuf.length - 1);
          }
          break;
        }

        if (idx > 0) {
          ctx._imuBuf.removeRange(0, idx);
        }

        if (ctx._imuBuf.length < 20) break;

        // 解析20字节
        final bytes = Uint8List.fromList(ctx._imuBuf.sublist(0, 20));
        final bd = ByteData.sublistView(bytes);

        // 小端序 int16
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
        ctx._imuBuf.removeRange(0, 20);
        notifyListeners();
      }
    } catch (e) {
      _log(ctx.role, 'IMU解析异常: $e');
    }
  }

  // ─────────────────────────── 断开 ───────────────────────────

  Future<void> disconnectRole(DeviceRole role) async {
    final ctx = _contexts[role]!;
    await _disconnectInternal(ctx);
    notifyListeners();
  }

  Future<void> disconnectAll() async {
    for (final ctx in _contexts.values) {
      await _disconnectInternal(ctx);
    }
    if (_recording) {
      stopRecording();
    }
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
  }

  // ─────────────────────────── 录制 ───────────────────────────

  void startRecording() {
    if (_recording) return;
    _records.clear();
    _recording = true;

    // 10Hz采样打包
    _recordTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      _captureOneRecord();
    });

    notifyListeners();
    debugPrint('[Record] 开始录制');
  }

  void stopRecording() {
    _recording = false;
    _recordTimer?.cancel();
    _recordTimer = null;
    notifyListeners();
    debugPrint('[Record] 停止录制，共${_records.length}条');
  }

  void setLabel(String label) {
    _currentLabel = label;
    notifyListeners();
  }

  void clearRecords() {
    _records.clear();
    notifyListeners();
  }

  void _captureOneRecord() {
    final pL = _contexts[DeviceRole.pressureLeft]!.pressure.copy();
    final pR = _contexts[DeviceRole.pressureRight]!.pressure.copy();
    final iL = _contexts[DeviceRole.imuLeft]!.imu.copy();
    final iR = _contexts[DeviceRole.imuRight]!.imu.copy();

    final rec = GaitRecord(
      timestamp: DateTime.now().toIso8601String(),
      pressureR: pR,
      imuR: iR,
      pressureL: pL,
      imuL: iL,
      label: _currentLabel,
    );
    _records.add(rec);
    notifyListeners();
  }

  // ─────────────────────────── 工具 ───────────────────────────

  void _log(DeviceRole role, String msg) {
    final ts = DateTime.now().toIso8601String();
    debugPrint('[$ts][${role.label}] $msg');
  }

  @override
  void dispose() {
    _recordTimer?.cancel();
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
