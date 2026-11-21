/// 下载目录文件的类型分组与扩展名映射。
///
/// 单独放在纯 Dart 文件里：既给 local_media_scanner 复用，
/// 也能在主机上用 `dart run` 直接跑断言（不依赖 Flutter 插件）。
///
/// 分得比「视频 / 音频 / 图片 / 文档 / 压缩包」细一档，是为了让文件页的分类宫格
/// 真能用：安装包和电子书在下载目录里都是成堆出现的，混进「其他」等于没分类。
enum LocalFileKind {
  video,
  audio,
  image,
  document,
  ebook,
  archive,
  apk,
  other,
}

extension LocalFileKindX on LocalFileKind {
  String get label => switch (this) {
        LocalFileKind.video => '视频',
        LocalFileKind.audio => '音频',
        LocalFileKind.image => '图片',
        LocalFileKind.document => '文档',
        LocalFileKind.ebook => '电子书',
        LocalFileKind.archive => '压缩包',
        LocalFileKind.apk => '安装包',
        LocalFileKind.other => '其他',
      };
}

/// 分类宫格的展示顺序：先媒体后资料，最后兜底。
///
/// 固定顺序而不是直接用 `values`：以后往枚举中间插类型时，
/// 宫格顺序不应该跟着代码顺序乱跳。
const List<LocalFileKind> kGridKinds = <LocalFileKind>[
  LocalFileKind.video,
  LocalFileKind.image,
  LocalFileKind.audio,
  LocalFileKind.document,
  LocalFileKind.ebook,
  LocalFileKind.archive,
  LocalFileKind.apk,
  LocalFileKind.other,
];

/// HLS / DASH 这类「清单文件」：它们不是媒体本身，元数据与播放方式都不一样。
///
/// 单独标出来是必需的——`.m3u8` 若落进普通视频分支，会去读时长与分辨率，
/// 结果全空，用户看到的是一行「—」。
const Set<String> kPlaylistExts = <String>{'.m3u8', '.mpd'};

bool isPlaylistName(String name) => kPlaylistExts.contains(extensionOf(name));

String extensionOf(String name) {
  final lower = name.toLowerCase();
  final dot = lower.lastIndexOf('.');
  return dot > 0 ? lower.substring(dot) : '';
}

const Map<String, LocalFileKind> kExtKinds = <String, LocalFileKind>{
  // 视频（含 HLS 清单：归视频，但播放与元数据另有分支）
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
  '.m3u8': LocalFileKind.video,
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
  '.srt': LocalFileKind.document,
  '.vtt': LocalFileKind.document,
  // 电子书
  '.epub': LocalFileKind.ebook,
  '.mobi': LocalFileKind.ebook,
  '.azw': LocalFileKind.ebook,
  '.azw3': LocalFileKind.ebook,
  '.fb2': LocalFileKind.ebook,
  '.cbz': LocalFileKind.ebook,
  '.cbr': LocalFileKind.ebook,
  // 压缩包
  '.zip': LocalFileKind.archive,
  '.rar': LocalFileKind.archive,
  '.7z': LocalFileKind.archive,
  '.tar': LocalFileKind.archive,
  '.gz': LocalFileKind.archive,
  // 安装包
  '.apk': LocalFileKind.apk,
  '.apks': LocalFileKind.apk,
  '.xapk': LocalFileKind.apk,
};

/// 按文件名判类型：无扩展名或未知扩展名一律算「其他」
LocalFileKind kindOfName(String name) =>
    kExtKinds[extensionOf(name)] ?? LocalFileKind.other;
