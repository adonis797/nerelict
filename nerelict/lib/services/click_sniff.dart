import 'dart:convert';

import '../models/sniffed_media.dart' show kOverlayThreshold;

/// 点击捕获上报的事件类型。
///
/// - [click]：页面某处被点了一下，归因窗口开启（只用于提示与序号）；
/// - [hit]：窗口内捕获到一条媒体地址，可能来自播放列表 / 分片 / 直链；
/// - [overlay]：播放器容器被判定为「点击后浮起的浮层」，带置信分；
/// - [mse]：播放器走 MediaSource（blob 地址），真实地址在 JS 侧不可见；
/// - [iframe]：跨域 iframe 播放器，只能拿到播放器所在地址。
enum ClickEventType {
  click,
  hit,
  overlay,
  mse,
  iframe,

  /// 广告防护：清掉遮挡层 / 拒掉点击弹窗（与媒体无关，只用于提示）
  shield,
}

/// 一条点击捕获事件。
///
/// 解析刻意宽松：页面里任何脚本都能往通道里塞消息，字段缺失或类型不对时
/// 一律返回 null 或空值，绝不让一条脏消息打断嗅探链路。
class ClickSniffEvent {
  const ClickSniffEvent({
    required this.type,
    required this.sessionId,
    this.url = '',
    this.kind = '',
    this.from = '',
    this.delayMs = 0,
    this.overlayScore = 0,
    this.overlayTag = '',
    this.label = '',
    this.page = '',
    this.title = '',
  });

  final ClickEventType type;

  /// 第几次点击（页面内自增，换页后从 1 重新计）
  final int sessionId;

  /// hit / iframe 才有：媒体地址或播放器地址
  final String url;

  /// playlist / segment / progressive
  final String kind;

  /// fetch / xhr / play / video / dom / iframe / perf
  final String from;

  /// 从点击到捕获的毫秒数
  final int delayMs;

  /// 浮层置信分（0~100），达到 [kOverlayThreshold] 才算浮层播放
  final int overlayScore;

  /// 被判定为浮层的元素标签名
  final String overlayTag;

  /// 点击目标描述，例如 `div.thumb 「第 3 集」`
  final String label;

  final String page;
  final String title;

  bool get isOverlay => overlayScore >= kOverlayThreshold;
  bool get isMse => type == ClickEventType.mse;

  /// 适合放进提示语的一行描述
  String get summary {
    switch (type) {
      case ClickEventType.click:
        return '已记录点击 #$sessionId${label.isEmpty ? '' : ' · $label'}';
      case ClickEventType.hit:
        return '#$sessionId 捕获${isOverlay ? '浮层' : ''}视频（${delayMs}ms）';
      case ClickEventType.overlay:
        return '#$sessionId 浮层置信 $overlayScore';
      case ClickEventType.mse:
        return '#$sessionId 使用 MSE 播放';
      case ClickEventType.iframe:
        return '#$sessionId 跨域播放器';
      case ClickEventType.shield:
        return kind == 'popup' ? '已拦截点击弹窗' : '已移除广告遮挡层';
    }
  }

  static ClickSniffEvent? parse(String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;

    final type = switch (_str(decoded['t'])) {
      'click' => ClickEventType.click,
      'hit' => ClickEventType.hit,
      'overlay' => ClickEventType.overlay,
      'mse' => ClickEventType.mse,
      'iframe' => ClickEventType.iframe,
      'shield' => ClickEventType.shield,
      _ => null,
    };
    if (type == null) return null;

    final url = _str(decoded['url']);
    // 只有 hit / iframe 需要地址，其余类型缺地址也照常收
    if ((type == ClickEventType.hit || type == ClickEventType.iframe) &&
        !url.startsWith('http')) {
      return null;
    }

    return ClickSniffEvent(
      type: type,
      sessionId: _int(decoded['id']),
      url: url,
      kind: _str(decoded['kind']),
      from: _str(decoded['from']),
      delayMs: _int(decoded['delay']),
      overlayScore: _int(decoded['score']).clamp(0, 100),
      overlayTag: _str(decoded['tag']).toLowerCase(),
      label: _str(decoded['label']),
      page: _str(decoded['page']),
      title: _str(decoded['title']),
    );
  }

  static String _str(Object? v) => v is String ? v.trim() : '';

  static int _int(Object? v) {
    if (v is int) return v;
    if (v is double) return v.round();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }
}
