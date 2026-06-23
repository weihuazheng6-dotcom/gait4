import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'permission_gate.dart';

class UserInfoScreen extends StatefulWidget {
  const UserInfoScreen({super.key});

  @override
  State<UserInfoScreen> createState() => _UserInfoScreenState();
}

class _UserInfoScreenState extends State<UserInfoScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _ageCtrl = TextEditingController();
  final _heightCtrl = TextEditingController();
  final _weightCtrl = TextEditingController();
  String _gender = '男';

  @override
  void dispose() {
    _nameCtrl.dispose();
    _ageCtrl.dispose();
    _heightCtrl.dispose();
    _weightCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState!.validate()) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const PermissionGate()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('用户信息')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline,
                          color: Color(0xFF1565C0), size: 20),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          '请填写基本信息，用于步态数据分析',
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // 姓名
              TextFormField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  labelText: '姓名',
                  prefixIcon: Icon(Icons.person_outline),
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? '请输入姓名' : null,
              ),
              const SizedBox(height: 16),

              // 性别
              InputDecorator(
                decoration: const InputDecoration(
                  labelText: '性别',
                  prefixIcon: Icon(Icons.wc_outlined),
                ),
                child: Row(
                  children: ['男', '女'].map((g) {
                    return Expanded(
                      child: RadioListTile<String>(
                        title: Text(g),
                        value: g,
                        groupValue: _gender,
                        onChanged: (v) => setState(() => _gender = v!),
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 16),

              // 年龄
              TextFormField(
                controller: _ageCtrl,
                decoration: const InputDecoration(
                  labelText: '年龄',
                  suffixText: '岁',
                  prefixIcon: Icon(Icons.cake_outlined),
                ),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                validator: (v) {
                  final n = int.tryParse(v ?? '');
                  if (n == null || n < 1 || n > 120) return '请输入有效年龄';
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // 身高
              TextFormField(
                controller: _heightCtrl,
                decoration: const InputDecoration(
                  labelText: '身高',
                  suffixText: 'cm',
                  prefixIcon: Icon(Icons.height),
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                validator: (v) {
                  final n = double.tryParse(v ?? '');
                  if (n == null || n < 50 || n > 250) return '请输入有效身高';
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // 体重
              TextFormField(
                controller: _weightCtrl,
                decoration: const InputDecoration(
                  labelText: '体重',
                  suffixText: 'kg',
                  prefixIcon: Icon(Icons.monitor_weight_outlined),
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                validator: (v) {
                  final n = double.tryParse(v ?? '');
                  if (n == null || n < 10 || n > 300) return '请输入有效体重';
                  return null;
                },
              ),
              const SizedBox(height: 32),

              // 提交按钮
              ElevatedButton.icon(
                onPressed: _submit,
                icon: const Icon(Icons.arrow_forward, size: 18),
                label: const Text('开始检测'),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
