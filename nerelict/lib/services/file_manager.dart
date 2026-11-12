import 'dart:io';
import 'app_paths.dart';

/// 下载目录里一个文件的元信息（不向界面暴露完整路径）。
class ManagedFile {
  const ManagedFile({
    required this.path,
    required this.name,
    required this.size,
    required this.modifiedAt,
  });

  final String path;
  final String name;
  final int size;
  final DateTime modifiedAt;

  String get extension {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(dot).toLowerCase() : '';
  }

  String get typeLabel => switch (extension) {
        '.mp4' || '.m4v' => 'MP4 视频',
        '.ts' => 'TS 视频',
        '.webm' => 'WebM 视频',
        '.mkv' => 'MKV 视频',
        '.mov' => 'MOV 视频',
        '.flv' => 'FLV 视频',
        '.avi' => 'AVI 视频',
        '.mp3' => 'MP3 音频',
        '.m4a' => 'M4A 音频',
        '.aac' => 'AAC 音频',
        '.flac' => 'FLAC 音频',
        '.wav' => 'WAV 音频',
        '.jpg' || '.jpeg' => 'JPEG 图片',
        '.png' => 'PNG 图片',
        '.webp' => 'WebP 图片',
        '.gif' => 'GIF 图片',
        '.pdf' => 'PDF 文档',
        '.txt' || '.md' => '文本文件',
        '.json' => 'JSON 文件',
        '.zip' || '.rar' || '.7z' => '压缩包',
        '.srt' || '.vtt' => '字幕文件',
        '' => '文件',
        _ => '${extension.substring(1).toUpperCase()} 文件',
      };

  /// 只有视频能交给 Nerelict 播放，其余类型用于文件管理
  bool get isPlayable => const <String>{
        '.mp4',
        '.m4v',
        '.ts',
        '.webm',
        '.mkv',
        '.mov',
        '.flv',
        '.avi',
        '.3gp',
      }.contains(extension);

  String get sizeText {
    if (size <= 0) return '—';
    const units = <String>['B', 'KB', 'MB', 'GB'];
    var v = size.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 100 || i == 0 ? 0 : 1)} ${units[i]}';
  }

  String get dateText {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${modifiedAt.year}-${two(modifiedAt.month)}-${two(modifiedAt.day)} '
        '${two(modifiedAt.hour)}:${two(modifiedAt.minute)}';
  }
}

class FileManagerException implements Exception {
  const FileManagerException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 下载目录文件的只读查看 / 重命名 / 删除。
///
/// 只操作本软件下载目录里的成品文件；所有写操作都返回新路径或抛异常，
/// 由 AppState 统一同步任务、进度记忆、收藏与本地视频列表，避免状态不一致。
class FileManager {
  FileManager._();

  static final RegExp _invalidChars = RegExp(r'[/\\:*?"<>|]');

  static String _fileName(String path) {
    final parts = path.split(RegExp(r'[/\\]'));
    return parts.isEmpty ? '' : parts.last;
  }

  static String _extension(String name) {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(dot).toLowerCase() : '';
  }

  static Future<ManagedFile?> inspect(String path) async {
    try {
      final file = File(path);
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) return null;
      return ManagedFile(
        path: path,
        name: _fileName(path),
        size: stat.size,
        modifiedAt: stat.modified,
      );
    } catch (_) {
      return null;
    }
  }

  /// 重命名：保留原扩展名，自动清理非法字符，返回新路径。
  static Future<String> rename(String path, String desiredName) async {
    final file = File(path);
    if (!await file.exists()) {
      throw const FileManagerException('文件不存在或已被删除');
    }
    final original = _fileName(path);
    final ext = _extension(original);
    var base = desiredName.replaceAll(_invalidChars, '_').trim();
    while (base.startsWith('.')) {
      base = base.substring(1).trim();
    }
    if (base.isEmpty) {
      throw const FileManagerException('文件名不能为空');
    }
    if (base.length > 80) base = base.substring(0, 80).trim();
    if (ext.isNotEmpty) {
      if (base.toLowerCase().endsWith(ext)) {
        base = base.substring(0, base.length - ext.length).trim();
      } else {
        // 不允许改扩展名，否则应用内播放与转换状态会失效
        final dot = base.lastIndexOf('.');
        if (dot > 0) base = base.substring(0, dot).trim();
      }
    }
    if (base.isEmpty) {
      throw const FileManagerException('文件名不能为空');
    }
    final newName = '$base$ext';
    if (newName == original) return path;

    final target = File(joinPath(file.parent.path, newName));
    if (await target.exists()) {
      throw const FileManagerException('已存在同名文件，请换一个名称');
    }
    try {
      final renamed = await file.rename(target.path);
      return renamed.path;
    } catch (e) {
      throw FileManagerException('重命名失败：$e');
    }
  }

  static Future<void> delete(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (e) {
      throw FileManagerException('删除失败：$e');
    }
  }
}
