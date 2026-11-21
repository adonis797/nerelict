import 'dart:io';

import 'app_paths.dart';
import 'local_media_scanner.dart';

/// 删除先落进回收站，而不是直接 `delete()`。
///
/// 起因是一次真实的误删：在文件页上误触删除后，成品视频直接从设备上消失了，
/// 没有任何挽回余地。对「下载目录」这种用户自己攒出来的内容，
/// 删除应该是可撤销的，而不是不可逆的。
///
/// 规则刻意简单：
/// - 移到 `<下载目录>/.trash/`，文件名前加时间戳避免重名；
/// - 保留 7 天，之后的在扫描时顺手清掉；
/// - 回收站目录以 `.` 开头，扫描会跳过它，不会出现在列表里。
class FileTrash {
  const FileTrash._();

  /// 保留时长：够用户发现误删并撤回，又不至于长期占地方。
  static const Duration keepFor = Duration(days: 7);

  static const String dirName = '.trash';

  /// 把文件移进回收站，返回回收站里的路径；失败返回 null（调用方决定是否硬删）。
  static Future<String?> moveToTrash(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final base = await appDownloadDir();
      final trash = Directory(joinPath(base.path, dirName));
      if (!await trash.exists()) await trash.create(recursive: true);
      final name = path.split(Platform.pathSeparator).last;
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final target = joinPath(trash.path, '${stamp}_$name');
      await file.rename(target);
      return target;
    } catch (_) {
      return null;
    }
  }

  /// 从回收站还原到原目录，返回还原后的路径。
  ///
  /// 回收站文件名格式是 `<时间戳>_<原名>`，还原时去掉前缀；
  /// 已经不存在的条目返回 null，调用方据此提示「撤销失败」。
  static Future<String?> restore(String trashPath) async {
    try {
      final file = File(trashPath);
      if (!await file.exists()) return null;
      final base = await appDownloadDir();
      if (!await base.exists()) await base.create(recursive: true);
      final name = trashPath.split(Platform.pathSeparator).last;
      final cut = name.indexOf('_');
      final original = cut > 0 ? name.substring(cut + 1) : name;
      var target = joinPath(base.path, original);
      if (await File(target).exists()) {
        // 同名文件已经回来了：加个后缀，绝不覆盖
        final dot = original.lastIndexOf('.');
        final stem = dot > 0 ? original.substring(0, dot) : original;
        final ext = dot > 0 ? original.substring(dot) : '';
        target = joinPath(
            base.path, '${stem}_恢复_${DateTime.now().millisecondsSinceEpoch}$ext');
      }
      await file.rename(target);
      return target;
    } catch (_) {
      return null;
    }
  }

  /// 清掉超过保留时长的条目；顺便删掉空目录。
  static Future<int> purgeExpired({Duration? keep}) async {
    final limit = keep ?? keepFor;
    var removed = 0;
    try {
      final base = await appDownloadDir();
      final trash = Directory(joinPath(base.path, dirName));
      if (!await trash.exists()) return 0;
      final now = DateTime.now();
      await for (final entity in trash.list(followLinks: false)) {
        if (entity is! File) continue;
        try {
          final stat = await entity.stat();
          if (now.difference(stat.modified) > limit) {
            await entity.delete();
            removed++;
          }
        } catch (_) {
          // 单个条目删不掉就留着，下次再说
        }
      }
    } catch (_) {}
    return removed;
  }
}
