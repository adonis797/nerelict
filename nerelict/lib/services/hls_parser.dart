import 'dart:convert';
import 'dart:typed_data';

/// #EXT-X-KEY 描述的加密方式
class HlsKey {
  const HlsKey({required this.method, this.uri, this.iv});

  final String method;
  final Uri? uri;
  final Uint8List? iv;

  bool get isAes128 => method.toUpperCase() == 'AES-128';
}

class HlsSegment {
  HlsSegment({
    required this.uri,
    required this.key,
    required this.sequence,
    required this.duration,
    this.rangeOffset,
    this.rangeLength,
    this.discontinuityBefore = false,
    this.mapUri,
    this.mapRangeOffset,
    this.mapRangeLength,
  });

  final Uri uri;

  /// null 表示该分片未加密
  final HlsKey? key;

  /// 媒体序号，AES-128 未显式给 IV 时要用它推导
  final int sequence;
  final double duration;

  /// #EXT-X-BYTERANGE 的起始字节；与 [rangeLength] 同时为 null 表示整段下载。
  /// 一个文件被切成多段时，每段指向同一个 URI，只能靠字节区间区分。
  final int? rangeOffset;
  final int? rangeLength;

  /// 该分片前有 #EXT-X-DISCONTINUITY：时间轴在此处跳变（插播 / 换源 / 换编码）。
  final bool discontinuityBefore;

  /// 该分片所属的 #EXT-X-MAP 初始化分片（fMP4）。
  ///
  /// 规范允许播放列表里出现多次 `#EXT-X-MAP`（换编码 / 插播后会换 init），
  /// 只记第一个会让后半段缺少 moov，拼出来的文件播不了。所以 init 挂在分片上。
  final Uri? mapUri;
  final int? mapRangeOffset;
  final int? mapRangeLength;

  bool get hasMapRange => mapRangeLength != null && mapRangeLength! > 0;

  /// init 的身份：同一 URI 不同字节区间算两份，避免复用错段
  String get mapKey => mapUri == null
      ? ''
      : '${mapUri!}#${hasMapRange ? '${mapRangeOffset ?? 0}+$mapRangeLength' : ''}';

  bool get hasRange => rangeLength != null && rangeLength! > 0;
}

class HlsMediaPlaylist {
  HlsMediaPlaylist({
    required this.segments,
    required this.initUri,
    required this.isFmp4,
    required this.isLive,
    this.discontinuities = 0,
  });

  final List<HlsSegment> segments;

  /// #EXT-X-MAP 的初始化分片（fMP4 才有）
  final Uri? initUri;
  final bool isFmp4;
  final bool isLive;

  /// 播放列表中 #EXT-X-DISCONTINUITY 的个数。大于 0 说明时间轴不连续，
  /// 直接拼接得到的文件能播但时间戳会跳，转 MP4 后时长可能对不上，
  /// 需要在界面上如实告知，而不是假装产出了完整时间轴。
  final int discontinuities;

  Duration get totalDuration => segments.fold(
        Duration.zero,
        (acc, s) => acc + Duration(milliseconds: (s.duration * 1000).round()),
      );
}

class HlsVariant {
  HlsVariant({
    required this.uri,
    required this.bandwidth,
    this.resolution,
    this.codecs,
    this.frameRate,
    this.audioGroup,
    this.subtitleGroup,
  });

  final Uri uri;
  final int bandwidth;
  final String? resolution;

  /// CODECS 属性，用于判断是否 HEVC / 杜比等
  final String? codecs;
  final String? frameRate;

  /// 指向 #EXT-X-MEDIA 的 GROUP-ID：音轨 / 字幕是否独立成流
  final String? audioGroup;
  final String? subtitleGroup;

  /// 持久化「用户选过哪一档」的稳定标识。
  /// 带宽 + 分辨率足以区分同一份播放列表里的变体，而且比下标稳：
  /// 站点刷新列表后顺序可能变化，按下标复用会选错档。
  String get key => '$bandwidth@${resolution ?? '-'}';

  /// 画质档位的简短名字，用于选中后写进任务记录
  String get qualityLabel => resolution ?? bandwidthLabel;

  String get bandwidthLabel => bandwidth >= 1000000
      ? '${(bandwidth / 1000000).toStringAsFixed(1)} Mbps'
      : '${(bandwidth / 1000).round()} kbps';

  String get label => resolution == null
      ? bandwidthLabel
      : '$resolution · $bandwidthLabel';
}

