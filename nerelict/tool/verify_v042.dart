// 主机端行为测试：真实跑一遍「主播放列表选流 / Cookie 鉴权 /
// 字节区间分片 / 片段断点」，不依赖 Flutter 引擎 / 真机 / 公网。
//
//   dart run tool/verify_v042.dart
//
// 覆盖 0.4.2 三项改动：
//   1. 下载前选流：多档清晰度可按 key 选中、未知 key 回落、音轨独立成流时阻断；
//   2. Cookie 鉴权：需要登录态的分片带 Cookie 才能取到，取不到时不影响其它链路；
//   3. #EXT-X-BYTERANGE / #EXT-X-DISCONTINUITY：同文件多区间正确拼接、
//      区间长度不符时报错、断点被计数且不误算 DISCONTINUITY-SEQUENCE。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nerelict/models/download_task.dart';
import 'package:nerelict/services/app_paths.dart';
import 'package:nerelict/services/hls_downloader.dart';
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

/// 服务端观察到的请求，用来断言 Range / Cookie 真的发出去了
final List<({String path, String? range, String? cookie})> requests =
    <({String path, String? range, String? cookie})>[];

/// 250 字节确定性内容，按字节区间切片后应能拼回原样
final Uint8List mediaBin =
    Uint8List.fromList(List<int>.generate(250, (i) => i % 256));

/// 三档清晰度：最高档音轨独立成流（AUDIO 组带 URI），另两档音轨内嵌
const String master = '#EXTM3U\n'
    '#EXT-X-VERSION:4\n'
    '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="中文",LANGUAGE="zh",'
    'DEFAULT=YES,CHANNELS="2",URI="audio_only.m3u8"\n'
    '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="mux",NAME="内嵌",DEFAULT=YES\n'
    '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="sub",NAME="中文字幕",LANGUAGE="zh",'
    'URI="subs.m3u8"\n'
    '#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,'
    'CODECS="hvc1.1.6.L120",AUDIO="aud"\n'
    'v_hi.m3u8\n'
    '#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,'
    'CODECS="avc1.4d401f",AUDIO="mux"\n'
    'v_mid.m3u8\n'
    '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,'
    'CODECS="avc1.42e01e",AUDIO="mux",SUBTITLES="sub"\n'
    'v_low.m3u8\n';

String variantPlaylist(String tag) => '#EXTM3U\n'
    '#EXT-X-VERSION:3\n'
    '#EXT-X-TARGETDURATION:4\n'
    '#EXTINF:4,\n'
    '${tag}_0.ts\n'
    '#EXTINF:4,\n'
    '${tag}_1.ts\n'
    '#EXT-X-ENDLIST\n';

/// 同一文件按 100/100/50 切片，第二段省略 @offset 要求接续第一段
const String byteRangePlaylist = '#EXTM3U\n'
    '#EXT-X-VERSION:4\n'
    '#EXT-X-TARGETDURATION:4\n'
    '#EXTINF:4,\n'
    '#EXT-X-BYTERANGE:100@0\n'
    'media.bin\n'
    '#EXTINF:4,\n'
    '#EXT-X-BYTERANGE:100\n'
    'media.bin\n'
    '#EXTINF:4,\n'
    '#EXT-X-BYTERANGE:50@200\n'
    'media.bin\n'
    '#EXT-X-ENDLIST\n';

/// 带一处断点；DISCONTINUITY-SEQUENCE 不能算成断点
const String discontinuousPlaylist = '#EXTM3U\n'
    '#EXT-X-VERSION:3\n'
    '#EXT-X-TARGETDURATION:4\n'
    '#EXT-X-DISCONTINUITY-SEQUENCE:7\n'
    '#EXTINF:4,\n'
    'd0.ts\n'
    '#EXT-X-DISCONTINUITY\n'
    '#EXTINF:4,\n'
    'd1.ts\n'
    '#EXT-X-ENDLIST\n';

