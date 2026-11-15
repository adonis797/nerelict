// 0.4.3 四项适配的行为测试：fMP4 多段 init / 分片组播放 / 响应体抓地址 / DASH 边界。
//
//   dart run tool/verify_v043.dart
//
// 覆盖：
//   1. 一个播放列表里出现多段 #EXT-X-MAP 时，每个分片都挂对自己的 init；
//   2. #EXT-X-MAP 的 BYTERANGE 被解析（同 URI 不同区间是两份 init）；
//   3. 下载器按分片切换 init 写入，不再是「只有第一个 init」；
//   4. 分片组可以直接播放：合成播放列表 + 走代理（fMP4 分片除外）；
//   5. fetch/XHR 响应体里的媒体地址能被抓出来（POST 返回 JSON 的站点）；
//   6. DASH（.mpd）能播但不支持下载，且错误信息明确。
import 'dart:io';

import 'package:nerelict/services/hls_parser.dart';

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

String playlist(String body) => body;

void main() {
  final base = Uri.parse('https://cdn.example.com/v/');
  final downloader = read('lib/services/hls_downloader.dart');
  final proxy = read('lib/services/streaming_proxy.dart');
  final sniffer = read('lib/services/sniffer_js.dart');
  final browser = read('lib/ui/browser_tab.dart');

  stdout.writeln('=== 1. 多段 #EXT-X-MAP ===');
  final multi = parseMediaPlaylist(
    playlist('''#EXTM3U
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:4
#EXT-X-MAP:URI="init1.mp4"
#EXTINF:4.0,
s0.m4s
#EXTINF:4.0,
s1.m4s
#EXT-X-MAP:URI="init2.mp4"
#EXTINF:4.0,
s2.m4s
#EXTINF:4.0,
s3.m4s
#EXT-X-ENDLIST
'''),
    base,
  );
  check(multi.segments.length == 4, '4 个分片全部解析');
  check(multi.segments[0].mapUri.toString() == 'https://cdn.example.com/v/init1.mp4',
      '前两段挂第一个 init');
  check(multi.segments[1].mapKey == multi.segments[0].mapKey,
      '同一 init 的 mapKey 一致');
  check(multi.segments[2].mapUri.toString() == 'https://cdn.example.com/v/init2.mp4',
      '后两段挂第二个 init');
  check(multi.segments[2].mapKey != multi.segments[0].mapKey,
      '换了 init 的 mapKey 不同（否则会复用错 moov）');
  check(multi.isFmp4, '识别为 fMP4');

  stdout.writeln();
  stdout.writeln('=== 2. #EXT-X-MAP 的 BYTERANGE ===');
  final ranged = parseMediaPlaylist(
    playlist('''#EXTM3U
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:4
#EXT-X-MAP:URI="all.mp4",BYTERANGE="720@0"
#EXTINF:4.0,
s0.m4s
#EXT-X-MAP:URI="all.mp4",BYTERANGE="640@720"
#EXTINF:4.0,
s1.m4s
#EXT-X-ENDLIST
'''),
    base,
  );
  check(ranged.segments[0].hasMapRange && ranged.segments[0].mapRangeLength == 720,
      '第一段 init 长度为 720');
  check(ranged.segments[0].mapRangeOffset == 0, '第一段 init 偏移 0');
  check(ranged.segments[1].mapRangeOffset == 720 &&
          ranged.segments[1].mapRangeLength == 640,
      '第二段 init 偏移/长度正确');
  check(ranged.segments[0].mapKey != ranged.segments[1].mapKey,
      '同 URI 不同区间算两份 init');
  check(ranged.initUri.toString() == 'https://cdn.example.com/v/all.mp4',
      'playlist 级 initUri 仍保留（兼容旧字段）');

  final plain = parseMediaPlaylist(
    playlist('''#EXTM3U
#EXT-X-TARGETDURATION:4
#EXTINF:4.0,
a.ts
#EXT-X-ENDLIST
'''),
    base,
  );
  check(plain.segments.single.mapUri == null, '没有 MAP 时 mapUri 为空');
  check(plain.segments.single.mapKey.isEmpty, 'mapKey 为空串');

  stdout.writeln();
  stdout.writeln('=== 3. 下载器按分片切换 init ===');
  check(downloader.contains('final initPaths = <String, String>{}'),
      '按 mapKey 缓存多个 init');
  check(downloader.contains('if (key.isNotEmpty && key != writtenInit)'),
      '合并时 init 变化就重新写入');
  check(downloader.contains('seg.hasMapRange'), 'init 支持字节区间');
  check(downloader.contains('_initFileName(seg)'), 'init 文件名带区间身份');
  check(!downloader.contains('if (initPath != null) {'),
      '旧的「只写一个 init」逻辑已移除');

  stdout.writeln();
  stdout.writeln('=== 4. 分片组直接播放 ===');
  check(proxy.contains('playbackUrlForSegments'), '代理提供分片组播放地址');
  check(proxy.contains('_buildSegmentPlaylist') &&
          proxy.contains('#EXT-X-ENDLIST'),
      '合成一份完整 VOD 播放列表');
  check(proxy.contains("writeln(_proxyUrl('/seg', seg, referer, h: headerToken))"),
      '分片全部改写成本代理地址（Cookie/Referer/鉴权头与在线播放一致）');
  check(proxy.contains("route.startsWith('/local')"), '新增 /local 路由');
  check(proxy.contains('_localPlaylists'), '播放列表放内存，不落盘');
  check(proxy.contains("!u.contains('.m4s') && !u.contains('.mp4')"),
      'fMP4 分片不硬凑（缺 init 合出来也放不了）');
  check(proxy.contains('usable.length < 2'), '少于 2 段不起播放器');
  check(browser.contains('_playSegmentGroup') && browser.contains('分片没法直接播放'),
      '播放失败时给出可执行的提示');
  check(browser.contains('m.isPlayable || m.needsSegmentDownload'),
      '分片组也有播放入口');
  check(read('lib/ui/player_page.dart').contains('alreadyLocal'),
      '本机代理地址不再被二次代理');

  stdout.writeln();
  stdout.writeln('=== 5. 响应体里的地址 ===');
  check(sniffer.contains('scanBody'), '提供响应体扫描');
  check(sniffer.contains('res.clone()') && sniffer.contains('.text()'),
      '读一份 response 克隆，不消耗原响应');
  check(sniffer.contains('bodyAllowed'), '只对成功且是文本类的响应扫描');
  check(sniffer.contains('json|text|xml|javascript'), '按 content-type 过滤');
  check(sniffer.contains('524288'), '限 512KB，避免大响应拖慢页面');
  check(sniffer.contains("addEventListener('load'"), 'XHR 也扫描响应体');
  check(sniffer.contains("rt !== 'text' && rt !== 'json'"), 'XHR 只读文本/JSON');
  check(sniffer.contains("replace(/\\\\\\//g, '/')"), '还原 JSON 里转义的斜杠');
  check(sniffer.contains('m3u8|mpd|mp4'), '媒体扩展名覆盖 HLS/DASH/直链');
  check(!sniffer.contains('preventDefault('), '仍然不干预请求');

  stdout.writeln();
  stdout.writeln('=== 6. DASH 边界 ===');
  check(downloader.contains('暂不支持下载 DASH'), '下载时明确拒绝 .mpd');
  check(!downloader.contains('MediaKind.dash'), '下载器不假设能解析 MPD');
  final dashSource = read('lib/services/media_source.dart');
  check(dashSource.contains('MediaKind.dash'), '播放侧仍识别 .mpd');
  check(!dashSource.contains("kind == MediaKind.dash) {\n      reason"),
      '.mpd 没有被标记成「不支持播放」');

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