/// #EXT-X-MEDIA 声明的替代 rendition（独立音轨 / 字幕 / 备用机位）。
class HlsRendition {
  const HlsRendition({
    required this.type,
    required this.groupId,
    required this.name,
    this.uri,
    this.language,
    this.isDefault = false,
    this.isForced = false,
    this.channels,
  });

  /// AUDIO / SUBTITLES / VIDEO / CLOSED-CAPTIONS
  final String type;
  final String groupId;
  final String name;

  /// 独立的子播放列表地址；null 表示这条 rendition 内嵌在变体里，不需要单独下载
  final String? uri;
  final String? language;
  final bool isDefault;
  final bool isForced;

  /// 音频声道数，如 "2" / "6"
  final String? channels;

  bool get isAudio => type.toUpperCase() == 'AUDIO';
  bool get isSubtitle => type.toUpperCase() == 'SUBTITLES';

  /// 有独立地址就意味着音轨被拆成了一个单独的视频文件流：
  /// 只下视频变体会得到没有声音的产物，必须显式告诉用户。
  bool get isSeparate => uri != null && uri!.trim().isNotEmpty;

  String get label {
    final parts = <String>[
      if (language != null && language!.trim().isNotEmpty) language!.trim(),
      if (name.trim().isNotEmpty) name.trim(),
      if (channels != null && channels!.trim().isNotEmpty) '${channels!.trim()} 声道',
      if (isDefault) '默认',
      if (isForced) '强制字幕',
    ];
    return parts.join(' · ');
  }
}

/// 一份主播放列表的完整解析结果：码率变体 + 音轨/字幕声明。
class HlsMasterPlaylist {
  HlsMasterPlaylist({required this.variants, required this.renditions});

  /// 已按带宽从高到低排序
  final List<HlsVariant> variants;
  final List<HlsRendition> renditions;

  bool get isEmpty => variants.isEmpty;

  /// 某个变体引用的独立音轨（AUDIO 组里声明了 URI 的那些）
  List<HlsRendition> separateAudioFor(HlsVariant v) {
    final group = v.audioGroup;
    if (group == null) return const <HlsRendition>[];
    return renditions
        .where((r) => r.isAudio && r.groupId == group && r.isSeparate)
        .toList();
  }

  /// 下载时默认取哪一条独立音轨。
  ///
  /// 顺序是 `DEFAULT=YES` → 中文（zh / chi / cmn / 中文语种标记）→ 组内第一条。
  /// 不取「声道最多」的那条：多声道的常是导演评论轨，把正片音轨换掉反而更糟。
  HlsRendition? preferredAudioFor(HlsVariant v) {
    final list = separateAudioFor(v);
    if (list.isEmpty) return null;
    for (final r in list) {
      if (r.isDefault) return r;
    }
    for (final r in list) {
      final lang = (r.language ?? '').toLowerCase();
      if (lang.startsWith('zh') || lang == 'chi' || lang == 'cmn') return r;
      final name = r.name.toLowerCase();
      if (name.contains('中文') || name.contains('国语') || name.contains('普通话')) {
        return r;
      }
    }
    return list.first;
  }

  /// 某个变体可选的字幕
  List<HlsRendition> subtitlesFor(HlsVariant v) {
    final group = v.subtitleGroup;
    if (group == null) return const <HlsRendition>[];
    return renditions
        .where((r) => r.isSubtitle && r.groupId == group)
        .toList();
  }

  /// 按持久化的 key 恢复用户上次的选择。
  ///
  /// 精确命中优先；播放列表换了一套分辨率时退到「同高度里带宽最接近」，
  /// 都对不上才回落到最高码率——保证续传不会因为站点改列表就直接失败。
  HlsVariant? pick(String? key) {
    if (variants.isEmpty) return null;
    if (key == null || key.isEmpty) return variants.first;
    for (final v in variants) {
      if (v.key == key) return v;
    }
    // 播放列表换了一套分辨率时退到「同高度」那一档，比直接掉到最高档更接近
    // 用户原本的意图（key 形如 `带宽@分辨率`，这里取 @ 之后的部分）
    final at = key.indexOf('@');
    final res = at < 0 ? '' : key.substring(at + 1);
    if (res.isNotEmpty && res != '-') {
      final sameRes = variants.where((v) => v.resolution == res).toList();
      if (sameRes.isNotEmpty) return sameRes.first;
    }
    return variants.first;
  }
}

