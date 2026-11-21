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

/// Cloudflare 通行证类 Cookie 的名字：缺少它时，403 的成因与「有它但仍被拒」完全不同。
const Set<String> kClearanceCookieNames = <String>{
  'cf_clearance',
  '__cf_bm',
  'cf_chl_2',
  'cf_chl_prog',
  '__cflb',
};

/// 从 Cookie 串里挑出名字（只要名字，不要值），并判断有没有通行证。
///
/// 名字不是秘密，值才是；这里返回布尔，避免调用方不小心把值带进日志。
bool hasClearanceCookie(String rawCookie) {
  for (final part in rawCookie.split(';')) {
    final eq = part.indexOf('=');
    if (eq <= 0) continue;
    final name = part.substring(0, eq).trim().toLowerCase();
    if (kClearanceCookieNames.contains(name)) return true;
  }
  return false;
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
/// - [challenged]：是否命中人机验证特征（`cf-mitigated` / 挑战页正文等）；
/// - [clearanceSent]：带的 Cookie 里有没有 Cloudflare 的通行证（`cf_clearance`）。
///   `null` 表示没带上 Cookie、无从判断。这一位是「去代取凭证」还是「去解决指纹」的分水岭：
///   带了 9 项 Cookie 却没带 `cf_clearance` 和「带了仍然被拒」是两件完全不同的事。
/// - [captureTried]：是否已经用 WebView 代取过一次。代取过还说「去代取」，
///   等于让用户重复同一步，所以这两种要分开说；
/// - [captureGotCookie]：代取那次到底拿到 Cookie 没有。「没拿到」多半是页面还没过验证，
///   「拿到了仍被拒」才是凭证与请求绑定不符——两者的下一步完全不同。
/// - [crossHost]：被拒的地址与当前页面是否不同域。分片常挂在独立 CDN 域名上，
///   此时「页面可见 Cookie」量的是页面那个域，对分片域没有参考价值，
///   必须单独成一种情况，否则会把「跨域」误判成「HttpOnly」。
AuthFailureReport describeAuthFailure({
  required bool cookieSent,
  required int cookieCount,
  required int? pageCookieLength,
  required bool challenged,
  bool? clearanceSent,
  bool captureTried = false,
  bool captureGotCookie = false,
  String captureNote = '',
  bool minimalTried = false,
  /// 这次实际发出去的头名字（不含值）。用来证明「精简模式」到底精简了什么。
  String headerNames = '',
  bool crossHost = false,
}) {
  if (cookieSent) {
    final label = clearanceSent == false
        ? 'Cookie 已带（$cookieCount 项，但缺 cf_clearance）'
        : 'Cookie 已带（$cookieCount 项）';
    if (challenged) {
      if (clearanceSent == false) {
        if (!captureTried) {
          return AuthFailureReport(
            label,
            '通行证是 HttpOnly，Cookie 通道读不到；需要由 WebView 上下文代取一次',
          );
        }
        if (!captureGotCookie) {
          final detail = captureNote.isEmpty ? '' : '（$captureNote）';
          return AuthFailureReport(
            label,
            '代取没拿到 Cookie$detail：先在页面里把该视频播放十几秒，'
                '确认人机验证已过再回来重试',
          );
        }
        return AuthFailureReport(
          label,
          '已代取到通行证仍被拒：凭证多半与本次请求的出口 IP / UA 绑定，或该地址禁止下载',
        );
      }
      return AuthFailureReport(
        label,
        '通行证已带上仍被判为自动化：属于 TLS / HTTP2 指纹差异，换 Cookie 或加头都无效',
      );
    }
    return AuthFailureReport(
      label,
      minimalTried
          ? '已改用与播放器相同的精简请求头（仅 UA + Referer）重试仍被拒：'
              '多半是签名已过期，或该地址不接受下载请求'
          : '仍被拒，多半是来源页校验或链接签名已过期',
    );
  }

  if (crossHost) {
    // 跨域是最容易被误读的一种：一味说「要按该域单独取凭证」，会让用户以为
    // 还没试过。这里把「试过什么」逐项摊开，下一步做什么才不重复。
    final tried = <String>[];
    if (minimalTried) {
      final where = headerNames.isEmpty ? '' : '（实际只发了 $headerNames）';
      tried.add('已改用与播放器相同的最小请求头$where重试');
    }
    if (captureTried) {
      tried.add(captureGotCookie
          ? '已按该域代取到凭证但仍被拒'
          : '已按该域代取过凭证但没取到${captureNote.isEmpty ? '' : '：$captureNote'}');
    }
    final head = '分片在独立域名上，页面的登录态带不过去';
    if (tried.isEmpty) {
      return AuthFailureReport(
        'Cookie 未取到（该域 0 项，且与当前页面不同域）',
        '$head：这类站点要按该域单独取凭证',
      );
    }
    return AuthFailureReport(
      'Cookie 未取到（该域 0 项，且与当前页面不同域）',
      '$head；${tried.join('，')}。该域自己有一道验证，只能在该域上过一次再下',
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
