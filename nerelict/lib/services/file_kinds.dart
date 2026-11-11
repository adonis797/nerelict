/// 下载目录文件的类型分组与扩展名映射。
///
/// 单独放在纯 Dart 文件里：既给 local_media_scanner 复用，
/// 也能在主机上用 `dart run` 直接跑断言（不依赖 Flutter 插件）。
enum LocalFileKind { video, audio, image, document, archive, other }

extension LocalFileKindX on LocalFileKind {
  String get label => switch (this) {
        LocalFileKind.video => '视频',
        LocalFileKind.audio => '音频',
        LocalFileKind.image => '图片',
        LocalFileKind.document => '文档',
        LocalFileKind.archive => '压缩包',
        LocalFileKind.other => '其他',
      };
}

const Map<String, LocalFileKind> kExtKinds = <String, LocalFileKind>{
  // 视频
  '.ts': LocalFileKind.video,
  '.mp4': LocalFileKind.video,
  '.m4v': LocalFileKind.video,
  '.webm': LocalFileKind.video,
  '.mkv': LocalFileKind.video,
  '.mov': LocalFileKind.video,
  '.flv': LocalFileKind.video,
  '.avi': LocalFileKind.video,
  '.3gp': LocalFileKind.video,
  '.m2ts': LocalFileKind.video,
  '.mts': LocalFileKind.video,
  '.mpg': LocalFileKind.video,
  '.mpeg': LocalFileKind.video,
  '.wmv': LocalFileKind.video,
  '.rmvb': LocalFileKind.video,
  // 音频
  '.mp3': LocalFileKind.audio,
  '.m4a': LocalFileKind.audio,
  '.aac': LocalFileKind.audio,
  '.flac': LocalFileKind.audio,
  '.wav': LocalFileKind.audio,
  '.ogg': LocalFileKind.audio,
  '.opus': LocalFileKind.audio,
  '.amr': LocalFileKind.audio,
  '.mka': LocalFileKind.audio,
  // 图片
  '.jpg': LocalFileKind.image,
  '.jpeg': LocalFileKind.image,
  '.png': LocalFileKind.image,
  '.webp': LocalFileKind.image,
  '.gif': LocalFileKind.image,
  '.bmp': LocalFileKind.image,
  '.heic': LocalFileKind.image,
  // 文档
  '.pdf': LocalFileKind.document,
  '.txt': LocalFileKind.document,
  '.md': LocalFileKind.document,
  '.json': LocalFileKind.document,
  '.xml': LocalFileKind.document,
  '.csv': LocalFileKind.document,
  '.doc': LocalFileKind.document,
  '.docx': LocalFileKind.document,
  '.xls': LocalFileKind.document,
  '.xlsx': LocalFileKind.document,
  '.ppt': LocalFileKind.document,
  '.pptx': LocalFileKind.document,
  '.epub': LocalFileKind.document,
  '.srt': LocalFileKind.document,
  '.vtt': LocalFileKind.document,
  // 压缩包
  '.zip': LocalFileKind.archive,
  '.rar': LocalFileKind.archive,
  '.7z': LocalFileKind.archive,
  '.tar': LocalFileKind.archive,
  '.gz': LocalFileKind.archive,
};

/// 按文件名判类型：无扩展名或未知扩展名一律算「其他」
LocalFileKind kindOfName(String name) {
  final lower = name.toLowerCase();
  final dot = lower.lastIndexOf('.');
  if (dot < 0) return LocalFileKind.other;
  return kExtKinds[lower.substring(dot)] ?? LocalFileKind.other;
}
