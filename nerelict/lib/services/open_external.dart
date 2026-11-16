import 'package:flutter/services.dart';

/// 把自定义 scheme 深链交给系统处理。
///
/// WebView 自己开不了 `weixin://`、`mqqapi://`、`alipays://` 这类地址，
/// 而它们正是微信 / QQ / 支付宝 / 运营商一键登录的唯一入口。
/// 以前 `onNavigationRequest` 一律拦掉，用户看到的就是「点登录按钮完全没反应」，
/// 而且没有任何提示可循——所以这里至少要把请求递出去，并让调用方能报失败。
///
/// 只做「递交给系统」，不判断应用是否存在：`startActivity` 抛
/// `ActivityNotFoundException` 时原生侧返回 false，由调用方给提示。
class OpenExternal {
  const OpenExternal._();

  static const MethodChannel _channel = MethodChannel('com.nerelict/external');

  /// 尝试用系统里能处理该 scheme 的应用打开。返回 false 表示没有可用应用，
  /// 或平台通道不可用（主机端脚本里跑不到这个能力）。
  static Future<bool> open(String url) async {
    if (!url.contains('://')) return false;
    try {
      final ok =
          await _channel.invokeMethod<bool>('open', <String, dynamic>{'url': url});
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }
}
