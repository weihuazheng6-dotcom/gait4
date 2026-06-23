import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';
import '../models/gait_data.dart';
import '../services/ble_manager.dart';

class ScanScreen extends StatefulWidget {
  final DeviceRole? preselectedRole;
  const ScanScreen({super.key, this.preselectedRole});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ble = context.read<BleManager>();
      if (!ble.isScanning) {
        ble.startScan(timeoutSec: 12);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('扫描设备'),
        actions: [
          Consumer<BleManager>(
            builder: (_, ble, __) => IconButton(
              icon: Icon(ble.isScanning ? Icons.stop : Icons.refresh),
              onPressed: () {
                if (ble.isScanning) {
                  ble.stopScan();
                } else {
                  ble.startScan(timeoutSec: 12);
                }
              },
            ),
          ),
        ],
      ),
      body: Consumer<BleManager>(
        builder: (context, ble, _) {
          return Column(
            children: [
              if (ble.isScanning)
                const LinearProgressIndicator(color: Color(0xFF1565C0)),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(
                      ble.isScanning ? Icons.bluetooth_searching : Icons.bluetooth,
                      color: const Color(0xFF1565C0),
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      ble.isScanning
                          ? '扫描中... 已找到${ble.scanResults.length}个'
                          : '扫描完成 · ${ble.scanResults.length}个设备',
                      style: const TextStyle(fontSize: 14),
                    ),
                    if (widget.preselectedRole != null) ...[
                      const Spacer(),
                      Chip(
                        label: Text(
                          '分配给: ${widget.preselectedRole!.label}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        backgroundColor: const Color(0xFFE3F2FD),
                      ),
                    ],
                  ],
                ),
              ),
              Expanded(
                child: ble.scanResults.isEmpty
                    ? Center(
                        child: Text(
                          ble.isScanning ? '搜索中...' : '暂无设备',
                          style: TextStyle(color: Colors.grey.shade600),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        itemCount: ble.scanResults.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) => _buildDeviceTile(ble, ble.scanResults[i]),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildDeviceTile(BleManager ble, ScanResult r) {
    final name = r.device.platformName.isNotEmpty
        ? r.device.platformName
        : (r.advertisementData.advName.isNotEmpty
            ? r.advertisementData.advName
            : '未知设备');
    final id = r.device.remoteId.str;
    final rssi = r.rssi;

    // 判断已分配给哪个角色
    DeviceRole? assignedRole;
    for (final role in DeviceRole.values) {
      final ctx = ble.getContext(role);
      if (ctx.deviceId == id && ctx.status != ConnectionStatus.disconnected) {
        assignedRole = role;
        break;
      }
    }

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: _rssiColor(rssi).withOpacity(0.15),
        child: Icon(Icons.bluetooth, color: _rssiColor(rssi), size: 20),
      ),
      title: Text(
        name,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        '$id · RSSI $rssi dBm',
        style: const TextStyle(fontSize: 11),
      ),
      trailing: assignedRole != null
          ? Chip(
              label: Text(assignedRole.label, style: const TextStyle(fontSize: 11)),
              backgroundColor: Colors.green.shade50,
              side: BorderSide(color: Colors.green.shade200),
            )
          : const Icon(Icons.chevron_right),
      onTap: () => _onTapDevice(ble, r),
      onLongPress: () => _showRolePicker(ble, r),
    );
  }

  Color _rssiColor(int rssi) {
    if (rssi > -60) return Colors.green;
    if (rssi > -80) return Colors.orange;
    return Colors.grey;
  }

  Future<void> _onTapDevice(BleManager ble, ScanResult r) async {
    if (widget.preselectedRole != null) {
      await _connectTo(ble, r, widget.preselectedRole!);
    } else {
      _showRolePicker(ble, r);
    }
  }

  void _showRolePicker(BleManager ble, ScanResult r) {
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '选择角色',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            const Divider(height: 1),
            ...DeviceRole.values.map((role) {
              final ctx = ble.getContext(role);
              final isOccupied = ctx.status == ConnectionStatus.connected;
              return ListTile(
                leading: Icon(
                  role.isPressure ? Icons.compress : Icons.rotate_right,
                  color: const Color(0xFF1565C0),
                ),
                title: Text(role.label),
                subtitle: isOccupied ? Text('已连接: ${ctx.deviceName}') : null,
                trailing: isOccupied
                    ? const Icon(Icons.warning, color: Colors.orange, size: 18)
                    : null,
                onTap: () {
                  Navigator.pop(context);
                  _connectTo(ble, r, role);
                },
              );
            }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _connectTo(BleManager ble, ScanResult r, DeviceRole role) async {
    await ble.stopScan();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Color(0xFF1565C0)),
            const SizedBox(height: 16),
            Text('连接 ${role.label}...', style: const TextStyle(fontSize: 14)),
          ],
        ),
      ),
    );

    final ok = await ble.connectDevice(r.device, role);
    if (!mounted) return;
    Navigator.pop(context); // 关闭loading

    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${role.label} 连接成功')),
      );
      if (widget.preselectedRole != null) {
        Navigator.pop(context); // 返回主页
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${role.label} 连接失败'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  void dispose() {
    // 离开扫描页时停止扫描
    try {
      context.read<BleManager>().stopScan();
    } catch (_) {}
    super.dispose();
  }
}

