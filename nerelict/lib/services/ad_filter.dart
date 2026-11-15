/// 广告识别：只看地址形态，不认站点。
///
/// 目标不是「拦住所有广告」，而是在「点击后跳走 / 页面顶部混着广告媒体」这类
/// 场景里把明显是广告的地址挑出来，避免它抢走自动接管、占满嗅探列表。
/// 因此规则刻意保守：
///
/// - **高置信**：命中已知广告网络域名。这类域名只做广告，可以据此自动回退。
/// - **中置信**：路径里有独占的广告段（`/ads/`、`/preroll/`、`vast` 等）。
///   只按「整段」匹配，绝不按子串，`download`、`shadow`、`adapter` 这类不会被误伤。
/// - 其余一律不判广告——宁可漏掉，也不要误杀真实视频。
library;

/// 已知广告网络 / 广告投放域名（后缀匹配，含子域）。
const List<String> _adHosts = <String>[
  'doubleclick.net',
  'googlesyndication.com',
  'googleadservices.com',
  'adservice.google.com',
  '2mdn.net',
  'adsystem.com',
  'amazon-adsystem.com',
  'adnxs.com',
  'rubiconproject.com',
  'pubmatic.com',
  'openx.net',
  'criteo.com',
  'criteo.net',
  'taboola.com',
  'outbrain.com',
  'mgid.com',
  'zergnet.com',
  'popads.net',
  'popcash.net',
  'propellerads.com',
  'onclckds.com',
  'exoclick.com',
  'exosrv.com',
  'juicyads.com',
  'trafficjunky.net',
  'trafficfactory.biz',
  'adsterra.com',
  'hilltopads.net',
  'clickadu.com',
  'adcash.com',
  'adcolony.com',
  'applovin.com',
  'vungle.com',
  'inmobi.com',
  'startapp.com',
  'smartadserver.com',
  'adform.net',
  '33across.com',
  'yieldmo.com',
  'teads.tv',
  'spotxchange.com',
  'springserve.com',
  'tremorhub.com',
  'aniview.com',
  'vi.ai',
];

/// 独占路径段：整段相等才会命中。
const Set<String> _adSegments = <String>{
  'ad',
  'ads',
  'adv',
  'adserver',
  'adservers',
  'advert',
  'adverts',
  'advertisement',
  'advertisements',
  'preroll',
  'midroll',
  'postroll',
  'pre-roll',
  'mid-roll',
  'post-roll',
  'prebid',
  'vast',
  'vpaid',
  'companion',
  'interstitial',
  'adslot',
  'adunit',
  'adtag',
  'adzone',
  'adcall',
  'sponsored',
};

/// 段前缀：`adserver-01`、`preroll_720`、`vast3` 这类带后缀的命名。
const List<String> _adSegmentPrefixes = <String>[
  'adserver',
  'advert',
  'preroll',
  'midroll',
  'postroll',
  'adslot',
  'adunit',
  'adtag',
  'adzone',
  'adcall',
  'vast',
];

/// 判定结果。[reason] 用于界面提示与日志，[highConfidence] 才允许自动回退。
class AdVerdict {
  const AdVerdict({required this.isAd, this.reason = '', this.highConfidence = false});

  static const AdVerdict clean = AdVerdict(isAd: false);

  final bool isAd;
  final String reason;
  final bool highConfidence;

  bool get isHighConfidenceAd => isAd && highConfidence;
}

/// 地址层面的广告判定，全部是纯函数，方便主机端测试。
class AdFilter {
  const AdFilter._();

  /// 媒体地址是否疑似广告（用于嗅探列表标记与自动接管拦截）。
  static AdVerdict inspect(String url) => _inspect(url);

  static bool isAdUrl(String url) => _inspect(url).isAd;

  /// 页面地址是否疑似广告落地页（用于点击跳转兜底）。
  static AdVerdict inspectPage(String url) => _inspect(url);

  static AdVerdict _inspect(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.host.isEmpty) return AdVerdict.clean;

    final host = uri.host.toLowerCase();
    for (final suffix in _adHosts) {
      if (host == suffix || host.endsWith('.$suffix')) {
        return AdVerdict(
          isAd: true,
          reason: '广告域名 $suffix',
          highConfidence: true,
        );
      }
    }

    for (final segment in uri.pathSegments) {
      final s = segment.toLowerCase();
      if (_adSegments.contains(s)) {
        return AdVerdict(isAd: true, reason: '路径段 /$s');
      }
      for (final prefix in _adSegmentPrefixes) {
        // 必须有分隔符或数字后缀，避免 legit「advertise.mp4」之外的东西也被吞掉
        if (s.startsWith(prefix) &&
            (s.length == prefix.length ||
                !_isLetter(s.codeUnitAt(prefix.length)))) {
          return AdVerdict(isAd: true, reason: '路径段 /$s');
        }
      }
    }

    // VAST / VPAID 常见于查询参数（?type=vast），只认整词
    final query = uri.query.toLowerCase();
    if (query.contains('vast') || query.contains('vpaid')) {
      return const AdVerdict(isAd: true, reason: 'VAST/VPAID 参数');
    }
    return AdVerdict.clean;
  }

  static bool _isLetter(int code) =>
      (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
}
