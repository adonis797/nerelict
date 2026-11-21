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
    if (withCookie == 0) return '隐藏页面的 $requests 个请求都没带 Cookie';
    if (cookie == null) return '请求带了 Cookie 头但内容为空';
    return '隐藏页面 $requests 个请求里有 $withCookie 个带 Cookie';
  }
}