Future<void> handle(HttpRequest req) async {
  final path = req.uri.path;
  final range = req.headers.value(HttpHeaders.rangeHeader);
  final cookie = req.headers.value(HttpHeaders.cookieHeader);
  requests.add((path: path, range: range, cookie: cookie));
  final res = req.response;

  void playlist(String body) {
    res.headers.contentType =
        ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8');
    res.write(body);
  }

  if (path == '/master.m3u8') {
    playlist(master);
  } else if (path == '/v_hi.m3u8') {
    playlist(variantPlaylist('hi'));
  } else if (path == '/v_mid.m3u8') {
    playlist(variantPlaylist('mid'));
  } else if (path == '/v_low.m3u8') {
    playlist(variantPlaylist('low'));
  } else if (path == '/byrange.m3u8') {
    playlist(byteRangePlaylist);
  } else if (path == '/disc.m3u8') {
    playlist(discontinuousPlaylist);
  } else if (path == '/ignore-range.m3u8') {
    playlist('#EXTM3U\n'
        '#EXT-X-VERSION:4\n'
        '#EXT-X-TARGETDURATION:4\n'
        '#EXTINF:4,\n'
        '#EXT-X-BYTERANGE:100@0\n'
        'ignore-range.bin\n'
        '#EXT-X-ENDLIST\n');
  } else if (path == '/auth.m3u8') {
    // 只有带正确会话 Cookie 才给播放列表
    if (cookie != null && cookie.contains('sid=ok')) {
      playlist(variantPlaylist('auth'));
    } else {
      res.statusCode = HttpStatus.forbidden;
    }
  } else if (path == '/media.bin' || path == '/ignore-range.bin') {
    final start = _rangeStart(range);
    // ignore-range.bin 故意忽略 Range，用来验证下载器不会照单全收
    if (path == '/media.bin' && start != null) {
      final end = _rangeEnd(range) ?? (mediaBin.length - 1);
      res.statusCode = HttpStatus.partialContent;
      res.headers.set('Content-Range', 'bytes $start-$end/${mediaBin.length}');
      res.add(mediaBin.sublist(start, end + 1));
    } else {
      res.add(mediaBin);
    }
  } else {
    // 普通分片：首字节编码档位，便于断言实际选中了哪一档
    final m = RegExp(r'^/(hi|mid|low|auth|d)_?(\d)\.ts$').firstMatch(path);
    if (m != null) {
      final tier = m.group(1)!;
      final idx = int.tryParse(m.group(2) ?? '0') ?? 0;
      final seed = switch (tier) {
        'hi' => 100,
        'mid' => 200,
        'low' => 210,
        'auth' => 220,
        _ => 230,
      };
      res.add(Uint8List.fromList(<int>[seed + idx]));
    } else {
      res.statusCode = HttpStatus.notFound;
    }
  }
  await res.close();
}

int? _rangeStart(String? range) {
  if (range == null || !range.startsWith('bytes=')) return null;
  final v = range.substring(6).split('-').first;
  return int.tryParse(v);
}

int? _rangeEnd(String? range) {
  if (range == null || !range.startsWith('bytes=')) return null;
  final parts = range.substring(6).split('-');
  if (parts.length < 2) return null;
  return int.tryParse(parts[1]);
}