bool isMasterPlaylist(String text) => text.contains('#EXT-X-STREAM-INF');

/// 解析 HLS 属性列表，正确处理引号内的逗号
Map<String, String> parseAttributes(String input) {
  final result = <String, String>{};
  var i = 0;
  while (i < input.length) {
    final eq = input.indexOf('=', i);
    if (eq < 0) break;
    final key = input.substring(i, eq).trim();
    var j = eq + 1;
    String value;
    if (j < input.length && input[j] == '"') {
      final end = input.indexOf('"', j + 1);
      if (end < 0) {
        value = input.substring(j + 1);
        j = input.length;
      } else {
        value = input.substring(j + 1, end);
        j = end + 1;
      }
    } else {
      var end = input.indexOf(',', j);
      if (end < 0) end = input.length;
      value = input.substring(j, end).trim();
      j = end;
    }
    result[key] = value;
    final comma = input.indexOf(',', j);
    if (comma < 0) break;
    i = comma + 1;
  }
  return result;
}

/// 把 0x... 的 IV 字符串解析成 16 字节
Uint8List? parseIv(String hex) {
  var h = hex.trim();
  if (h.toLowerCase().startsWith('0x')) h = h.substring(2);
  if (h.isEmpty || h.length > 32) return null;
  h = h.padLeft(32, '0');
  final out = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// 分片序号转 16 字节大端 IV（HLS 规范规定）
Uint8List ivFromSequence(int sequence) {
  final iv = Uint8List(16);
  var v = sequence;
  for (var i = 15; i >= 0 && v > 0; i--) {
    iv[i] = v & 0xff;
    v >>= 8;
  }
  return iv;
}

/// 兼容旧调用方：只关心码率变体时用这个。
List<HlsVariant> parseMasterPlaylist(String text, Uri base) =>
    parseMasterPlaylistFull(text, base).variants;

/// 解析主播放列表的码率变体与 #EXT-X-MEDIA 声明的音轨 / 字幕。
///
/// 之前只认 #EXT-X-STREAM-INF，音轨组被整个忽略。音视频分离的站点
/// （AUDIO 组带独立 URI）因此会下出一个没有声音的视频，且没有任何提示。
HlsMasterPlaylist parseMasterPlaylistFull(String text, Uri base) {
  final lines = const LineSplitter().convert(text);
  final variants = <HlsVariant>[];
  final renditions = <HlsRendition>[];
  Map<String, String>? pending;
  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#EXT-X-MEDIA:')) {
      final a = parseAttributes(line.substring('#EXT-X-MEDIA:'.length));
      final type = (a['TYPE'] ?? '').toUpperCase();
      final group = a['GROUP-ID'];
      if (type.isEmpty || group == null || group.isEmpty) continue;
      final uri = a['URI'];
      renditions.add(HlsRendition(
        type: type,
        groupId: group,
        name: a['NAME'] ?? '',
        uri: uri == null || uri.trim().isEmpty
            ? null
            : base.resolve(uri.trim()).toString(),
        language: a['LANGUAGE'],
        isDefault: (a['DEFAULT'] ?? '').toUpperCase() == 'YES',
        isForced: (a['FORCED'] ?? '').toUpperCase() == 'YES',
        channels: a['CHANNELS'],
      ));
    } else if (line.startsWith('#EXT-X-STREAM-INF:')) {
      pending = parseAttributes(line.substring('#EXT-X-STREAM-INF:'.length));
    } else if (!line.startsWith('#') && pending != null) {
      variants.add(HlsVariant(
        uri: base.resolve(line),
        bandwidth: int.tryParse(pending['BANDWIDTH'] ?? '') ?? 0,
        resolution: pending['RESOLUTION'],
        codecs: pending['CODECS'],
        frameRate: pending['FRAME-RATE'],
        audioGroup: pending['AUDIO'],
        subtitleGroup: pending['SUBTITLES'],
      ));
      pending = null;
    }
  }
  variants.sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
  return HlsMasterPlaylist(variants: variants, renditions: renditions);
}

