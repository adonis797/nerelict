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

/// 纯数字文件名（`0`、`253`、`0012`）——HLS/DASH 缓存目录最常见的分片命名。
final RegExp _kNumericStem = RegExp(r'^\d{1,7}$');

/// `seg_xxx` / `frag_xxx` / `chunk-xxx` 这类分片前缀。
final RegExp _kSegmentStem =
    RegExp(r'^(seg|frag|chunk)[_-]?[0-9a-z]{1,}$', caseSensitive: false);

/// 会被当成「分片」的扩展名。`.mp4` 也可能是普通视频，所以最终是否忽略
/// 交给调用方按「同目录里成组出现」判断，单看名字不能一票否决。
const Set<String> kSegmentExts = <String>{
  '.ts',
  '.m4s',
  '.cmfv',
  '.cmfa',
  '.m4v',
  '.mp4',
  '.aac',
  '.m4a',
};

/// 名字看起来像媒体分片（纯数字段号或 seg_ 前缀 + 媒体扩展名）。
bool looksLikeMediaSegment(String name) {
  final ext = extensionOf(name);
  if (!kSegmentExts.contains(ext)) return false;
  final stem = name.substring(0, name.length - ext.length);
  if (_kNumericStem.hasMatch(stem)) return true;
  return _kSegmentStem.hasMatch(stem);
}

/// 下载器自己的临时分片/半成品：`seg_<hash>.bin`、`init_<hash>.mp4`、`*.part`。
///
/// 这些文件永远不该出现在文件页——它们既不能播放，也没有完整数据。
bool looksLikePartFile(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.part') || lower.endsWith('.tmp')) return true;
  if (lower.endsWith('.bin')) {
    final stem = lower.substring(0, lower.length - 4);
    if ((stem.startsWith('seg_') ||
            stem.startsWith('part_') ||
            stem.startsWith('init_')) &&
        stem.length > 12) {
      return true;
    }
  }
  return false;
}

/// 任意层级都要跳过的「缓存类」目录名（小写比较）。
///
/// 全盘扫描最容易翻车的地方：应用缓存里有成千上万个缩略图/分片，会把
/// 真正的用户文件挤出上限。系统媒体库（MediaStore）同样不索引这些目录，
/// 夸克/迅雷的文件管理看不到它们，原因就在这里。
const Set<String> kNoiseDirNames = <String>{
  'cache',
  'caches',
  'code_cache',
  'thumbnails',
  'thumbnail',
  'thumbs',
  'thumb',
  'tmp',
  'temp',
  'logs',
  'trash',
  'recycle',
  'recycler',
  'recycle_bin',
};

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
  '.rm': LocalFileKind.video,
  '.f4v': LocalFileKind.video,
  '.vob': LocalFileKind.video,
  '.ogv': LocalFileKind.video,
  '.divx': LocalFileKind.video,
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
  '.wma': LocalFileKind.audio,
  '.ape': LocalFileKind.audio,
  '.aiff': LocalFileKind.audio,
  '.aif': LocalFileKind.audio,
  '.mid': LocalFileKind.audio,
  '.midi': LocalFileKind.audio,
  '.ac3': LocalFileKind.audio,
  '.dts': LocalFileKind.audio,
  // 图片
  '.jpg': LocalFileKind.image,
  '.jpeg': LocalFileKind.image,
  '.png': LocalFileKind.image,
  '.webp': LocalFileKind.image,
  '.gif': LocalFileKind.image,
  '.bmp': LocalFileKind.image,
  '.heic': LocalFileKind.image,
  '.heif': LocalFileKind.image,
  '.svg': LocalFileKind.image,
  '.ico': LocalFileKind.image,
  '.tif': LocalFileKind.image,
  '.tiff': LocalFileKind.image,
  '.avif': LocalFileKind.image,
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
  '.log': LocalFileKind.document,
  '.yaml': LocalFileKind.document,
  '.yml': LocalFileKind.document,
  '.html': LocalFileKind.document,
  '.htm': LocalFileKind.document,
  '.rtf': LocalFileKind.document,
  '.odt': LocalFileKind.document,
  '.ods': LocalFileKind.document,
  '.odp': LocalFileKind.document,
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
  '.bz2': LocalFileKind.archive,
  '.xz': LocalFileKind.archive,
  '.tgz': LocalFileKind.archive,
  '.lz4': LocalFileKind.archive,
  '.zst': LocalFileKind.archive,
  // 安装包
  '.apk': LocalFileKind.apk,
  '.apks': LocalFileKind.apk,
  '.xapk': LocalFileKind.apk,
};

