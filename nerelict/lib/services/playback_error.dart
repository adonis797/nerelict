/// 把播放内核抛出的原始错误翻译成用户能看懂、能据此行动的一句话。
///
/// 原始错误长这样（真机截图里就是这一条）：
/// `PlatformException(VideoError, Video player had error zn: Source error, null, null)`
/// —— 既不告诉用户是「要登录」「地址过期」还是「设备解不了这个编码」，
/// 也不告诉他下一步该做什么。这里按已知错误码归类，输出人话 + 建议动作。
library;

/// 归类结果：主文案 + 建议动作（可为空）。
class PlaybackErrorInfo {
  const PlaybackErrorInfo(this.summary, [this.hint = '']);

  final String summary;
  final String hint;

  bool get isEmpty => summary.isEmpty && hint.isEmpty;

  /// 卡片上显示的一整行
  String get text => hint.isEmpty ? summary : '$summary（$hint）';
}

/// 原始错误里常见的可识别片段 → 人话。
const List<(String, String, String)> _rules = <(String, String, String)>[
  ('DRM', '内容受 DRM 保护', 'Nerelict 不支持解密，请用官方播放器'),
  ('Protected', '内容受版权保护', 'Nerelict 不支持解密'),
  ('license', '受 DRM 保护，需要许可证', 'Nerelict 不支持解密'),
  ('403', '服务器拒绝访问（403）', '可能需要登录或防盗链，试试先在网页里播一次'),
  ('404', '地址不存在（404）', '链接可能已过期，重新嗅探一次'),
  ('410', '地址已失效（410）', '重新嗅探一次'),
  ('UnrecognizedInputFormat', '容器格式无法识别', '可能不是标准 MP4/HLS'),
  ('ParserException', '媒体索引损坏或格式不受支持', '可尝试重新嗅探或下载后转 MP4'),
  ('Decoder', '设备解码器不支持该编码', '常见于 HEVC / AV1，换设备或下载后转码'),
  ('decoder', '设备解码器不支持该编码', '常见于 HEVC / AV1，换设备或下载后转码'),
  ('codec', '设备缺少对应解码器', '常见于 HEVC / AV1'),
  ('Timeout', '请求超时', '网络较慢或源站限速，可重试'),
  ('timeout', '请求超时', '网络较慢或源站限速，可重试'),
  ('Failed host lookup', '域名解析失败', '检查网络或代理'),
  ('Connection', '网络连接中断', '可重试'),
  ('Source error', '视频源打不开', '可能需要登录 / 防盗链、地址已过期，或格式不受支持'),
  ('Invalid', '媒体数据无效', '可能只嗅探到分片的一部分，重新嗅探'),
];

/// 去掉 `PlatformException(...)` 外壳与 `, null, null` 尾巴，便于展示与匹配。
String stripPlatformException(String raw) {
  var s = raw.trim();
  const prefix = 'PlatformException(';
  if (s.startsWith(prefix)) s = s.substring(prefix.length);
  if (s.endsWith(')')) s = s.substring(0, s.length - 1);
  s = s.replaceAll(RegExp(r',\s*null(,\s*null)*\s*$'), '');
  return s.trim();
}

/// 归类原始错误。无法识别时返回原样（至少不丢信息）。
PlaybackErrorInfo humanizePlaybackError(String raw) {
  final plain = stripPlatformException(raw);
  if (plain.isEmpty) return const PlaybackErrorInfo('未知错误');
  final lower = plain.toLowerCase();
  for (final rule in _rules) {
    final needle = rule.$1;
    final hit = needle.length <= 4
        ? plain.contains(needle) || lower.contains(needle.toLowerCase())
        : lower.contains(needle.toLowerCase());
    if (hit) return PlaybackErrorInfo(rule.$2, rule.$3);
  }
  return PlaybackErrorInfo(plain);
}

/// 单行摘要（用于卡片标题区，尽量短）。
String playbackErrorSummary(String raw) => humanizePlaybackError(raw).text;
