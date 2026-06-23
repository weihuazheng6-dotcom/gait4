import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'home_screen.dart';

/// 权限申请入口页
class PermissionGate extends StatefulWidget {
  const PermissionGate({super.key});

  @override
  State<PermissionGate> createState() => _PermissionGateState();
}

class _PermissionGateState extends State<PermissionGate> {
  bool _checking = true;
  bool _granted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _requestPermissions());
  }

  Future<void> _requestPermissions() async {
    try {
      final statuses = await [
        Permission.bluetooth,
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.bluetoothAdvertise,
        Permission.location,
        Permission.locationWhenInUse,
        Permission.storage,
      ].request();

      final allOk = statuses.values.every((s) =>
          s.isGranted || s.isLimited || s.isRestricted);

      setState(() {
        _granted = allOk;
        _checking = false;
      });
    } catch (e) {
      debugPrint('[Permission] 申请异常: $e');
      setState(() {
        _granted = false;
        _checking = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: Color(0xFF1565C0)),
              SizedBox(height: 16),
              Text('正在申请权限...', style: TextStyle(fontSize: 14)),
            ],
          ),
        ),
      );
    }

    if (!_granted) {
      return Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.warning_amber_rounded, size: 64, color: Colors.orange),
                const SizedBox(height: 16),
                const Text(
                  '需要蓝牙与定位权限才能使用本应用',
                  style: TextStyle(fontSize: 16),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: _requestPermissions,
                  child: const Text('重新申请权限'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => openAppSettings(),
                  child: const Text('打开系统设置'),
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () {
                    setState(() => _granted = true);
                  },
                  child: const Text('跳过（可能功能受限）'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return const HomeScreen();
  }
}
