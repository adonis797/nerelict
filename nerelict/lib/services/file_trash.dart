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
/// - 旁边写一个 `<回收站路径>.origin` 记下原路径——全盘浏览里删掉的文件本来
///   不在下载目录，撤销时必须回到它原来的目录，否则等于「恢复到一个陌生位置」；
/// - 保留 7 天，之后的在扫描时顺手清掉；
/// - 回收站目录以 `.` 开头，扫描会跳过它，不会出现在列表里。
class FileTrash {
  const FileTrash._();

  /// 保留时长：够用户发现误删并撤回，又不至于长期占地方。
  static const Duration keepFor = Duration(days: 7);

  static const String dirName = '.trash';

  /// 原路径旁注的后缀。
  static const String originSuffix = '.origin';

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
      if (!await _moveFile(file, target)) return null;
      // 旁注写在搬完之后：搬失败就不该留下一条指向用户的假记录
      try {
        await File('$target$originSuffix').writeAsString(path, flush: true);
      } catch (_) {}
      return target;
    } catch (_) {
      return null;
    }
  }

  /// 搬运一个文件：先试 `rename`，失败再「复制 + 删源」。
  ///
  /// Android 11+ 上应用私有目录（`Android/data/<pkg>`）与公共目录（`Download`、
  /// `DCIM` …）常常不在同一个挂载点，`rename` 会抛 `EXDEV`。全盘浏览里的文件
  /// 都在公共目录，所以这里必须留一条跨挂载点的退路——宁可多一次 IO，
  /// 也不能让「删除可撤销」在真机上直接失效。
  static Future<bool> _moveFile(File from, String target) async {
    try {
      await from.rename(target);
      return true;
    } catch (_) {
      // 落到复制路径
    }
    try {
      await from.copy(target);
    } catch (_) {
      return false;
    }
    try {
      await from.delete();
    } catch (_) {
      // 源没删掉就等于没删成功：清掉副本，让调用方走原来的失败分支
      try {
        await File(target).delete();
      } catch (_) {}
      return false;
    }
    return true;
  }

  /// 从回收站还原，返回还原后的路径。
  ///
  /// 回收站文件名格式是 `<时间戳>_<原名>`，还原时去掉前缀。
  /// 有 `.origin` 旁注就回原目录（全盘删除的文件靠它回到原处），
  /// 没有则退回下载目录——旧版回收站里的条目仍能按原行为恢复。
  /// 已经不存在的条目返回 null，调用方据此提示「撤销失败」。
  static Future<String?> restore(String trashPath) async {
    try {
      final file = File(trashPath);
      if (!await file.exists()) return null;
      final name = trashPath.split(Platform.pathSeparator).last;
      final cut = name.indexOf('_');
      final original = cut > 0 ? name.substring(cut + 1) : name;

      final originDir = await _readOrigin(trashPath);
      final base = originDir != null && originDir.isNotEmpty
          ? Directory(originDir)
          : await appDownloadDir();
      if (!await base.exists()) await base.create(recursive: true);

      var target = joinPath(base.path, original);
      if (await File(target).exists()) {
        // 同名文件已经回来了：加个后缀，绝不覆盖
        final dot = original.lastIndexOf('.');
        final stem = dot > 0 ? original.substring(0, dot) : original;
        final ext = dot > 0 ? original.substring(dot) : '';
        target = joinPath(
            base.path, '${stem}_恢复_${DateTime.now().millisecondsSinceEpoch}$ext');
      }
      // 还原同样可能跨挂载点，走与删除一样的搬运逻辑
      if (!await _moveFile(file, target)) return null;
      await _clearOrigin(trashPath);
      return target;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _readOrigin(String trashPath) async {
    try {
      final note = File('$trashPath$originSuffix');
      if (!await note.exists()) return null;
      final text = (await note.readAsString()).trim();
      if (text.isEmpty) return null;
      final i = text.lastIndexOf(Platform.pathSeparator);
      return i > 0 ? text.substring(0, i) : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _clearOrigin(String trashPath) async {
    try {
      final note = File('$trashPath$originSuffix');
      if (await note.exists()) await note.delete();
    } catch (_) {}
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
