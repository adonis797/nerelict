/// 本地媒体文件的补充元数据：时长、分辨率、清单分片情况。
///
/// 为什么单独一层：`LocalFile` 只描述「磁盘上有个文件」（名字、大小、时间、类型），
/// 而时长/分辨率要解码、分片完整性要读清单并 stat 同目录文件——都慢，不能进扫描循环。
/// 所以扫描保持轻量，元数据按需补、按 `path + size + mtime` 缓存。
///
/// 纯 Dart（无 Flutter、无 IO），主机端可直接断言。
library;

/// 媒体探测结果。`null` 字段表示「拿不到」，不要用 0 冒充。
class MediaMeta {
  const MediaMeta({
    this.duration,
    this.width,
    this.height,
    this.isPlaylist = false,
    this.segments = 0,
    this.missingSegments = 0,
    this.encrypted = false,
    this.isMaster = false,
    this.note = '',
    this.failed = false,
  });

  final Duration? duration;
  final int? width;
  final int? height;

  /// 这一条是不是 HLS/DASH 清单（`.m3u8` / `.mpd`）
  final bool isPlaylist;

  /// 清单里的分片数；非清单为 0
  final int segments;

  /// 本地缺失的分片数（只对相对路径 + 同目录的分片有效）
  final int missingSegments;

  /// 清单是否声明了加密（`#EXT-X-KEY:METHOD=AES-128` 等）
  final bool encrypted;

  /// 是不是 master 清单（含 `#EXT-X-STREAM-INF`）
  final bool isMaster;

  /// 人话备注：清单解析失败、分片在远程无法核对之类，空串表示无需说明
  final String note;

  /// 探测失败（解码器不支持、文件损坏）：不当成「没有元数据」，要显式标出来
  final bool failed;

  bool get hasVideoInfo => duration != null || width != null;

  /// 行内第二段的视频附加信息。
  ///
  /// 普通视频给 `12:04 · 1080p`；清单给 `8 分片 · 齐全`，两者不会混用——
  /// 清单没有时长和分辨率，硬塞只会得到一串空白。
  String get inlineInfo {
    if (isPlaylist) {
      final parts = <String>[];
      if (segments > 0) parts.add('$segments 分片');
      if (isMaster) parts.add('master');
      parts.add(segmentStatus);
      if (encrypted) parts.add('加密');
      return parts.join(' · ');
    }
    final parts = <String>[];
    if (duration != null) parts.add(formatDuration(duration!));
    if (width != null && height != null) parts.add(resolutionLabel(width!, height!));
    return parts.join(' · ');
  }

  /// 清单分片的完整性结论。
  String get segmentStatus {
    if (failed) return '清单不可读';
    if (segments == 0) return note.isEmpty ? '无分片' : note;
    if (missingSegments > 0) return '缺 $missingSegments 段';
    if (note.isNotEmpty) return note;
    return '齐全';
  }

  /// 缺分片、不可读、加密都值得在列表里提前标出来（点下去大概率播不动）。
  bool get attention => failed || missingSegments > 0;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (duration != null) 'd': duration!.inMilliseconds,
        if (width != null) 'w': width,
        if (height != null) 'h': height,
        if (isPlaylist) 'p': 1,
        if (segments > 0) 'n': segments,
        if (missingSegments > 0) 'm': missingSegments,
        if (encrypted) 'e': 1,
        if (isMaster) 'ma': 1,
        if (note.isNotEmpty) 'nt': note,
        if (failed) 'f': 1,
      };

  static MediaMeta fromJson(Map<String, dynamic> raw) => MediaMeta(
        duration: raw['d'] is num
            ? Duration(milliseconds: (raw['d'] as num).toInt())
            : null,
        width: (raw['w'] as num?)?.toInt(),
        height: (raw['h'] as num?)?.toInt(),
        isPlaylist: raw['p'] == 1,
        segments: (raw['n'] as num?)?.toInt() ?? 0,
        missingSegments: (raw['m'] as num?)?.toInt() ?? 0,
        encrypted: raw['e'] == 1,
        isMaster: raw['ma'] == 1,
        note: raw['nt'] as String? ?? '',
        failed: raw['f'] == 1,
      );
}

/// 清单文件的解析结论（纯文本层面，不碰文件系统）。
class PlaylistSummary {
  const PlaylistSummary({
    required this.segments,
    required this.encrypted,
    required this.isMaster,
    this.targetDuration,
    this.uris = const <String>[],
  });

  final int segments;
  final bool encrypted;
  final bool isMaster;
  final Duration? targetDuration;

  /// 分片（或子清单）地址，按出现顺序。用于核对本地分片是否齐全。
  final List<String> uris;

  bool get valid => segments > 0 || isMaster;
}

/// 解析 m3u8 文本：数分片、看是否加密、是否 master。
///
/// 只做「够用」的解析：不构造完整树，也不解析 `#EXT-X-BYTERANGE`——
/// 这里要回答的是「这是不是一份可用清单、有几段」，细节留给真正的下载器。
PlaylistSummary parsePlaylistText(String text) {
  var segments = 0;
  var encrypted = false;
  var isMaster = false;
  var header = false;
  int? target;
  final uris = <String>[];
  for (final rawLine in text.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    // 首个非空行必须是 #EXTM3U：防盗链常回一段 HTML，若不校验会把它数成「1 个分片」
    if (!header) {
      if (!line.startsWith('#EXTM3U')) {
        return const PlaylistSummary(
          segments: 0,
          encrypted: false,
          isMaster: false,
        );
      }
      header = true;
      continue;
    }
    if (line.startsWith('#')) {
      if (line.startsWith('#EXT-X-STREAM-INF')) isMaster = true;
      if (line.startsWith('#EXT-X-TARGETDURATION:')) {
        target = int.tryParse(line.substring('#EXT-X-TARGETDURATION:'.length).trim());
      }
      if (line.startsWith('#EXT-X-KEY:') &&
          !line.toUpperCase().contains('METHOD=NONE')) {
        encrypted = true;
      }
      continue;
    }
    // 非注释行 = 一个分片或子清单地址
    segments++;
    if (uris.length < 512) uris.add(line);
  }
  return PlaylistSummary(
    segments: segments,
    encrypted: encrypted,
    isMaster: isMaster,
    targetDuration: target == null ? null : Duration(seconds: target),
    uris: uris,
  );
}

/// `12:04` / `1:02:03`；拿不到时长时返回空串，让调用方自己决定显示什么。
String formatDuration(Duration d) {
  final total = d.inSeconds;
  if (total <= 0) return '';
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

/// 按高度给常见档位名；不在档位上就老老实实写 `宽×高`。
String resolutionLabel(int width, int height) {
  // 竖屏视频（720×1280）按短边报档位：用户说的是「720p」，不是「1280 高」
  final h = width > 0 && width < height ? width : height;
  if (h <= 0) return '';
  // 只有接近标准档位才用档位名：640×400 说成「360p」是错的，
  // 编码器切出来的 1088 说成「1080p」则是对的，所以给一点容差。
  const tiers = <(int, String)>[
    (2160, '4K'),
    (1440, '2K'),
    (1080, '1080p'),
    (720, '720p'),
    (480, '480p'),
    (360, '360p'),
  ];
  for (final (tier, label) in tiers) {
    if (h >= tier * 0.95 && h <= tier * 1.06) return label;
  }
  return width > 0 ? '$width×$h' : '';
}
