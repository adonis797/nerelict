/// 把「Cookie 可见性 + 响应特征」翻译成用户能照着做的一句话。
///
/// 之前所有 401/403 都收敛成一句「Cookie 未取到」，把三种完全不同的故障混在一起：
/// 该域没有 Cookie、Cookie 是 HttpOnly 读不到、带了 Cookie 仍被判自动化。
/// 判读表见 `docs/download-auth-and-challenge.md` §4。
///
/// 纯 Dart + 纯函数，主机端可直接断言，不依赖平台通道与真实网络。
library;

/// 诊断结果：一句状态标签 + 一句下一步建议。
class AuthFailureReport {
  const AuthFailureReport(this.cookieLabel, this.hint);

  /// 例如 `Cookie 未取到（该域 0 项，页面可见 0 字符）`。
  final String cookieLabel;

  /// 例如 `先在页面里把该视频播放十几秒，再回来重试`。
  final String hint;

  /// 给日志用的紧凑摘要，不含任何 Cookie 值。
  String get logLine => '$cookieLabel / $hint';

  @override
  String toString() => '$cookieLabel：$hint';
}

/// 关键凭证是不是 HttpOnly —— 也就是「该走浏览器代取」的那种情况。
///
/// 判定条件：我们一条 Cookie 都没带上，但页面自己有可见 Cookie。
bool looksHttpOnlyOnly({
  required bool cookieSent,
  required int? pageCookieLength,
}) {
  if (cookieSent) return false;
  final len = pageCookieLength;
  return len != null && len > 0;
}

/// 生成诊断文案。
///
/// - [cookieSent]：这次请求有没有带上 Cookie；
/// - [cookieCount]：带上（或读到）的 Cookie 条数，只用于展示，不含名字与值；
/// - [pageCookieLength]：`document.cookie.length`，`null` 表示读不到；
/// - [challenged]：是否命中人机验证特征（`cf-mitigated` / 挑战页正文等）。
AuthFailureReport describeAuthFailure({
  required bool cookieSent,
  required int cookieCount,
  required int? pageCookieLength,
  required bool challenged,
}) {
  if (cookieSent) {
    final label = 'Cookie 已带（$cookieCount 项）';
    return AuthFailureReport(
      label,
      challenged
          ? '已带 Cookie 仍被判为自动化访问：属于请求特征差异（头部与指纹），不是登录态问题'
          : '仍被拒，多半是来源页校验或链接签名已过期',
    );
  }

  final page = pageCookieLength;
  if (page == null) {
    return AuthFailureReport(
      'Cookie 未取到（该域 0 项，页面 Cookie 读数不可用）',
      '先在页面里把该视频播放十几秒，让站点把凭证发下来，再回来重试',
    );
  }
  if (page == 0) {
    return AuthFailureReport(
      'Cookie 未取到（该域 0 项，页面也没有可见 Cookie）',
      '说明该站点的登录态或人机验证没有在 App 内完成：先在页面里播放十几秒，或重新登录后再试',
    );
  }
  return AuthFailureReport(
    'Cookie 未取到（该域 0 项，但页面有 $page 个字符的可见 Cookie）',
    '关键凭证是 HttpOnly，读取通道拿不到；下载改由 WebView 上下文代取（见文档 §6）',
  );
}
