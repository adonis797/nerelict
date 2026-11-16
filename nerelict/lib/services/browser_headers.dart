/// 回源媒体请求的「浏览器等效头」。
///
/// 目的：让 m3u8 与分片的请求更像页面里发出的 XHR，而不是一个裸 HTTP 客户端。
/// 背景见 `docs/download-auth-and-challenge.md` §5：不少站点（尤其挂在 Cloudflare 后面的）
/// 会按请求头的完整度给人机打分，只有 UA / Referer / Cookie 的请求很容易被判成自动化。
///
/// 边界刻意为「只补浏览器一定会带、且值可以静态确定」的头：
///
/// - **不碰** `User-Agent` / `Referer` / `Cookie` / `Range`：这几项必须反映真实会话，
///   由调用方（下载器、代理）自己填，本模块绝不覆盖；
/// - **不加** `sec-ch-ua` 系列：Chromium 确实会带，但品牌串必须与 UA 里的 Chrome 版本一一对应，
///   猜错比不带更容易被识别；单独带 `sec-ch-ua-mobile` 反而更不自然；
/// - **不改** ExoPlayer 直连（`MediaSource.headers`）：播放当前是通的，
///   往已知可用的路径上加变量只会引入新问题，等有「播放也被挑战」的实例再说。
///
/// 纯 Dart，无 Flutter 依赖，便于主机端断言。
library;

/// 移动端中文环境的默认语言权重。
const String kAcceptLanguage = 'zh-CN,zh;q=0.9,en;q=0.8';

/// 生成与 [url] / [referer] 匹配的浏览器等效头。
///
/// [referer] 为空或不可解析时按 `none` 处理（等价于地址栏直接访问）；
/// 与目标 host 不同则给 `cross-site`，其余按 `same-origin`。
Map<String, String> browserMediaHeaders(String url, {String? referer}) {
  final target = Uri.tryParse(url);
  if (target == null || !target.hasAuthority) return const <String, String>{};
  return <String, String>{
    'Accept': '*/*',
    'Accept-Language': kAcceptLanguage,
    'Sec-Fetch-Dest': 'empty',
    'Sec-Fetch-Mode': 'cors',
    'Sec-Fetch-Site': _fetchSite(target, referer),
  };
}

String _fetchSite(Uri target, String? referer) {
  if (referer == null || referer.isEmpty) return 'none';
  final ref = Uri.tryParse(referer);
  if (ref == null || !ref.hasAuthority) return 'none';
  final sameScheme = ref.scheme.toLowerCase() == target.scheme.toLowerCase();
  final sameHost = ref.host.toLowerCase() == target.host.toLowerCase();
  // scheme 或 host 任一不同都算跨站：浏览器就是这么判的
  return sameScheme && sameHost ? 'same-origin' : 'cross-site';
}
