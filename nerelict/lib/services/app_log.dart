import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'app_paths.dart';

/// 轻量诊断日志：环形缓冲 + 导出。
///
/// 项目里有很多「失败也要继续」的分支，过去一律 `catch (_) {}`，
/// 出问题（比如转 MP4 丢音轨）时只能靠猜。这里把关键路径统一记一行，
/// 内存中保留最近 [maxLines] 条，需要时导出成文件给开发者看。
class AppLog {
  AppLog._();

  static final AppLog instance = AppLog._();

  static const int maxLines = 600;

  final Queue<String> _lines = Queue<String>();
  int _dropped = 0;

  List<String> get lines => _lines.toList(growable: false);
  int get count => _lines.length;
  int get dropped => _dropped;

  void d(String tag, String message) => _add('D', tag, message);

  void w(String tag, String message) => _add('W', tag, message);

  void e(String tag, String message, [Object? error]) {
    final extra = error == null ? '' : ' | $error';
    _add('E', tag, '$message$extra');
  }

  void _add(String level, String tag, String message) {
    final now = DateTime.now();
    final t = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}.'
        '${now.millisecond.toString().padLeft(3, '0')}';
    _lines.add('$t $level/$tag $message');
    while (_lines.length > maxLines) {
      _lines.removeFirst();
      _dropped++;
    }
    // release 下也打到 logcat，方便 adb 现场排查（格式固定，便于 grep）
    // ignore: avoid_print
    print('NERELICT $t $level/$tag $message');
    if (kDebugMode) {
      debugPrint('[$level/$tag] $message');
    }
  }

  void clear() {
    _lines.clear();
    _dropped = 0;
  }

  /// 导出到应用私有目录 logs/，保留最近 5 个文件，返回文件路径。
  Future<String?> export({String? note}) async {
    try {
      final base = await getApplicationSupportDirectory();
      final dir = Directory(joinPath(base.path, 'logs'));
      if (!await dir.exists()) await dir.create(recursive: true);
      final now = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final name = 'nerelict-${now.year}${two(now.month)}${two(now.day)}-'
          '${two(now.hour)}${two(now.minute)}${two(now.second)}.log';
      final file = File(joinPath(dir.path, name));
      final header = StringBuffer()
        ..writeln('# Nerelict diagnostics')
        ..writeln('# exported: ${now.toIso8601String()}')
        ..writeln('# lines: ${_lines.length} (dropped $_dropped)')
        ..writeln('# platform: ${Platform.operatingSystem} '
            '${Platform.operatingSystemVersion}');
      if (note != null && note.isNotEmpty) {
        header.writeln('# note: $note');
      }
      header.writeln('---');
      await file.writeAsString(
        '${header.toString()}${_lines.join('\n')}\n',
        flush: true,
      );
      await _prune(dir);
      return file.path;
    } catch (e) {
      eLog('AppLog', 'export failed', e);
      return null;
    }
  }

  Future<void> _prune(Directory dir) async {
    try {
      final files = await dir
          .list()
          .where((e) => e is File && e.path.endsWith('.log'))
          .cast<File>()
          .toList();
      if (files.length <= 5) return;
      files.sort((a, b) => a.path.compareTo(b.path));
      for (var i = 0; i < files.length - 5; i++) {
        try {
          await files[i].delete();
        } catch (_) {}
      }
    } catch (_) {}
  }
}

/// 便捷函数：`logD('Download', '...')`
void logD(String tag, String message) => AppLog.instance.d(tag, message);
void logW(String tag, String message) => AppLog.instance.w(tag, message);
void logE(String tag, String message, [Object? error]) =>
    AppLog.instance.e(tag, message, error);

/// 避免在 AppLog 内部再调用扩展方法时命名冲突
void eLog(String tag, String message, Object? error) =>
    AppLog.instance.e(tag, message, error);

/// 把未捕获异常也收进日志（不改变原有崩溃行为）
void installGlobalErrorLogging() {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    AppLog.instance.e(
      'Flutter',
      details.exceptionAsString(),
      details.stack?.toString().split('\n').take(6).join(' | '),
    );
    previous?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLog.instance.e('Platform', '$error',
        stack.toString().split('\n').take(6).join(' | '));
    return false; // 交回默认处理
  };
}
