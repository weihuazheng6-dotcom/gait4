import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/gait_data.dart';

class CsvExportService {
  /// 导出CSV到本地文件，返回文件路径
  static Future<String?> exportToFile(List<GaitRecord> records) async {
    if (records.isEmpty) {
      debugPrint('[CSV] 没有数据');
      return null;
    }

    try {
      final dir = await _getExportDir();
      final ts = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .replaceAll('.', '-');
      final filename = 'gait_data_$ts.csv';
      final file = File('${dir.path}/$filename');

      final buf = StringBuffer();
      // 表头
      buf.writeln(GaitRecord.csvHeader().join(','));
      // 数据行
      for (final r in records) {
        buf.writeln(r.toCsvRow().map(_escapeCsv).join(','));
      }

      await file.writeAsString(buf.toString(), flush: true);
      debugPrint('[CSV] 已导出: ${file.path}');
      return file.path;
    } catch (e) {
      debugPrint('[CSV] 导出失败: $e');
      return null;
    }
  }

  /// 导出并分享
  static Future<bool> exportAndShare(List<GaitRecord> records) async {
    final path = await exportToFile(records);
    if (path == null) return false;
    try {
      await Share.shareXFiles(
        [XFile(path)],
        subject: '步态检测数据',
        text: '共${records.length}条记录',
      );
      return true;
    } catch (e) {
      debugPrint('[CSV] 分享失败: $e');
      return false;
    }
  }

  /// 获取导出目录（优先公共Documents）
  static Future<Directory> _getExportDir() async {
    // Android: /storage/emulated/0/Documents
    try {
      final docDir = Directory('/sdcard/Documents');
      if (await docDir.exists() || await _tryCreate(docDir)) {
        return docDir;
      }
    } catch (_) {}

    // 回退到应用外部存储
    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) return ext;
    } catch (_) {}

    // 最后回退到应用私有目录
    return await getApplicationDocumentsDirectory();
  }

  static Future<bool> _tryCreate(Directory dir) async {
    try {
      await dir.create(recursive: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  static String _escapeCsv(String v) {
    if (v.contains(',') || v.contains('"') || v.contains('\n')) {
      return '"${v.replaceAll('"', '""')}"';
    }
    return v;
  }
}
