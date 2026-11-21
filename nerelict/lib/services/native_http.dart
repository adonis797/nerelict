
import 'package:flutter/services.dart';

/// 用 Android 自带 HTTP 栈取字节。
///
/// 动机（实测）：有些站点按 **TLS / HTTP 栈**而不是请求头来识别客户端。
/// 同一个地址、同样只剩 `User-Agent` + `Referer`：
///
/// - ExoPlayer 直连 → 能拿到；
/// - Dart 的 `dart:io`（播放代理、Dio 下载）→ 403。
///
/// 用户侧的观察正好印证：关掉「边下边播缓存」时 HLS 直连能播，开启后改走
/// Dart 代理就播不了。所以下载也改走这条**已经证明能通**的栈。
///
/// 只做最小转发：调用方给什么头就发什么头，不补 Cookie、不补浏览器特征头。
class NativeHttp {
  const NativeHttp._();

  static const MethodChannel _channel =
      MethodChannel('com.nerelict/nativehttp');

  /// 发一次 GET。返回 `null` 表示通道不可用或请求异常（调用方自行回退）。
  static Future<({int status, Uint8List bytes, String url})?> fetch(
    String url,
    Map<String, String> headers, {
    String? range,
  }) async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'fetch',
        <String, dynamic>{
          'url': url,
          'headers': headers,
          if (range != null) 'range': range,
        },
      );
      if (raw == null) return null;
      final status = (raw['status'] as num?)?.toInt() ?? 0;
      final body = raw['bytes'];
      final bytes = body is Uint8List
          ? body
          : (body is List<int> ? Uint8List.fromList(body) : Uint8List(0));
      return (
        status: status,
        bytes: bytes,
        url: (raw['url'] as String?) ?? url,
      );
    } on MissingPluginException {
      // 主机端验证脚本没有这个通道
      return null;
    } catch (_) {
      return null;
    }
  }
}
