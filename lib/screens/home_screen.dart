import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/gait_data.dart';
import '../services/ble_manager.dart';
import '../services/csv_export.dart';
import 'scan_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _labelCtrl = TextEditingController(text: '0');

  @override
  void dispose() {
    _labelCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('步态检测'),
        actions: [
          Consumer<BleManager>(
            builder: (_, ble, __) => Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Text(
                  '${ble.connectedCount}/4',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
        ],
      ),
      body: Consumer<BleManager>(
        builder: (context, ble, _) {
          return Column(
            children: [
              // 录制状态栏
              if (ble.isRecording) _buildRecordingBanner(ble),
              // 设备卡片网格
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: GridView.count(
                    crossAxisCount: 2,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                    childAspectRatio: 0.78,
                    children: [
                      _buildDeviceCard(ble, DeviceRole.pressureLeft),
                      _buildDeviceCard(ble, DeviceRole.pressureRight),
                      _buildDeviceCard(ble, DeviceRole.imuLeft),
                      _buildDeviceCard(ble, DeviceRole.imuRight),
                    ],
                  ),
                ),
              ),
              // 底部操作栏
              _buildBottomBar(ble),
            ],
          );
        },
      ),
    );
  }

  Widget _buildRecordingBanner(BleManager ble) {
    return Container(
      width: double.infinity,
      color: Colors.red.shade50,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.fiber_manual_record, color: Colors.red, size: 16),
          const SizedBox(width: 6),
          Text(
            '录制中 · ${ble.recordCount} 条 · 标签: ${ble.currentLabel}',
            style: const TextStyle(fontSize: 14, color: Colors.red),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceCard(BleManager ble, DeviceRole role) {
    final ctx = ble.getContext(role);
    final isPressure = role.isPressure;

    Color statusColor;
    switch (ctx.status) {
      case ConnectionStatus.connected: statusColor = Colors.green; break;
      case ConnectionStatus.connecting: statusColor = Colors.orange; break;
      case ConnectionStatus.failed: statusColor = Colors.red; break;
      default: statusColor = Colors.grey;
    }

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _onCardTap(ble, role),
        onLongPress: () => _onCardLongPress(ble, role),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    isPressure ? Icons.compress : Icons.rotate_right,
                    size: 18,
                    color: const Color(0xFF1565C0),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      role.label,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                ctx.status.label + (ctx.deviceName.isNotEmpty ? ' · ${ctx.deviceName}' : ''),
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                overflow: TextOverflow.ellipsis,
              ),
              const Divider(height: 12),
              Expanded(
                child: isPressure
                    ? _buildPressureData(ctx.pressure)
                    : _buildImuData(ctx.imu),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPressureData(PressureData p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _dataRow('P1', p.p1.toStringAsFixed(1)),
        _dataRow('P2', p.p2.toStringAsFixed(1)),
        _dataRow('P3', p.p3.toStringAsFixed(1)),
      ],
    );
  }

  Widget _buildImuData(ImuData i) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionLabel('加速度 g'),
          _dataRow('X', i.accX.toStringAsFixed(3)),
          _dataRow('Y', i.accY.toStringAsFixed(3)),
          _dataRow('Z', i.accZ.toStringAsFixed(3)),
          const SizedBox(height: 4),
          _sectionLabel('角速度 °/s'),
          _dataRow('X', i.gyroX.toStringAsFixed(1)),
          _dataRow('Y', i.gyroY.toStringAsFixed(1)),
          _dataRow('Z', i.gyroZ.toStringAsFixed(1)),
          const SizedBox(height: 4),
          _sectionLabel('欧拉角 °'),
          _dataRow('R', i.roll.toStringAsFixed(1)),
          _dataRow('P', i.pitch.toStringAsFixed(1)),
          _dataRow('Y', i.yaw.toStringAsFixed(1)),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
    padding: const EdgeInsets.only(top: 2, bottom: 2),
    child: Text(
      text,
      style: TextStyle(fontSize: 10, color: Colors.grey.shade600, fontWeight: FontWeight.w600),
    ),
  );

  Widget _dataRow(String name, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            child: Text(
              name,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 13,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar(BleManager ble) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        border: Border(top: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 第一行：标签输入
          Row(
            children: [
              const Text('标签:', style: TextStyle(fontSize: 14)),
              const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  height: 40,
                  child: TextField(
                    controller: _labelCtrl,
                    decoration: const InputDecoration(
                      hintText: '0-9 或 自定义',
                      isDense: true,
                    ),
                    style: const TextStyle(fontSize: 14),
                    onChanged: (v) => ble.setLabel(v),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // 快捷标签按钮 0-9
              SizedBox(
                height: 40,
                child: DropdownButton<String>(
                  value: ['0','1','2','3','4','5','6','7','8','9']
                      .contains(_labelCtrl.text) ? _labelCtrl.text : null,
                  hint: const Text('快速', style: TextStyle(fontSize: 12)),
                  items: List.generate(10, (i) => '$i')
                      .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) {
                      setState(() => _labelCtrl.text = v);
                      ble.setLabel(v);
                    }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 第二行：操作按钮
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const ScanScreen()),
                    );
                  },
                  icon: const Icon(Icons.bluetooth_searching, size: 16),
                  label: const Text('扫描'),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: ble.isRecording ? Colors.red : const Color(0xFF1565C0),
                  ),
                  onPressed: () {
                    if (ble.isRecording) {
                      ble.stopRecording();
                    } else {
                      ble.startRecording();
                    }
                  },
                  icon: Icon(ble.isRecording ? Icons.stop : Icons.play_arrow, size: 16),
                  label: Text(ble.isRecording ? '停止' : '录制'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: ble.recordCount == 0
                      ? null
                      : () => _exportCsv(ble),
                  icon: const Icon(Icons.file_download, size: 16),
                  label: Text('导出(${ble.recordCount})'),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                  ),
                  onPressed: ble.connectedCount == 0
                      ? null
                      : () => ble.disconnectAll(),
                  icon: const Icon(Icons.link_off, size: 16),
                  label: const Text('断开所有'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _onCardTap(BleManager ble, DeviceRole role) {
    final ctx = ble.getContext(role);
    if (ctx.status == ConnectionStatus.connected) {
      // 已连接，询问断开
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(role.label),
          content: Text('已连接: ${ctx.deviceName}\n是否断开？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                ble.disconnectRole(role);
              },
              child: const Text('断开', style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      );
    } else {
      // 未连接，进入扫描
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ScanScreen(preselectedRole: role),
        ),
      );
    }
  }

  void _onCardLongPress(BleManager ble, DeviceRole role) {
    final ctx = ble.getContext(role);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(role.label),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('状态: ${ctx.status.label}'),
            if (ctx.deviceName.isNotEmpty) Text('设备: ${ctx.deviceName}'),
            if (ctx.deviceId.isNotEmpty) Text('ID: ${ctx.deviceId}'),
            if (ctx.lastUpdate != null)
              Text('最近更新: ${ctx.lastUpdate!.toIso8601String().substring(11, 19)}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _exportCsv(BleManager ble) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    final path = await CsvExportService.exportToFile(ble.records);
    if (!mounted) return;
    Navigator.pop(context);

    if (path == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('导出失败')),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('导出成功'),
        content: Text('文件路径:\n$path\n\n共 ${ble.records.length} 条记录'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await CsvExportService.exportAndShare(ble.records);
            },
            child: const Text('分享'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              ble.clearRecords();
            },
            child: const Text('清空数据', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}