/// 按文件名判类型：无扩展名或未知扩展名一律算「其他」
LocalFileKind kindOfName(String name) =>
    kExtKinds[extensionOf(name)] ?? LocalFileKind.other;

/// 按「文件头魔数」嗅探真实类型，给无扩展名、错扩展名、以及扩展名映射表
/// 覆盖不到的文件兜底。只读前若干字节，不进解码循环。
///
/// [header] 是文件开头的原始字节（扫描器负责读，这里只做纯判定，便于 `dart run`
/// 直接断言）。返回 null 表示「嗅探不出来」，调用方应退回 [kindOfName] 的结论。
LocalFileKind? sniffKind(List<int> header) {
  bool has(List<int> sig, [int offset = 0]) {
    if (header.length < offset + sig.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (header[offset + i] != sig[i]) return false;
    }
    return true;
  }

  if (header.isEmpty) return null;

  // 容器/流媒体视频与音频
  // MP4 族：ftyp 盒子（第 4~8 字节是 'ftyp'）
  if (header.length >= 12 && header[4] == 0x66 && header[5] == 0x74 &&
      header[6] == 0x79 && header[7] == 0x70) {
    // ftyp 后的 major brand：'M4A ' 是音频，'heic'/'avif'/'mif1' 等是图片，
    // 'qt  ' 是 QuickTime(MOV)，其余算视频。
    final brand = header.sublist(8, 12);
    if (_eq(brand, 'M4A ') || _eq(brand, 'M4B ') || _eq(brand, 'f4a ') ||
        _eq(brand, 'M4P ')) {
      return LocalFileKind.audio;
    }
    if (_eq(brand, 'heic') || _eq(brand, 'heix') || _eq(brand, 'hevc') ||
        _eq(brand, 'hevx') || _eq(brand, 'mif1') || _eq(brand, 'msf1') ||
        _eq(brand, 'avif') || _eq(brand, 'avis')) {
      return LocalFileKind.image;
    }
    return LocalFileKind.video;
  }
  if (has(const [0x1A, 0x45, 0xDF, 0xA3])) return LocalFileKind.video; // Matroska
  if (has(const [0x4F, 0x67, 0x67, 0x53])) return LocalFileKind.audio; // OggS
  if (has(const [0x52, 0x49, 0x46, 0x46]) && header.length >= 12 &&
      _eq(header.sublist(8, 12), 'WAVE')) {
    return LocalFileKind.audio; // RIFF....WAVE
  }
  if (has(const [0x52, 0x49, 0x46, 0x46]) && header.length >= 12 &&
      _eq(header.sublist(8, 12), 'AVI ')) {
    return LocalFileKind.video; // RIFF....AVI
  }
  if (has(const [0x52, 0x49, 0x46, 0x46]) && header.length >= 12 &&
      _eq(header.sublist(8, 12), 'WEBP')) {
    return LocalFileKind.image; // RIFF....WEBP
  }
  if (has(const [0x46, 0x4C, 0x56, 0x01])) return LocalFileKind.video; // FLV
  if (has(const [0x00, 0x00, 0x01, 0xBA]) ||
      has(const [0x00, 0x00, 0x01, 0xB3])) {
    return LocalFileKind.video; // MPEG-PS / MPEG 视频流
  }
  if (has(const [0x30, 0x26, 0xB2, 0x75])) return LocalFileKind.video; // ASF/WMV
  // 注：TS 分片不做魔数嗅探——0x47 同步字节太宽泛（GIF 的 'G' 也是 0x47），
  // 单字节判定会误伤图片；TS 一律靠 `.ts` 扩展名（下载器就是按 `.ts` 命名的）。
  if (has(const [0x00, 0x00, 0x00, 0x18]) && header.length >= 8 &&
      _eq(header.sublist(4, 8), 'ftyp')) {
    return LocalFileKind.video; // 3GP 等 ftyp 变体（brand 前置长度）
  }

  // 音频
  if (has(const [0x49, 0x44, 0x33])) return LocalFileKind.audio; // ID3 (MP3)
  if ((header[0] == 0xFF) && (header.length > 1) &&
      ((header[1] & 0xE0) == 0xE0)) {
    return LocalFileKind.audio; // MP3 帧同步
  }
  if (has(const [0x66, 0x4C, 0x61, 0x43])) return LocalFileKind.audio; // fLaC
  if (has(const [0x41, 0x44, 0x49, 0x46])) return LocalFileKind.audio; // ADIF (AAC)
  if (has(const [0x23, 0x21, 0x41, 0x4D, 0x52])) return LocalFileKind.audio; // AMR

  // 图片
  if (has(const [0xFF, 0xD8, 0xFF])) return LocalFileKind.image; // JPEG
  if (has(const [0x89, 0x50, 0x4E, 0x47])) return LocalFileKind.image; // PNG
  if (has(const [0x47, 0x49, 0x46, 0x38])) return LocalFileKind.image; // GIF8
  if (has(const [0x42, 0x4D])) return LocalFileKind.image; // BMP
  if (has(const [0x49, 0x49, 0x2A, 0x00]) ||
      has(const [0x4D, 0x4D, 0x00, 0x2A])) {
    return LocalFileKind.image; // TIFF（II*\0 / MM\0*）
  }

  // 文档
  if (has(const [0x25, 0x50, 0x44, 0x46])) return LocalFileKind.document; // %PDF
  if (has(const [0x50, 0x4B, 0x03, 0x04]) ||
      has(const [0x50, 0x4B, 0x05, 0x06]) ||
      has(const [0x50, 0x4B, 0x07, 0x08])) {
    // ZIP 魔数：可能是压缩包，也可能是 docx/xlsx/pptx/epub/apk/jar
    // 具体归属靠扩展名，这里先认作压缩包，调用方用扩展名覆盖
    return LocalFileKind.archive;
  }
  if (has(const [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C])) {
    return LocalFileKind.archive; // 7z
  }
  if (has(const [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07])) {
    return LocalFileKind.archive; // RAR
  }
  if (has(const [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])) {
    return LocalFileKind.document; // OLE2（旧版 .doc/.xls/.ppt）
  }

  return null;
}

