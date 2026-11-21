/// 「页面可见 Cookie」探针。
///
/// 只回答一个问题：同一个域，`CookieManager.getCookie(url)` 读不到东西时，
/// 页面上到底有没有 Cookie。用来区分两种完全不同的故障：
///
/// - 该域确实没有 Cookie（用户没在 App 里过挑战 / 分片在另一个域）；
/// - Cookie 存在但都是 `HttpOnly`，读取通道看不到。
///
/// 判读表见 `docs/download-auth-and-challenge.md` §4。
///
/// 刻意保持极简且无副作用：不参与鉴权判断、不缓存 Cookie 值、不落盘。
/// 纯 Dart（无 Flutter 依赖），下载器可以在同步的错误文案里直接读 [lastLength]。
class PageCookieProbe {
  const PageCookieProbe._();

  /// 由 `browser_tab` 注入：在本页执行一次 `document.cookie.length`。
  static Future<int?> Function()? _reader;

  /// 最近一次读到的字符数；`null` 表示从未读到（没有 WebView、注入失败或页面还没加载完）。
  static int? lastLength;

  /// 最近一次读取对应的 host，换站时用来判断要不要丢弃旧值。
  static String lastHost = '';

  static void attach(Future<int?> Function()? reader) {
    _reader = reader;
  }

  /// 刷新一次读数。失败时保留旧值，不把「读不到」当成「没有 Cookie」。
  ///
  /// 调用点只有两处：页面加载完成、以及 403 之后补刷一次给下一次重试用。
  static Future<void> refresh(String host) async {
    final reader = _reader;
    if (reader == null) return;
    int? value;
    try {
      value = await reader();
    } catch (_) {
      return;
    }
    if (value == null) return;
    lastLength = value;
    lastHost = host.toLowerCase();
  }

  /// 取某个 host 的读数；host 不一致说明是上一个站点的旧值，宁可返回 null。
  static int? lengthFor(String host) {
    if (lastLength == null) return null;
    if (lastHost.isEmpty) return lastLength;
    return lastHost == host.toLowerCase() ? lastLength : null;
  }

  static void clear() {
    lastLength = null;
    lastHost = '';
  }
}
