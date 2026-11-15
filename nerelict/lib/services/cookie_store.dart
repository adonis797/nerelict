import 'dart:async';

import 'package:flutter/services.dart';

/// 从 WebView 的 CookieManager 取当前站点 Cookie，供下载与播放代理复用。
///
/// 为什么要它：下载器只带 Referer 和 User-Agent，而很多站点的分片需要登录态，
/// 直接请求会 403；同一地址在 WebView 里却能播，因为浏览器自己带了 Cookie。
/// 取到之后用同一身份下载，行为才和「能播放」对齐。
///
/// 三条硬约束：
/// - **只在内存里**：不落盘、不写进任务 JSON、不进日志，避免登录凭证留在磁盘；
/// - **按 host 缓存**：同域分片共享一次查询，避免每个分片都过一次平台通道；
/// - **缓存要短**：站点常用短期签名 Cookie，缓存太久反而拿到已失效的值。
class CookieStore {
  CookieStore._();

  static final CookieStore instance = CookieStore._();

  static const MethodChannel _channel = MethodChannel('com.nerelict/cookie');

  /// 缓存有效期。短到能跟上签名刷新，长到不必为每个分片查一次。
  static const Duration ttl = Duration(seconds: 90);

  final Map<String, _Entry> _cache = <String, _Entry>{};

  /// 取某个地址对应的 Cookie 串；没有、不支持或原生层缺失时返回 null。
  ///
  /// 返回 null 表示「按匿名请求继续」，调用方不应把它当成错误。
  Future<String?> cookiesFor(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasAuthority) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;

    final host = uri.host.toLowerCase();
    final now = DateTime.now();
    final hit = _cache[host];
    if (hit != null && now.difference(hit.at) < ttl) return hit.value;

    String? value;
    try {
      value = await _channel.invokeMethod<String>(
        'get',
        <String, dynamic>{'url': url},
      );
    } on MissingPluginException {
      // 主机端验证脚本 / 旧原生层没有这个通道，按匿名请求处理
      return null;
    } on PlatformException {
      return null;
    } catch (_) {
      return null;
    }

    final trimmed = value?.trim();
    _cache[host] = _Entry(
      trimmed == null || trimmed.isEmpty ? null : trimmed,
      now,
    );
    return _cache[host]!.value;
  }

  /// 换站点或用户重新登录后丢弃缓存，避免把上一个站的凭证带过去。
  void invalidate([String? host]) {
    if (host == null || host.isEmpty) {
      _cache.clear();
      return;
    }
    _cache.remove(host.toLowerCase());
  }

  /// 仅供调试：当前缓存了多少个站点（不含 Cookie 内容本身）。
  int get cachedHostCount => _cache.length;
}

class _Entry {
  const _Entry(this.value, this.at);

  final String? value;
  final DateTime at;
}