HlsMediaPlaylist parseMediaPlaylist(String text, Uri base) {
  final lines = const LineSplitter().convert(text);
  final segments = <HlsSegment>[];
  HlsKey? currentKey;
  Uri? initUri;
  // 当前生效的 #EXT-X-MAP（可能中途变化），按分片记录
  Uri? currentMapUri;
  int? currentMapOffset;
  int? currentMapLength;
  var isFmp4 = false;
  var isLive = true;
  var mediaSequence = 0;
  var index = 0;
  var pendingDuration = 0.0;
  var discontinuities = 0;

  // #EXT-X-BYTERANGE 的待应用值；offset 省略时按规范接续同一 URI 的上一段
  int? pendingRangeLength;
  int? pendingRangeOffset;
  int? lastRangeEnd;
  Uri? lastRangeUri;
  var pendingDiscontinuity = false;

  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty) continue;

    if (line.startsWith('#')) {
      if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        mediaSequence = int.tryParse(line.substring(22).trim()) ?? 0;
      } else if (line.startsWith('#EXT-X-KEY:')) {
        final attrs = parseAttributes(line.substring('#EXT-X-KEY:'.length));
        final method = (attrs['METHOD'] ?? 'NONE').toUpperCase();
        final uriStr = attrs['URI'];
        final ivStr = attrs['IV'];
        if (method == 'NONE' || uriStr == null) {
          currentKey = null;
        } else {
          currentKey = HlsKey(
            method: method,
            uri: base.resolve(uriStr),
            iv: ivStr == null ? null : parseIv(ivStr),
          );
        }
      } else if (line.startsWith('#EXT-X-MAP:')) {
        final attrs = parseAttributes(line.substring('#EXT-X-MAP:'.length));
        final uriStr = attrs['URI'];
        if (uriStr != null) {
          currentMapUri = base.resolve(uriStr);
          currentMapOffset = null;
          currentMapLength = null;
          // #EXT-X-MAP:URI="init.mp4",BYTERANGE="720@0" 时只取这一段
          final range = attrs['BYTERANGE'];
          if (range != null) {
            final at = range.indexOf('@');
            final len = int.tryParse(
                (at < 0 ? range : range.substring(0, at)).trim());
            if (len != null && len > 0) {
              currentMapLength = len;
              currentMapOffset =
                  at < 0 ? 0 : int.tryParse(range.substring(at + 1).trim());
            }
          }
          initUri ??= currentMapUri;
          isFmp4 = true;
        }
      } else if (line.startsWith('#EXT-X-BYTERANGE:')) {
        final v = line.substring('#EXT-X-BYTERANGE:'.length).trim();
        final at = v.indexOf('@');
        pendingRangeLength = int.tryParse((at < 0 ? v : v.substring(0, at)).trim());
        pendingRangeOffset =
            at < 0 ? null : int.tryParse(v.substring(at + 1).trim());
      } else if (line == '#EXT-X-DISCONTINUITY') {
        // 只认精确标签：#EXT-X-DISCONTINUITY-SEQUENCE 是另一回事，不能混算
        pendingDiscontinuity = true;
      } else if (line.startsWith('#EXTINF:')) {
        pendingDuration = double.tryParse(
                line.substring('#EXTINF:'.length).split(',').first.trim()) ??
            0;
      } else if (line.startsWith('#EXT-X-ENDLIST')) {
        isLive = false;
      }
    } else {
      final uri = base.resolve(line);
      int? rangeOffset;
      final rangeLength = pendingRangeLength;
      if (rangeLength != null && rangeLength > 0) {
        // 省略 @offset 时：同一个 URI 的上一个区间接着往后走，
        // 换了 URI 则从 0 开始（规范就是按「同一资源的上一段」定义的）。
        rangeOffset = pendingRangeOffset ??
            (lastRangeUri == uri && lastRangeEnd != null ? lastRangeEnd : 0);
        lastRangeEnd = rangeOffset + rangeLength;
        lastRangeUri = uri;
      }
      if (pendingDiscontinuity) discontinuities++;
      segments.add(HlsSegment(
        uri: uri,
        key: currentKey,
        sequence: mediaSequence + index,
        duration: pendingDuration,
        rangeOffset: rangeOffset,
        rangeLength: rangeLength,
        discontinuityBefore: pendingDiscontinuity,
        mapUri: currentMapUri,
        mapRangeOffset: currentMapOffset,
        mapRangeLength: currentMapLength,
      ));
      index++;
      pendingDuration = 0;
      pendingRangeLength = null;
      pendingRangeOffset = null;
      pendingDiscontinuity = false;
    }
  }

  return HlsMediaPlaylist(
    segments: segments,
    initUri: initUri,
    isFmp4: isFmp4,
    isLive: isLive,
    discontinuities: discontinuities,
  );
}
