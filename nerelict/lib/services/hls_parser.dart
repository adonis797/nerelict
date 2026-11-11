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
  });

  final Uri uri;

  /// null 表示该分片未加密
  final HlsKey? key;

  /// 媒体序号，AES-128 未显式给 IV 时要用它推导
  final int sequence;
  final double duration;
}

class HlsMediaPlaylist {
  HlsMediaPlaylist({
    required this.segments,
    required this.initUri,
    required this.isFmp4,
    required this.isLive,
  });

  final List<HlsSegment> segments;

  /// #EXT-X-MAP 的初始化分片（fMP4 才有）
  final Uri? initUri;
  final bool isFmp4;
  final bool isLive;

  Duration get totalDuration => segments.fold(
        Duration.zero,
        (acc, s) => acc + Duration(milliseconds: (s.duration * 1000).round()),
      );
}

class HlsVariant {
  HlsVariant({required this.uri, required this.bandwidth, this.resolution});

  final Uri uri;
  final int bandwidth;
  final String? resolution;

  String get label {
    final bw = bandwidth >= 1000000
        ? '${(bandwidth / 1000000).toStringAsFixed(1)} Mbps'
        : '${(bandwidth / 1000).round()} kbps';
    return resolution == null ? bw : '$resolution · $bw';
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

List<HlsVariant> parseMasterPlaylist(String text, Uri base) {
  final lines = const LineSplitter().convert(text);
  final variants = <HlsVariant>[];
  Map<String, String>? pending;
  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#EXT-X-STREAM-INF:')) {
      pending = parseAttributes(line.substring('#EXT-X-STREAM-INF:'.length));
    } else if (!line.startsWith('#') && pending != null) {
      variants.add(HlsVariant(
        uri: base.resolve(line),
        bandwidth: int.tryParse(pending['BANDWIDTH'] ?? '') ?? 0,
        resolution: pending['RESOLUTION'],
      ));
      pending = null;
    }
  }
  variants.sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
  return variants;
}

HlsMediaPlaylist parseMediaPlaylist(String text, Uri base) {
  final lines = const LineSplitter().convert(text);
  final segments = <HlsSegment>[];
  HlsKey? currentKey;
  Uri? initUri;
  var isFmp4 = false;
  var isLive = true;
  var mediaSequence = 0;
  var index = 0;
  var pendingDuration = 0.0;

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
          initUri = base.resolve(uriStr);
          isFmp4 = true;
        }
      } else if (line.startsWith('#EXTINF:')) {
        pendingDuration = double.tryParse(
                line.substring('#EXTINF:'.length).split(',').first.trim()) ??
            0;
      } else if (line.startsWith('#EXT-X-ENDLIST')) {
        isLive = false;
      }
    } else {
      segments.add(HlsSegment(
        uri: base.resolve(line),
        key: currentKey,
        sequence: mediaSequence + index,
        duration: pendingDuration,
      ));
      index++;
      pendingDuration = 0;
    }
  }

  return HlsMediaPlaylist(
    segments: segments,
    initUri: initUri,
    isFmp4: isFmp4,
    isLive: isLive,
  );
}
