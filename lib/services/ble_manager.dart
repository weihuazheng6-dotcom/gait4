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

  // 数据处理流控制
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

  // UI更新节流 - 防止过高频率的UI更新
  final Map<DeviceRole, DateTime> _lastNotifyTime = {};
  static const Duration _notifyThrottle = Duration(milliseconds: 50); // 20Hz UI更新

  // 数据处理队列
  final Map<DeviceRole, List<Map<String, dynamic>>> _dataQueue = {
    for (final role in DeviceRole.values) role: [],
  };

  // 后台数据处理定时器
  Timer? _dataProcessTimer;
  static const Duration _processingInterval = Duration(milliseconds: 10);

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

  BleManager() {
    _initializeLastNotifyTime();
  }

  void _initializeLastNotifyTime() {
    for (final role in DeviceRole.values) {
      _lastNotifyTime[role] = DateTime.now();
    }
  }

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

      // ========== 新增：请求更优蓝牙连接间隔 ==========
      await _requestOptimalConnectionParameters(device, role);
      // ===========================================

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

      // 启动后台数据处理器（只启动一次）
      _startDataProcessor();

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

  /// 新增：请求最优连接间隔（Android 7.5ms，iOS 15ms）
  Future<void> _requestOptimalConnectionParameters(BluetoothDevice device, DeviceRole role) async {
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        // Android: 高优先级模式，期望连接间隔 7.5ms - 15ms
        await device.requestConnectionPriority(
          priority: ConnectionPriority.highPriority,
        );
        _log(role, '已请求 Android 高优先级连接参数 (期望 7.5-15ms)');
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        // iOS: 尝试请求，但系统通常会忽略或无法动态调整
        // 这里仅做一个空调用，不报错即可
        try {
          await device.requestConnectionPriority(
            priority: ConnectionPriority.balanced,
          );
          _log(role, '已尝试 iOS 连接参数请求');
        } catch (e) {
          _log(role, 'iOS 连接参数请求被忽略（正常）: $e');
        }
      }
    } catch (e) {
      _log(role, '请求连接参数失败: $e');
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
      // 直接放入队列，而不是立即处理
      _queuePressureData(ctx, data);
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
      // 直接放入队列，而不是立即处理
      _queueImuData(ctx, data);
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

  // ─────────────────────────── 数据队列 ───────────────────────────

  /// 将压力数据入队（非阻塞）
  void _queuePressureData(DeviceContext ctx, List<int> data) {
    final queue = _dataQueue[ctx.role]!;
    // 限制队列大小，防止内存泄漏
    if (queue.length < 50) {
      queue.add({
        'type': 'pressure',
        'data': data,
        'timestamp': DateTime.now(),
      });
    }
  }

  /// 将IMU数据入队（非阻塞）
  void _queueImuData(DeviceContext ctx, List<int> data) {
    final queue = _dataQueue[ctx.role]!;
    // 限制队列大小，防止内存泄漏
    if (queue.length < 50) {
      queue.add({
        'type': 'imu',
        'data': data,
        'timestamp': DateTime.now(),
      });
    }
  }

  // ─────────────────────────── 后台数据处理 ───────────────────────────

  /// 启动后台数据处理定时器
  void _startDataProcessor() {
    _dataProcessTimer ??= Timer.periodic(_processingInterval, (_) {
      _processAllDataQueues();
    });
  }

  /// 处理所有设备的数据队列
  void _processAllDataQueues() {
    bool shouldNotify = false;
    bool hasNewData = false;

    for (final role in DeviceRole.values) {
      final queue = _dataQueue[role]!;
      if (queue.isEmpty) continue;

      final ctx = _contexts[role]!;

      // 一次性处理队列中的所有数据
      while (queue.isNotEmpty) {
        final item = queue.removeAt(0);
        final data = item['data'] as List<int>;

        if (item['type'] == 'pressure') {
          _handlePressureData(ctx, data);
        } else {
          _handleImuData(ctx, data);
        }
        
        hasNewData = true;
      }

      // 检查是否需要通知UI（节流）
      final now = DateTime.now();
      final lastNotify = _lastNotifyTime[role]!;
      if (now.difference(lastNotify) >= _notifyThrottle) {
        _lastNotifyTime[role] = now;
        shouldNotify = true;
      }
    }

    // 数据驱动采样：有新数据就采样一次
    if (_recording && hasNewData) {
      _captureOneRecord();
    }

    // 统一的UI更新通知，而不是每个数据都通知
    if (shouldNotify) {
      notifyListeners();
    }
  }

  // ─────────────────────────── 数据解析 ───────────────────────────

  /// 压力数据：ASCII "$P1,P2,P3,...;"
  void _handlePressureData(DeviceContext ctx, List<int> data) {
    try {
      final text = ascii.decode(data, allowInvalid: true);
      ctx._pressureBuf += text;

      // 防止缓冲区过大
      if (ctx._pressureBuf.length > 1024) {
        final lastDollar = ctx._pressureBuf.lastIndexOf(r'$');
        if (lastDollar > 0) {
          ctx._pressureBuf = ctx._pressureBuf.substring(lastDollar);
        } else {
          ctx._pressureBuf = '';
        }
      }

      // 高效的帧解析
      int start = 0;
      while (start < ctx._pressureBuf.length) {
        final dollarIdx = ctx._pressureBuf.indexOf(r'$', start);
        if (dollarIdx < 0) {
          // 没有找到$，清空之前的内容
          ctx._pressureBuf = '';
          break;
        }

        final semiIdx = ctx._pressureBuf.indexOf(';', dollarIdx);
        if (semiIdx < 0) {
          // 没有找到;，保留$之后的内容
          ctx._pressureBuf = ctx._pressureBuf.substring(dollarIdx);
          break;
        }

        // 解析一个完整的帧
        final frame = ctx._pressureBuf.substring(dollarIdx + 1, semiIdx);
        final fields = frame.split(',');

        if (fields.length >= 3) {
          try {
            ctx.pressure.p1 = double.tryParse(fields[0].trim()) ?? ctx.pressure.p1;
            ctx.pressure.p2 = double.tryParse(fields[1].trim()) ?? ctx.pressure.p2;
            ctx.pressure.p3 = double.tryParse(fields[2].trim()) ?? ctx.pressure.p3;
            ctx.lastUpdate = DateTime.now();
            ctx._dataPacketsProcessed++;
          } catch (_) {
            // 解析单个值失败，继续
          }
        }

        start = semiIdx + 1;
      }

      // 清理已处理的数据
      if (start > 0 && start < ctx._pressureBuf.length) {
        ctx._pressureBuf = ctx._pressureBuf.substring(start);
      } else if (start > 0) {
        ctx._pressureBuf = '';
      }
    } catch (e) {
      _log(ctx.role, '压力解析异常: $e');
    }
  }

  /// IMU数据：20字节二进制帧，帧头0x55 0x61
  void _handleImuData(DeviceContext ctx, List<int> data) {
    try {
      ctx._imuBuf.addAll(data);

      // 防止缓冲区过大（更大的缓冲区以适应高速数据流）
      if (ctx._imuBuf.length > 512) {
        // 保留最后256字节
        ctx._imuBuf.removeRange(0, ctx._imuBuf.length - 256);
      }

      // 高效的帧头搜索：使用快速的字节对比
      int frameCount = 0;
      while (ctx._imuBuf.length >= 20 && frameCount < 5) {
        // 查找帧头 0x55 0x61
        int idx = _findFrameHeader(ctx._imuBuf);
        
        if (idx < 0) {
          // 没找到帧头，保留最后1字节以防帧头被切断
          if (ctx._imuBuf.length > 1) {
            ctx._imuBuf.removeRange(0, ctx._imuBuf.length - 1);
          }
          break;
        }

        // 删除帧头前的数据
        if (idx > 0) {
          ctx._imuBuf.removeRange(0, idx);
        }

        if (ctx._imuBuf.length < 20) break;

        // 解析20字节帧
        try {
          _parseImuFrame(ctx, ctx._imuBuf.sublist(0, 20));
          ctx._dataPacketsProcessed++;
        } catch (e) {
          // 帧解析失败，跳过这个字节
          if (ctx._imuBuf.length > 1) {
            ctx._imuBuf.removeRange(0, 1);
          } else {
            break;
          }
          continue;
        }

        // 成功解析，删除已处理的帧
        ctx._imuBuf.removeRange(0, 20);
        frameCount++;
      }
    } catch (e) {
      _log(ctx.role, 'IMU解析异常: $e');
    }
  }

  /// 快速查找IMU帧头
  int _findFrameHeader(List<int> buf) {
    for (int i = 0; i < buf.length - 1; i++) {
      if (buf[i] == 0x55 && buf[i + 1] == 0x61) {
        return i;
      }
    }
    return -1;
  }

  /// 解析单个IMU帧
  void _parseImuFrame(DeviceContext ctx, List<int> frameBytes) {
    final bytes = Uint8List.fromList(frameBytes);
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
    _dataProcessTimer?.cancel();
    _dataProcessTimer = null;
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

  // ─────────────────────────── 录制 ───────────────────────────

  void startRecording() {
    if (_recording) return;
    _records.clear();
    _recording = true;

    notifyListeners();
    debugPrint('[Record] 开始录制 - 数据驱动采样100Hz');
  }

  void stopRecording() {
    _recording = false;
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
    // 直接读取最新数据
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
    _dataProcessTimer?.cancel();
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