bool _eq(List<int> a, String s) {
  if (a.length != s.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != s.codeUnitAt(i)) return false;
  }
  return true;
}

/// 磁盘上一个文件（任意类型）的轻量描述，只暴露元信息，不展示完整路径。
///
/// 放在纯 Dart 的 `file_kinds.dart` 里（而非 `local_media_scanner.dart`），
/// 是为了让「全盘递归扫描器」只依赖纯 Dart 层即可被 `dart run` 直接断言，
/// 不拖进 `path_provider` → Flutter 引擎的依赖链。
class LocalFile {
  const LocalFile({
    required this.path,
    required this.name,
    required this.size,
    required this.modifiedAt,
    required this.kind,
    this.isDir = false,
  });

  final String path;
  final String name;
  final int size;
  final DateTime modifiedAt;
  final LocalFileKind kind;

  /// 目录条目。目录没有大小与类型，但仍然要显示、要能进去。
  final bool isDir;

  String get extension {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(dot).toLowerCase() : '';
  }

  String get title {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// 只有视频能在 Nerelict 里直接播放；其他类型走文件管理（信息 / 重命名 / 删除）
  bool get isPlayable => !isDir && kind == LocalFileKind.video;

  bool get isMp4 => extension == '.mp4';

  /// 是不是 HLS/DASH 清单：它能播，但没有时长与分辨率，元信息另算。
  bool get isPlaylist => kPlaylistExts.contains(extension);

  /// 具体类型文案：优先给已知扩展名一个更准确的名字
  String get typeLabel {
    if (isDir) return '文件夹';
    final ext = extension;
    return switch (ext) {
      '.mp4' || '.m4v' => 'MP4 视频',
      '.ts' => 'TS 视频',
      '.webm' => 'WebM 视频',
      '.mkv' => 'MKV 视频',
      '.mov' => 'MOV 视频',
      '.flv' => 'FLV 视频',
      '.avi' => 'AVI 视频',
      // 清单文件不是媒体本身，单独给个名字，避免被当成「一个 12 KB 的视频」
      '.m3u8' => 'HLS 清单',
      '.mpd' => 'DASH 清单',
      '.mp3' => 'MP3 音频',
      '.m4a' => 'M4A 音频',
      '.flac' => 'FLAC 音频',
      '.wav' => 'WAV 音频',
      '.pdf' => 'PDF 文档',
      '.txt' || '.md' => '文本文件',
      '.epub' || '.mobi' || '.azw3' || '.fb2' => '电子书',
      '.zip' || '.rar' || '.7z' => '压缩包',
      '.apk' || '.apks' || '.xapk' => 'APK 安装包',
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
