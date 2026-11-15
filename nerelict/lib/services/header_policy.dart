import 'playlist_rewriter.dart' show stableCacheKey;

/// 请求头透传策略。
///
/// 为什么需要：一部分站点的播放地址不是靠 Cookie 鉴权，而是靠
/// `Authorization: Bearer …` 或自定义的 `X-*` 头。页面脚本能拿到这些头，
/// 但播放器与下载器只带 UA / Referer / Cookie，于是「网页里能播、Nerelict 报 403」。
///
/// 采集与回放分两处：
/// - `sniffer_js.dart` 在包装 fetch / XHR 时按同一套规则挑头；
/// - 这里是 Dart 侧的第二次过滤（页面脚本可被站点改写，不能当可信输入）。
///
/// 只放行鉴权类头，其余一律丢弃：`Cookie` / `Range` / `Referer` / `User-Agent`
/// 由链路自己生成，重复透传会覆盖掉正确值；`Host` / `Content-Length` 这类
/// 由 HTTP 客户端计算，手动设置会破坏请求。
class HeaderPolicy {
  HeaderPolicy._();

  /// 单次最多透传几个头：再多基本是站点把整份客户端指纹塞进来了。
  static const int kMaxHeaders = 8;

  /// 单个头的值上限。超长多见于把整个 JWT 链或 base64 blob 当头值，
  /// 截断后必然无效，直接丢弃比带着半个 token 去 403 更诚实。
  static const int kMaxValueLength = 1024;

  /// 放行：`Authorization`、`X-*`（业务自定义头）、`Origin`（部分 CDN 校验）。
  static final RegExp _allowed = RegExp(
    r'^(authorization|x-[a-z0-9!#$%&*+.^_`|~-]+|origin)$',
    caseSensitive: false,
  );

  /// 拒绝：链路自管或会破坏 HTTP 语义的头。
  static final RegExp _blocked = RegExp(
    r'^(cookie|set-cookie|host|content-length|content-type|content-encoding|'
    r'transfer-encoding|connection|range|if-[a-z-]+|referer|user-agent|'
    r'accept|accept-encoding|accept-language|pragma|cache-control|'
    r'sec-[a-z-]+|te|upgrade|proxy-[a-z-]+)$',
    caseSensitive: false,
  );

  /// 是否允许透传这个头。
  static bool allows(String name) {
    final n = name.trim();
    if (n.isEmpty || n.length > 64) return false;
    if (_blocked.hasMatch(n)) return false;
    return _allowed.hasMatch(n);
  }

  /// 清洗一批头：按小写名去重（后者覆盖前者，token 刷新时取新值），
  /// 丢弃空值、超长值、带换行的值。
  ///
  /// 返回不可变 Map，可直接放进任务模型或交给 HttpClient。
  static Map<String, String> sanitize(Map<String, String>? raw) {
    if (raw == null || raw.isEmpty) return const <String, String>{};
    final out = <String, String>{};
    // 小写名 -> 实际写入 out 的键，避免 `Authorization` 与 `authorization`
    // 同时存在时被 HttpClient 当成两个头发出
    final byLower = <String, String>{};
    for (final entry in raw.entries) {
      final name = entry.key.trim();
      if (!allows(name)) continue;
      var value = entry.value;
      // 换行会拆出额外的 header（头注入）。HttpClient 自己也会拒绝，
      // 但在进入请求前丢掉更安全，且不影响其它头的透传。
      if (value.contains('\n') || value.contains('\r')) continue;
      if (value.length > kMaxValueLength) continue;
      value = value.trim();
      if (value.isEmpty) continue;

      final lower = name.toLowerCase();
      final key = byLower[lower];
      if (key == null) {
        if (out.length >= kMaxHeaders) continue;
        byLower[lower] = name;
        out[name] = value;
      } else {
        out[key] = value;
      }
    }
    return Map<String, String>.unmodifiable(out);
  }

  /// 合并两批头：新的覆盖旧的（同名），仍然只保留白名单内的。
  static Map<String, String> merge(
    Map<String, String>? base,
    Map<String, String>? incoming,
  ) {
    if (incoming == null || incoming.isEmpty) return sanitize(base);
    if (base == null || base.isEmpty) return sanitize(incoming);
    return sanitize(<String, String>{...base, ...incoming});
  }

  /// 代理地址里的令牌：由目标地址派生，用于把「这批头属于哪个地址」
  /// 传给本地代理，而不把头的值写进 URL（会被日志与截图看到）。
  static String tokenFor(String url) {
    final key = stableCacheKey(url);
    final dot = key.lastIndexOf('.');
    final token = dot > 0 ? key.substring(0, dot) : key;
    return token.length > 12 ? token.substring(0, 12) : token;
  }

  /// 列表项上的说明：只列头名，不列值。
  static String describe(Iterable<String> names) => names.join(' · ');
}
