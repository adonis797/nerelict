import 'package:flutter/services.dart';

import 'app_log.dart';
import 'web_probe_result.dart';

/// 用 WebView 上下文代取一次请求头。
///
/// 为什么必须这么做：Cloudflare 的 `cf_clearance` 带 `HttpOnly`，
/// `CookieManager.getCookie()` 走的是 JS 可见的那份存储，读出来是空的（已实证）。
/// 而 WebView 自己的 `shouldInterceptRequest` 能看到**真实出站头**。
///
/// 一个必须记住的坑：**主框架导航拿不到 Cookie 头**，只有子资源请求才带全。
/// 所以原生侧先加载 `scheme://host/` 根页，再在页面里 `fetch` 目标地址。
///
/// 两个前提与一条边界：
/// - 可见 WebView 必须已经过验证（同进程共享 CookieManager）；
/// - 只抓目标主机那一次带 Cookie 的请求，抓到就销毁 WebView；
/// - 只把 Cookie 串交给下载链路，不落盘、不进任务模型、不打日志。
class WebProbe {
  const WebProbe._();

  static const MethodChannel _channel = MethodChannel('com.nerelict/webprobe');

  /// 抓一次目标地址的请求头，连同「为什么没抓到」的诊断一起返回。
  static Future<WebProbeResult?> capture(
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

      final headers = <String, String>{};
      var requests = 0;
      var withCookie = 0;
      var pages = 0;
      String? error;
      raw.forEach((k, v) {
        if (k is! String || v == null) return;
        final value = v.toString();
        // `__probe*` 是原生附带的诊断字段，不是真实请求头
        switch (k) {
          case '__probeRequests':
            requests = int.tryParse(value) ?? 0;
            break;
          case '__probeWithCookie':
            withCookie = int.tryParse(value) ?? 0;
            break;
          case '__probePages':
            pages = int.tryParse(value) ?? 0;
            break;
          case '__probeError':
            error = value;
            break;
          default:
            if (!k.startsWith('__')) headers[k] = value;
        }
      });

      final result = WebProbeResult(
        headers: headers,
        requests: requests,
        withCookie: withCookie,
        pages: pages,
        error: error,
      );
      logD('WebProbe',
          'req=$requests cookie=$withCookie pages=$pages has=${result.cookie != null}');
      return result;
    } on MissingPluginException {
      // 主机端脚本 / 旧原生层没有这个通道
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 只取 Cookie 串；拿不到返回 null。
  static Future<String?> captureCookie(String url, {String? userAgent}) async {
    final result = await capture(url, userAgent: userAgent);
    return result?.cookie;
  }
}
