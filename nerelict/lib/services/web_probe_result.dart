/// WebView 代取的结果与「为什么没拿到」的说明。
///
/// 单独放纯 Dart 文件：下载器要用这个类型，而下载器必须保持无 Flutter 依赖
/// （`verify_download` / `verify_v042` 直接 `dart run` 跑它）。
class WebProbeResult {
  const WebProbeResult({
    required this.headers,
    required this.requests,
    required this.withCookie,
    required this.pages,
    this.fetches = 0,
    this.domainCookies = -1,
    this.fetchResult = '',
    this.error,
  });

  /// 抓到的请求头（不含 `__probe*` 诊断字段）
  final Map<String, String> headers;

  /// 隐藏 WebView 一共发出多少个同主机请求
  final int requests;

  /// 其中带 Cookie 头的个数
  final int withCookie;

  /// 加载完成的页面数：0 说明根页根本没打开（多半被同一套验证挡住）
  final int pages;

  /// 一共发了几轮页面内 fetch。人机验证常是「先给挑战页、几秒后自动跳回」，
  /// 所以是一轮轮试，[fetches] 用来区分「试过多次都不行」和「只来得及试一次」。
  final int fetches;

  /// 该域在 WebView 里一共有几份 Cookie（-1 表示没读到）。
  ///
  /// 这一位用来分开两件事：`0` 说明人机验证根本没走完（该域一份都没下发），
  /// `大于 0 却没带上` 则是请求头被裁——修法完全不同，不能混成一句。
  final int domainCookies;

  /// 页面内 `fetch` 的返回值：`ok:<状态码>` 或 `err:<异常>`。
  final String fetchResult;

  /// 原生侧异常信息
  final String? error;

  String? get cookie {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'cookie') {
        final value = entry.value.trim();
        return value.isEmpty ? null : value;
      }
    }
    return null;
  }

  /// 一句话说清卡在哪一步。
  ///
  /// 这串会**直接进错误提示**：这台 ROM 会过滤第三方应用的 `Log.d`，
  /// 靠日志问用户「卡在哪」不现实，答案要落在屏幕上。
  String get note {
    final err = error;
    if (err != null && err.isNotEmpty) return '隐藏页面出错：$err';
    if (pages == 0) return '隐藏页面没打开（0 个页面加载完成）';
    if (requests == 0) return '隐藏页面打开后没发出任何请求';
    // fetch 的返回最能说明问题：有没有发出去、对方给了什么状态码
    final fetched = fetchResult;
    if (fetched.startsWith('err:')) {
      return '页面内 fetch 根本没发出去（${fetched.substring(4)}）';
    }
    if (fetched.startsWith('ok:')) {
      // 格式是 `ok:<状态码>:<正文开头>`，正文用来分辨「防盗链」和「人机验证」
      final rest = fetched.substring(3);
      final sep = rest.indexOf(':');
      final status = sep >= 0 ? rest.substring(0, sep) : rest;
      final body = sep >= 0 ? rest.substring(sep + 1).trim() : '';
      final hint = _bodyHint(body);
      if (domainCookies == 0) {
        return '页面内 fetch 返回 $status$hint，该域一份 Cookie 都没下发'
            '（人机验证没走完，$fetches 轮都没过）';
      }
      if (domainCookies > 0 && withCookie == 0) {
        return '页面内 fetch 返回 $status$hint，该域有 $domainCookies 份 Cookie '
            '但请求没带上（头被裁）';
      }
      return '页面内 fetch 返回 $status$hint'
          '（该域 Cookie ${domainCookies < 0 ? '未知' : domainCookies} 份）';
    }
    if (withCookie == 0) {
      final times = fetches > 0 ? '连续 $fetches 轮' : '';
      return '隐藏页面$times共 $requests 个请求都没带 Cookie';
    }
    if (cookie == null) return '请求带了 Cookie 头但内容为空';
    return '隐藏页面 $requests 个请求里有 $withCookie 个带 Cookie';
  }

  /// 从响应体开头认出常见的拒绝类型：比状态码精确得多。
  String _bodyHint(String body) {
    if (body.isEmpty) return '';
    final lower = body.toLowerCase();
    if (lower.contains('just a moment') ||
        lower.contains('cf-challenge') ||
        lower.contains('challenge-platform') ||
        lower.contains('attention required')) {
      return '（正文是 Cloudflare 挑战页）';
    }
    if (lower.contains('<html')) return '（正文是 HTML，不是 m3u8）';
    if (body.startsWith('#EXTM3U')) return '（正文是合法清单）';
    return '（正文：${body.length > 40 ? '${body.substring(0, 40)}…' : body}）';
  }
}