Future<void> main() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen(handle);
  final base = 'http://127.0.0.1:${server.port}';

  final root = await Directory.systemTemp.createTemp('nerelict_v042_');
  final outDir = Directory(joinPath(root.path, 'out'));
  final tmpDir = Directory(joinPath(root.path, 'tmp'));
  await outDir.create(recursive: true);
  await tmpDir.create(recursive: true);

  String? cookieFor(String url) =>
      url.contains('127.0.0.1') ? 'sid=ok; theme=dark' : null;

  final downloader = HlsDownloader(
    resolveOutputDir: () async => outDir,
    resolveTempDir: () async => tmpDir,
    resolveCookie: (url) async => cookieFor(url),
  );

  Future<Uint8List?> bytesOf(DownloadTask t) async {
    final p = t.filePath;
    if (p == null) return null;
    return File(p).readAsBytes();
  }

  try {
    stdout.writeln('=== 1. 主播放列表解析：码率 + 音轨/字幕组 ===');
    final parsed = parseMasterPlaylistFull(master, Uri.parse('$base/master.m3u8'));
    check(parsed.variants.length == 3, '解析出 3 档码率');
    check(parsed.variants.first.bandwidth == 5000000, '按带宽从高到低排序');
    check(parsed.renditions.length == 3, '解析出 3 条 #EXT-X-MEDIA 声明');
    check(parsed.renditions.where((r) => r.isAudio).length == 2, '识别出 2 个音轨组');
    check(parsed.renditions.where((r) => r.isSubtitle).length == 1, '识别出 1 个字幕组');

    final hi = parsed.variants.first;
    final mid = parsed.variants[1];
    check(hi.audioGroup == 'aud' && mid.audioGroup == 'mux', '变体上的 AUDIO 组被解析');
    check(hi.codecs != null && hi.codecs!.contains('hvc1'), 'CODECS 被解析');
    check(parsed.subtitlesFor(parsed.variants.last).isNotEmpty, '最低档关联到字幕组');

    stdout.writeln('=== 2. 独立音轨识别与选流 ===');
    check(parsed.separateAudioFor(hi).length == 1, '最高档被判定为音轨独立成流');
    check(parsed.separateAudioFor(mid).isEmpty, '内嵌音轨的档位不被误判');
    check(parsed.renditions.firstWhere((r) => r.isAudio).label.contains('中文'),
        '音轨标签包含语言与名称');

    check(parsed.pick('2000000@1280x720')?.resolution == '1280x720',
        '按保存的 key 精确恢复上次选择');
    check(parsed.pick('777@1280x720')?.resolution == '1280x720',
        '带宽变化时按同分辨率回落，不直接掉到最高档');
    check(parsed.pick(null)?.bandwidth == 5000000, '没有历史选择时默认最高码率');
    check(parsed.pick('123@999x999')?.bandwidth == 5000000,
        '完全对不上时回落最高码率');

    stdout.writeln('=== 3. 音轨独立成流时的处理（不再静默下出无声文件）===');
    // 默认落到最高档，而最高档音轨独立：自动退到第一个音轨内嵌的档位并说明，
    // 而不是让「点下载直接失败」变成新的坑
    final autoTask = DownloadTask(
      id: 'v042_auto_fallback',
      url: '$base/master.m3u8',
      title: 'auto-fallback',
    );
    await downloader.run(autoTask);
    check(autoTask.status == TaskStatus.done, '默认档位音轨独立时自动退到可用档位');
    check(autoTask.variantKey == '2000000@1280x720', '自动退到内嵌音轨的次高档');
    check(autoTask.variantNote != null && autoTask.variantNote!.contains('音轨独立'),
        '降级原因写明在任务上（${autoTask.variantNote}）');
    final autoBytes = await bytesOf(autoTask);
    check(autoBytes != null && autoBytes.first == 200, '自动回退后的产物来自实际所选档位');

    // 用户明确点了音轨独立的那一档：如实拒绝，不悄悄换成别的
    final explicit = DownloadTask(
      id: 'v042_explicit_blocked',
      url: '$base/master.m3u8',
      title: 'explicit',
    )..variantKey = '5000000@1920x1080';
    await downloader.run(explicit);
    check(explicit.status == TaskStatus.failed, '明确选中音轨独立的档位时失败而不是产出无声文件');
    check(explicit.error != null && explicit.error!.contains('音轨'),
        '失败原因明确指向音轨独立（${explicit.error}）');

    stdout.writeln('=== 4. 选中内嵌音轨的档位后正常下载 ===');
    final midTask = DownloadTask(
      id: 'v042_mid',
      url: '$base/master.m3u8',
      title: 'mid',
    )..variantKey = '2000000@1280x720';
    await downloader.run(midTask);
    check(midTask.status == TaskStatus.done, '指定档位后下载完成');
    check(midTask.variantKey == '2000000@1280x720', '任务记录了选中的档位 key');
    check(midTask.variant != null && midTask.variant!.contains('1280x720'),
        '任务记录了可读的档位名');
    final midBytes = await bytesOf(midTask);
    check(midBytes != null && midBytes.length == 2 && midBytes.first == 200,
        '产物来自所选档位的分片（不是最高档）');
    check(midTask.subtitleNote == null, '没有字幕组的档位不写字幕备注');

    final lowTask = DownloadTask(
      id: 'v042_low',
      url: '$base/master.m3u8',
      title: 'low',
    )..variantKey = '800000@640x360';
    await downloader.run(lowTask);
    final lowBytes = await bytesOf(lowTask);
    check(lowBytes != null && lowBytes.first == 210, '换一档后产物随之变化');
    check(lowTask.subtitleNote != null && lowTask.subtitleNote!.contains('中文'),
        '选中带字幕的档位时记录字幕备注');

    stdout.writeln('=== 5. Cookie 鉴权 ===');
    requests.clear();
    final noCookie = HlsDownloader(
      resolveOutputDir: () async => outDir,
      resolveTempDir: () async => tmpDir,
      resolveCookie: (url) async => null,
    );
    final denied = DownloadTask(
      id: 'v042_nocookie',
      url: '$base/auth.m3u8',
      title: 'nocookie',
    );
    await noCookie.run(denied);
    check(denied.status == TaskStatus.failed, '不带 Cookie 时鉴权失败（与服务端行为一致）');

    requests.clear();
    final authed = DownloadTask(
      id: 'v042_cookie',
      url: '$base/auth.m3u8',
      title: 'authed',
    );
    await downloader.run(authed);
    check(authed.status == TaskStatus.done, '带上 WebView 的 Cookie 后能取到分片');
    check(
        requests.any((r) =>
            r.path == '/auth.m3u8' && (r.cookie ?? '').contains('sid=ok')),
        '播放列表请求携带了 Cookie');
    check(
        requests.any((r) =>
            r.path == '/auth_0.ts' && (r.cookie ?? '').contains('sid=ok')),
        '分片请求同样携带 Cookie（不是只带在第一个请求上）');

    stdout.writeln('=== 6. Cookie 取不到时不影响其它链路 ===');
    final brokenCookie = HlsDownloader(
      resolveOutputDir: () async => outDir,
      resolveTempDir: () async => tmpDir,
      resolveCookie: (url) async => throw Exception('平台通道不可用'),
    );
    final robust = DownloadTask(
      id: 'v042_cookie_throw',
      url: '$base/v_low.m3u8',
      title: 'robust',
    );
    await brokenCookie.run(robust);
    check(robust.status == TaskStatus.done, '取 Cookie 抛异常时按匿名请求继续，下载不中断');

    stdout.writeln('=== 7. #EXT-X-BYTERANGE 分片 ===');
    final rangePlaylist = parseMediaPlaylist(
        byteRangePlaylist, Uri.parse('$base/byrange.m3u8'));
    check(rangePlaylist.segments.length == 3, '解析出 3 个区间分片');
    check(rangePlaylist.segments[0].rangeOffset == 0 &&
            rangePlaylist.segments[0].rangeLength == 100,
        '显式 @0 的区间被正确解析');
    check(rangePlaylist.segments[1].rangeOffset == 100,
        '省略 @offset 时接续同一 URI 的上一段');
    check(rangePlaylist.segments[2].rangeOffset == 200 &&
            rangePlaylist.segments[2].rangeLength == 50,
        '跨段跳转的 @200 被正确解析');

    requests.clear();
    final brTask = DownloadTask(
      id: 'v042_byterange',
      url: '$base/byrange.m3u8',
      title: 'byrange',
    );
    await downloader.run(brTask);
    check(brTask.status == TaskStatus.done, '区间分片下载完成');
    final brBytes = await bytesOf(brTask);
    check(brBytes != null && brBytes.length == 250,
        '三段区间拼回完整文件（共 250 字节）');
    check(
        brBytes != null &&
            listEquals(brBytes, mediaBin),
        '拼接结果与原始文件逐字节一致（同 URI 不同区间未互相覆盖）');
    check(
        requests.where((r) => r.path == '/media.bin').every((r) =>
            (r.range ?? '').startsWith('bytes=')),
        '每个区间分片都带 Range 请求');

    stdout.writeln('=== 8. 服务端忽略 Range 时报错 ===');
    final ignoreTask = DownloadTask(
      id: 'v042_ignore_range',
      url: '$base/ignore-range.m3u8',
      title: 'ignore-range',
    );
    await downloader.run(ignoreTask);
    check(ignoreTask.status == TaskStatus.failed,
        '服务端返回全量而不是声明区间时下载失败');
    check(
        ignoreTask.error != null && ignoreTask.error!.contains('字节区间'),
        '失败原因说明是字节区间不符（${ignoreTask.error}）');

    stdout.writeln('=== 9. #EXT-X-DISCONTINUITY ===');
    final discPlaylist = parseMediaPlaylist(
        discontinuousPlaylist, Uri.parse('$base/disc.m3u8'));
    check(discPlaylist.discontinuities == 1, '只统计 1 处断点');
    check(!discPlaylist.segments[0].discontinuityBefore, '第一段前没有断点');
    check(discPlaylist.segments[1].discontinuityBefore, '断点标记落在后一段上');
    check(discPlaylist.discontinuities != 2,
        'DISCONTINUITY-SEQUENCE 不会被误算成断点');

    final discTask = DownloadTask(
      id: 'v042_disc',
      url: '$base/disc.m3u8',
      title: 'disc',
    );
    await downloader.run(discTask);
    check(discTask.status == TaskStatus.done, '带断点的流仍可下载（不阻断）');
    check(discTask.discontinuities == 1, '断点数记到任务上供界面提示');
    check(jsonEncode(discTask.toJson()).contains('"discontinuities":1'),
        '断点数随任务持久化');

    stdout.writeln('=== 10. 选流结果持久化 ===');
    final restored = DownloadTask.fromJson(midTask.toJson());
    check(restored?.variantKey == '2000000@1280x720', '续传时能恢复选中的档位');
    check(restored?.subtitleNote == midTask.subtitleNote, '字幕备注同样被恢复');
    final discRestored = DownloadTask.fromJson(discTask.toJson());
    check(discRestored?.discontinuities == 1, '断点数能被恢复');
    final autoRestored = DownloadTask.fromJson(autoTask.toJson());
    check(autoRestored?.variantNote == autoTask.variantNote,
        '档位降级说明同样被持久化');
  } finally {
    await server.close(force: true);
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  }

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

bool listEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
