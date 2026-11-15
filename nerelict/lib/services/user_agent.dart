/// 出站请求统一使用的 User-Agent。
///
/// 单独放一个文件是为了保持依赖方向：下载器、播放代理、媒体层都要用它，
/// 但下载器必须在主机端能 `dart run` 跑测试，不能因为引用媒体层而把
/// `package:flutter` 拖进来（会需要 dart:ui，纯 Dart 环境编不了）。
///
/// 为什么必须统一：源站是按 WebView 那个 UA 发的地址。换成下载器自带的
/// UA 去取，等于「同一个地址、另一个客户端」，不少 CDN 会直接 403。
library;

class UserAgent {
  UserAgent._();

  /// 当前使用的 UA。WebView 建好后会换成它的真实值。
  static String current = kFallback;

  /// 兜底 UA：不含任何自家品牌 token，避免被站点的 UA 白名单挡下。
  static const String kFallback =
      'Mozilla/5.0 (Linux; Android 15; Pixel 8) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

  /// 采纳 WebView 的 UA。只接受看起来像浏览器 UA 的值，
  /// 防止某些定制 WebView 返回空串或 `MyApp/1.0` 把出站请求搞得不像浏览器。
  static void adopt(String? ua) {
    final value = ua?.trim() ?? '';
    final lower = value.toLowerCase();
    if (value.length < 20) return;
    if (!lower.contains('mozilla') || !lower.contains('applewebkit')) return;
    current = value;
  }
}
