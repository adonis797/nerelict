// 0.4.4 请求头透传的行为测试：白名单、清洗、令牌、序列化、链路接线。
//
//   dart run tool/verify_v044.dart
//
// 覆盖：
//   1. HeaderPolicy 只放行 Authorization / X-* / Origin；
//   2. 清洗：超长、换行、空值、同名去重、数量上限；
//   3. 代理令牌由地址派生、稳定、不暴露头的值；
//   4. SniffedMedia 合并头：后到覆盖先到，重复合并不触发刷新；
//   5. DownloadTask 序列化：头随任务落盘，脏数据回读时被过滤；
//   6. 嗅探脚本真的 hook 了 setRequestHeader，且分片组/切码率/下载都接线。
import 'dart:io';

import 'package:nerelict/models/download_task.dart';
import 'package:nerelict/models/player_request.dart';
import 'package:nerelict/models/sniffed_media.dart';
import 'package:nerelict/services/header_policy.dart';

int passed = 0;
final List<String> failures = <String>[];

void check(bool ok, String label) {
  if (ok) {
    passed++;
    stdout.writeln('  ✓ $label');
  } else {
    failures.add(label);
    stdout.writeln('  ✗ $label');
  }
}

String read(String path) => File(path).readAsStringSync();

void main() {
  stdout.writeln('=== 1. 白名单 ===');
  check(HeaderPolicy.allows('Authorization'), '放行 Authorization');
  check(HeaderPolicy.allows('authorization'), '头名大小写不敏感');
  check(HeaderPolicy.allows('X-Token'), '放行 X- 自定义头');
  check(HeaderPolicy.allows('X-Playback-Session-Id'), '放行带连字符的 X- 头');
  check(HeaderPolicy.allows('Origin'), '放行 Origin');
  check(!HeaderPolicy.allows('Cookie'), '拒绝 Cookie（由 CookieStore 实时取）');
  check(!HeaderPolicy.allows('Range'), '拒绝 Range（分片区间由链路算）');
  check(!HeaderPolicy.allows('Referer'), '拒绝 Referer（已有独立字段）');
  check(!HeaderPolicy.allows('User-Agent'), '拒绝 User-Agent（统一 UA）');
  check(!HeaderPolicy.allows('Host'), '拒绝 Host');
  check(!HeaderPolicy.allows('Content-Length'), '拒绝 Content-Length');
  check(!HeaderPolicy.allows('Accept-Encoding'), '拒绝 Accept-Encoding');
  check(!HeaderPolicy.allows('Sec-Fetch-Site'), '拒绝 Sec-*');
  check(!HeaderPolicy.allows(''), '拒绝空名');
  check(!HeaderPolicy.allows('X'), '拒绝过短的无意义名');

  stdout.writeln();
  stdout.writeln('=== 2. 清洗 ===');
  final clean = HeaderPolicy.sanitize(<String, String>{
    'Authorization': '  Bearer abc  ',
    'X-Token': 'tok',
    'Cookie': 'sid=1',
    'X-Empty': '   ',
    'X-Multiline': 'a\r\nInjected: 1',
    'X-Long': 'x' * 2000,
  });
  check(clean['Authorization'] == 'Bearer abc', '值会去掉首尾空白');
  check(!clean.containsKey('Cookie'), '非白名单头被剔除');
  check(!clean.containsKey('X-Empty'), '空值被剔除');
  check(!clean.containsKey('X-Multiline'), '带换行的值被剔除（防头注入）');
  check(!clean.containsKey('X-Long'), '超长值被剔除');
  check(clean.length == 2, '只剩下真正可用的两个头');

  final overwrite = HeaderPolicy.sanitize(<String, String>{
    'authorization': 'old',
    'Authorization': 'new',
  });
  check(overwrite.length == 1, '同名头（不同大小写）只保留一条');
  check(overwrite.values.single == 'new', '同名头取后到的值（token 刷新）');

  final many = <String, String>{
    for (var i = 0; i < 20; i++) 'X-H$i': '$i',
  };
  check(HeaderPolicy.sanitize(many).length == HeaderPolicy.kMaxHeaders,
      '头数量被截到上限 ${HeaderPolicy.kMaxHeaders}');

  final merged = HeaderPolicy.merge(
    <String, String>{'X-A': '1', 'X-B': '2'},
    <String, String>{'X-B': '3', 'Cookie': 'no'},
  );
  check(merged['X-A'] == '1', '合并保留只存在于旧批次的头');
  check(merged['X-B'] == '3', '合并时新值覆盖旧值');
  check(!merged.containsKey('Cookie'), '合并仍然过白名单');

  stdout.writeln();
  stdout.writeln('=== 3. 代理令牌 ===');
  const url = 'https://cdn.example.com/a/index.m3u8?token=1';
  final t1 = HeaderPolicy.tokenFor(url);
  final t2 = HeaderPolicy.tokenFor(url);
  check(t1 == t2, '同一地址的令牌稳定');
  check(t1.length == 12, '令牌固定 12 位');
  check(!t1.contains('token'), '令牌里不含地址原文');
  check(t1 != HeaderPolicy.tokenFor('https://cdn.example.com/a/other.m3u8'),
      '不同地址令牌不同');
  check(RegExp(r'^[0-9a-f]+$').hasMatch(t1), '令牌是十六进制摘要');

  stdout.writeln();
  stdout.writeln('=== 4. 资源项合并头 ===');
  final media = SniffedMedia(
    url: url,
    pageUrl: 'https://site.com/watch',
    source: 'perf',
  );
  check(media.requestHeaders.isEmpty, '新建资源项默认没有头');
  check(media.mergeHeaders(<String, String>{'Authorization': 'Bearer a'}),
      '首次合并返回 true');
  check(media.requestHeaders['Authorization'] == 'Bearer a', '头被记住');
  check(!media.mergeHeaders(<String, String>{'Authorization': 'Bearer a'}),
      '同样的头重复合并不触发刷新');
  check(media.mergeHeaders(<String, String>{'Authorization': 'Bearer b'}),
      'token 刷新时返回 true');
  check(media.requestHeaders['Authorization'] == 'Bearer b', '取新值');
  check(!media.mergeHeaders(<String, String>{'Cookie': 'sid=1'}),
      '全是非法头时不算变化');
  check(!media.requestHeaders.containsKey('Cookie'), '非法头没有进模型');
  check(!media.mergeHeaders(null), 'null 合并安全');

  stdout.writeln();
  stdout.writeln('=== 5. 下载任务序列化 ===');
  final task = DownloadTask(
    id: 't1',
    url: url,
    title: 'v',
  )..requestHeaders = HeaderPolicy.sanitize(<String, String>{
      'Authorization': 'Bearer x',
      'X-Token': 'y',
    });
  final json = task.toJson();
  check(json['headers'] is Map, '头随任务写入 JSON');
  final restored = DownloadTask.fromJson(json);
  check(restored != null, '任务能从 JSON 恢复');
  check(restored!.requestHeaders['Authorization'] == 'Bearer x',
      '恢复后 Authorization 仍在');
  check(restored.requestHeaders['X-Token'] == 'y', '恢复后自定义头仍在');

  final emptyTask = DownloadTask(id: 't2', url: url, title: 'v');
  check(!emptyTask.toJson().containsKey('headers'), '没有头时不写空字段');

  final dirty = DownloadTask.fromJson(<String, dynamic>{
    'id': 't3',
    'url': url,
    'title': 'v',
    'headers': <dynamic, dynamic>{
      'Authorization': 'Bearer ok',
      'Cookie': 'sid=1',
      'X-Bad': 'a\nb',
      42: 'ignore',
    },
  });
  check(dirty != null && dirty.requestHeaders['Authorization'] == 'Bearer ok',
      '回读时保留合法头');
  check(dirty != null && !dirty.requestHeaders.containsKey('Cookie'),
      '回读时过滤 Cookie（磁盘内容不可信）');
  check(dirty != null && !dirty.requestHeaders.containsKey('X-Bad'),
      '回读时过滤带换行的值');

  stdout.writeln();
  stdout.writeln('=== 6. 链路接线 ===');
  check(PlayerRequest(url: url).headers.isEmpty, '播放请求默认不带头');
  final req = PlayerRequest(url: url, headers: media.requestHeaders);
  check(req.headers['Authorization'] == 'Bearer b', '播放请求能携带头');

  final sniffer = read('lib/services/sniffer_js.dart');
  check(sniffer.contains('setRequestHeader'), '嗅探脚本 hook 了 setRequestHeader');
  check(sniffer.contains('XMLHttpRequest.prototype.send'), '在 send 时上报攒到的头');
  check(sniffer.contains('headersToList(init && init.headers'), 'fetch 读 init.headers');
  check(sniffer.contains('authorization|x-'), '脚本侧也有一份白名单');
  check(sniffer.contains('scanBody(t, \'body\', hs)'), '响应体抓到的地址带头');

  final proxy = read('lib/services/streaming_proxy.dart');
  check(proxy.contains('_registerHeaders'), '代理登记鉴权头');
  check(proxy.contains(r"'&h=$h'"), '代理 URL 只带令牌，不带头的值');
  check(proxy.contains('_headersByToken'), '头存在内存表里');
  check(proxy.contains('playbackUrlForSegments'), '分片组播放可用');
  check(proxy.contains('h: headerToken'), '分片沿用同一个令牌');

  final player = read('lib/ui/player_page.dart');
  check(player.contains('headers: widget.request.headers'),
      '播放页把请求头交给 MediaSource');
  check(player.contains('headers: widget.request.headers,'), '切码率时保留请求头');
  check(player.contains('headers: headers,'), '下载时把请求头交给任务');

  final browser = read('lib/ui/browser_tab.dart');
  check(browser.contains('headers: media.requestHeaders'),
      '列表起播 / 分片组 / 下载都带上了头');

  final downloader = read('lib/services/hls_downloader.dart');
  check(downloader.contains('_headersFor(url, referer, task.requestHeaders)'),
      '下载器的 m3u8 / 分片请求带头');
  check(downloader.contains('task.requestHeaders'), '直链请求也带头');

  final state = read('lib/state/app_state.dart');
  check(state.contains('_readHeaders(data[\'headers\'])'), '嗅探消息解析请求头');
  check(state.contains('HeaderPolicy.sanitize(headers)'), '入队时二次过滤');

  // 日志只记数量，不记头的值：Authorization 是敏感凭据
  final logLines = <String>[];
  for (final src in <String>[proxy, state, downloader]) {
    for (final line in src.split('\n')) {
      final t = line.trim();
      if (t.contains('logD(') && t.toLowerCase().contains('header')) {
        logLines.add(t);
      }
    }
  }
  check(logLines.isNotEmpty, '存在与请求头相关的日志');
  check(logLines.every((l) => l.contains('.length') || l.contains('auth headers')),
      '日志只记头的数量，不记头的值');

  stdout.writeln();
  stdout.writeln('=== 7. 403 诊断与 UA ===');
  check(downloader.contains('_lastRequestUrl'), '记录最近一次被拒的请求地址');
  check(downloader.contains('_lastRequestPath'), '错误提示能说出是哪一步被拒');
  check(downloader.contains("'Cookie 已带'") &&
          downloader.contains("'Cookie 未取到'"),
      '403 时明确是否带上了 Cookie');
  check(downloader.contains('_responseSnippet'), '403 时附上服务端原文');
  check(downloader.contains('服务器返回 \$code\$at'), '错误提示带上路径');

  final ms = read('lib/services/media_source.dart');
  final uaFile = read('lib/services/user_agent.dart');
  check(uaFile.contains('class UserAgent'), 'UA 抽成纯 Dart 模块（下载器可主机端测试）');
  check(uaFile.contains('static void adopt'), '能采纳 WebView 的真实 UA');
  check(uaFile.contains('kFallback'), '保留一份不含品牌 token 的兜底 UA');
  check(!uaFile.contains('M8Browser') && !ms.contains('M8Browser'),
      'UA 里不再有旧品牌 token');
  check(ms.contains('static String get userAgent'), '媒体层转发当前 UA');
  check(downloader.contains('UserAgent.current'), '下载器每次请求读当前 UA');
  check(downloader.contains('UserAgent.kFallback'), '下载器兜底 UA 与媒体层同源');
  check(!downloader.contains("import 'media_source.dart'"),
      '下载器不再依赖 Flutter 侧的媒体层');
  final browserUa = read('lib/ui/browser_tab.dart');
  check(browserUa.contains('_adoptWebViewUserAgent') &&
          browserUa.contains('getUserAgent') &&
          browserUa.contains('UserAgent.adopt'),
      'WebView 建好后把真实 UA 交给下载器与代理');

  final sp2 = read('lib/services/streaming_proxy.dart');
  check(sp2.contains('lastUpstreamError'), '代理记录最近一次被拒的回源');
  check(sp2.contains('_cacheWorthy'), '写缓存前校验响应是否可用');
  check(sp2.contains('"text/html"') || sp2.contains("'text/html'"),
      'HTML 防盗页不落缓存');
  check(sp2.contains('cacheFile.delete()'), '0 字节坏缓存会被清掉重取');
  check(read('lib/ui/player_page.dart').contains('lastUpstreamError'),
      '播放失败时附上代理回源状态');

  stdout.writeln();
  stdout.writeln('=== 8. Cloudflare 人机验证 ===');
  check(downloader.contains('_isBotChallenge'), '能识别人机验证拦截');
  check(downloader.contains("'cf-mitigated'"), '识别 Cloudflare 的响应标记');
  check(downloader.contains('Attention Required') &&
          downloader.contains('Just a moment'),
      '识别挑战页正文');
  check(downloader.contains('被站点的 Cloudflare 人机验证拦下'),
      '拦截时给专门的提示，不再误导成「没登录」');
  check(downloader.contains('invalidateCookie'), '403 时让 Cookie 缓存失效');
  check(downloader.contains('_onRequestRejected'), '重试前先失效缓存再回源');
  check(state.contains('invalidateCookie:'), '入口把失效动作接到 CookieStore');
  check(downloader.contains(r'<(script|style)[^>]*>'),
      '服务端原文会去掉 style/script，不把 CSS 噪声塞给用户');

  stdout.writeln();
  if (failures.isEmpty) {
    stdout.writeln('全部通过：$passed 项');
  } else {
    stdout.writeln('通过 $passed 项，失败 ${failures.length} 项：');
    for (final f in failures) {
      stdout.writeln('  - $f');
    }
    exitCode = 1;
  }
}
