import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'file_kinds.dart';
import 'app_paths.dart';

export 'file_kinds.dart';

/// 下载目录里的一个文件（任意类型），只暴露元信息，不展示完整路径。
class LocalFile {
  const LocalFile({
    required this.path,
    required this.name,
    required this.size,
    required this.modifiedAt,
    required this.kind,
  });

  final String path;
  final String name;
  final int size;
  final DateTime modifiedAt;
  final LocalFileKind kind;

  String get extension {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(dot).toLowerCase() : '';
  }

  String get title {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// 只有视频能在 MA8N 里直接播放；其他类型走文件管理（信息 / 重命名 / 删除）
  bool get isPlayable => kind == LocalFileKind.video;

  bool get isMp4 => extension == '.mp4';

  /// 具体类型文案：优先给已知扩展名一个更准确的名字
  String get typeLabel {
    final ext = extension;
    return switch (ext) {
      '.mp4' || '.m4v' => 'MP4 视频',
      '.ts' => 'TS 视频',
      '.webm' => 'WebM 视频',
      '.mkv' => 'MKV 视频',
      '.mov' => 'MOV 视频',
      '.flv' => 'FLV 视频',
      '.avi' => 'AVI 视频',
      '.mp3' => 'MP3 音频',
      '.m4a' => 'M4A 音频',
      '.flac' => 'FLAC 音频',
      '.wav' => 'WAV 音频',
      '.pdf' => 'PDF 文档',
      '.txt' || '.md' => '文本文件',
      '.zip' || '.rar' || '.7z' => '压缩包',
      '' => kind.label,
      _ => ext.substring(1).toUpperCase(),
    };
  }

  String get sizeText {
    if (size <= 0) return '—';
    const units = ['B', 'KB', 'MB', 'GB'];
    var v = size.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 100 || i == 0 ? 0 : 1)} ${units[i]}';
  }

  static LocalFileKind kindOf(String name) => kindOfName(name);
}

/// 应用下载目录（与下载器的输出目录保持同一个来源，避免两处不一致）
Future<Directory> appDownloadDir() async {
  final base = await getExternalStorageDirectory() ??
      await getApplicationDocumentsDirectory();
  return Directory(joinPath(base.path, kDownloadDirName));
}

/// 一次目录扫描的结果。
///
/// [complete] 为 false 表示枚举或读取过程中出错，[files] 只是部分结果；
/// 调用方不应拿它覆盖上一次的完整列表，否则文件会在界面上「凭空消失」。
class LocalFileScanResult {
  const LocalFileScanResult({
    required this.files,
    required this.complete,
    this.errors = 0,
  });

  final List<LocalFile> files;

  /// 是否完整遍历了下载目录（单个文件 stat 失败也会置为 false）
  final bool complete;
  final int errors;
}

/// 扫描下载目录里的全部文件（不再只限视频），按修改时间倒序返回。
/// 只读取文件元信息，不解码、不展示完整路径；隐藏文件与临时分片目录跳过。
///
/// 与 [scanLocalFiles] 的区别：出错时不吞掉异常，而是明确返回
/// [LocalFileScanResult.complete] = false，让上层决定保留旧列表。
Future<LocalFileScanResult> scanLocalFilesDetailed() async {
  final result = <LocalFile>[];
  final seen = <String>{};
  var errors = 0;
  try {
    final dir = await appDownloadDir();
    if (await dir.exists()) {
      await for (final entity in dir.list(followLinks: false)) {
        try {
          if (entity is! File) continue;
          final name = entity.path.split(Platform.pathSeparator).last;
          if (name.startsWith('.')) continue;
          if (name.endsWith('.part') || name.endsWith('.tmp')) continue;
          if (!seen.add(entity.path)) continue;
          final stat = await entity.stat();
          if (stat.size <= 0) continue;
          result.add(LocalFile(
            path: entity.path,
            name: name,
            size: stat.size,
            modifiedAt: stat.modified,
            kind: LocalFile.kindOf(name),
          ));
        } catch (_) {
          // 单个条目读不到只跳过它，但整次扫描不能算完整
          errors++;
        }
      }
    }
    result.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return LocalFileScanResult(
        files: result, complete: errors == 0, errors: errors);
  } catch (_) {
    // 目录枚举中断：返回部分结果并标记不完整
    return LocalFileScanResult(
        files: result, complete: false, errors: errors + 1);
  }
}

/// 兼容旧调用：只取文件列表。需要判断完整性时用 [scanLocalFilesDetailed]。
Future<List<LocalFile>> scanLocalFiles() async =>
    (await scanLocalFilesDetailed()).files;
