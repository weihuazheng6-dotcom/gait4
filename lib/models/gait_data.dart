/// 设备角色
enum DeviceRole {
  pressureLeft,   // 左脚压力
  pressureRight,  // 右脚压力
  imuLeft,        // 左脚IMU
  imuRight,       // 右脚IMU
}

extension DeviceRoleX on DeviceRole {
  String get label {
    switch (this) {
      case DeviceRole.pressureLeft: return '左脚压力';
      case DeviceRole.pressureRight: return '右脚压力';
      case DeviceRole.imuLeft: return '左脚IMU';
      case DeviceRole.imuRight: return '右脚IMU';
    }
  }

  bool get isPressure =>
      this == DeviceRole.pressureLeft || this == DeviceRole.pressureRight;

  bool get isIMU =>
      this == DeviceRole.imuLeft || this == DeviceRole.imuRight;

  bool get isLeft =>
      this == DeviceRole.pressureLeft || this == DeviceRole.imuLeft;
}

/// 连接状态
enum ConnectionStatus {
  disconnected,
  connecting,
  connected,
  failed,
}

extension ConnectionStatusX on ConnectionStatus {
  String get label {
    switch (this) {
      case ConnectionStatus.disconnected: return '未连接';
      case ConnectionStatus.connecting: return '连接中';
      case ConnectionStatus.connected: return '已连接';
      case ConnectionStatus.failed: return '连接失败';
    }
  }
}

/// 压力数据
class PressureData {
  double p1; // 第一跖骨
  double p2; // 第五跖骨
  double p3; // 脚跟

  PressureData({this.p1 = 0, this.p2 = 0, this.p3 = 0});

  PressureData copy() => PressureData(p1: p1, p2: p2, p3: p3);
}

/// IMU数据
class ImuData {
  double accX, accY, accZ;      // 加速度 g
  double gyroX, gyroY, gyroZ;   // 角速度 °/s
  double roll, pitch, yaw;      // 欧拉角 °

  ImuData({
    this.accX = 0, this.accY = 0, this.accZ = 0,
    this.gyroX = 0, this.gyroY = 0, this.gyroZ = 0,
    this.roll = 0, this.pitch = 0, this.yaw = 0,
  });

  ImuData copy() => ImuData(
    accX: accX, accY: accY, accZ: accZ,
    gyroX: gyroX, gyroY: gyroY, gyroZ: gyroZ,
    roll: roll, pitch: pitch, yaw: yaw,
  );
}

/// 单次采样记录（一行CSV）
class GaitRecord {
  final String timestamp;
  final PressureData pressureR;
  final ImuData imuR;
  final PressureData pressureL;
  final ImuData imuL;
  final String label;

  GaitRecord({
    required this.timestamp,
    required this.pressureR,
    required this.imuR,
    required this.pressureL,
    required this.imuL,
    required this.label,
  });

  /// 转CSV行（26列）
  List<String> toCsvRow() {
    String f1(double v) => v.toStringAsFixed(1);
    String f3(double v) => v.toStringAsFixed(3);

    return [
      timestamp,
      // 右脚压力 3
      f1(pressureR.p1), f1(pressureR.p2), f1(pressureR.p3),
      // 右脚加速度 3
      f3(imuR.accX), f3(imuR.accY), f3(imuR.accZ),
      // 右脚角速度 3
      f1(imuR.gyroX), f1(imuR.gyroY), f1(imuR.gyroZ),
      // 右脚欧拉角 3
      f1(imuR.roll), f1(imuR.pitch), f1(imuR.yaw),
      // 左脚压力 3
      f1(pressureL.p1), f1(pressureL.p2), f1(pressureL.p3),
      // 左脚加速度 3
      f3(imuL.accX), f3(imuL.accY), f3(imuL.accZ),
      // 左脚角速度 3
      f1(imuL.gyroX), f1(imuL.gyroY), f1(imuL.gyroZ),
      // 左脚欧拉角 3
      f1(imuL.roll), f1(imuL.pitch), f1(imuL.yaw),
      // 标签
      label,
    ];
  }

  /// CSV表头
  static List<String> csvHeader() => [
    'timestamp',
    'P_first_meta_R', 'P_Fifth_meta_R', 'P_heel_R',
    'acc_x_R', 'acc_y_R', 'acc_z_R',
    'ave_x_R', 'ave_y_R', 'ave_z_R',
    'ang_x_R', 'ang_y_R', 'ang_z_R',
    'P_first_meta_L', 'P_Fifth_meta_L', 'P_heel_L',
    'acc_x_L', 'acc_y_L', 'acc_z_L',
    'ave_x_L', 'ave_y_L', 'ave_z_L',
    'ang_x_L', 'ang_y_L', 'ang_z_L',
    'Label',
  ];
}
