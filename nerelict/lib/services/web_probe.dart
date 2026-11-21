import 'package:flutter/services.dart';

/// 用 WebView 上下文代取一次请求头。
///
/// 为什么必须这么做：Cloudflare 的 `cf_clearance` 带 `HttpOnly`，
/// `CookieManager.getCookie()` 走的是 JS 可见的那份存储，读出来是空的（已实证）。
/// 而 WebView 自己的 `shouldInterceptRequest` 能看到**真实出站头**，包含 HttpOnly。
///
/// 两个前提与一条边界：
/// - 可见 WebView 必须已经过验证（同进程共享 CookieManager，隐藏的这一个才会直接带上凭证）；
/// - 只抓目标主机那一次请求的头，抓到就销毁 WebView；
/// - 只返回 `Cookie` 字符串，不落盘、不进日志、不写进任务模型。
class WebProbe {
  const WebProbe._();

  static const MethodChannel _channel = MethodChannel('com.nerelict/webprobe');

  /// 抓一次目标地址的 Cookie。拿不到返回 null，调用方按原样继续（不死等）。
  static Future<String?> captureCookie(String url, {String? userAgent}) async {
    final headers = await captureHeaders(url, userAgent: userAgent);
    if (headers == null) return null;
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'cookie') {
        final value = entry.value.trim();
        return value.isEmpty ? null : value;
      }
    }
    return null;
  }

  /// 抓一次请求头。键名保持原样（服务端看到的形态），值不建议外传。
  static Future<Map<String, String>?> captureHeaders(
    String url, {
    String? userAgent,
  }) async {
    if (!url.startsWith('http://') && !url.startsWith('https://')) return null;
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'captureHeaders',
        <String, dynamic>{'url': url, 'userAgent': userAgent},
      );
      if (raw == null) return null;
      final out = <String, String>{};
      raw.forEach((k, v) {
        if (k is String && v != null) out[k] = v.toString();
      });
      return out.isEmpty ? null : out;
    } on MissingPluginException {
      // 主机端脚本 / 旧原生层没有这个通道
      return null;
    } catch (_) {
      return null;
    }
  }
}
