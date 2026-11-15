// 广告识别与列表排序的行为测试：不依赖 Flutter 引擎 / 真机 / 网络。
//
//   dart run tool/verify_ad_filter.dart
//
// 覆盖：
//   1. 高置信（广告网络域名）与中置信（独占路径段）判定；
//   2. 误伤防护：download / shadow / adapter / audio 这类合法命名不判广告；
//   3. 聚合层把广告标记挂到资源项上，且归因与广告标记互不影响；
//   4. 展示排序：真实条目在前、疑似广告沉底，组内顺序不变。
import 'dart:io';

import 'package:nerelict/models/sniffed_media.dart';
import 'package:nerelict/services/ad_filter.dart';
import 'package:nerelict/services/resource_aggregator.dart';

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

void main() {
  stdout.writeln('=== 1. 广告域名（高置信）===');
  for (final host in <String>[
    'https://securepubads.g.doubleclick.net/gampad/ads?iu=/1/video',
    'https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js',
    'https://s.adsystem.com/x/video.mp4',
    'https://cdn.exoclick.com/vast.xml',
    'https://a.trafficjunky.net/ads/video.mp4',
  ]) {
    final verdict = AdFilter.inspect(host);
    check(verdict.isAd && verdict.highConfidence, host.split('/')[2]);
  }
  check(
      AdFilter.inspect('https://doubleclick.net.evil.example/v.mp4').isAd ==
          false,
      '后缀匹配不跨越主机边界（doubleclick.net.evil 不算）');

  stdout.writeln('=== 2. 路径段（中置信）===');
  final pathAds = <String>[
    'https://cdn.example.com/ads/preroll.mp4',
    'https://cdn.example.com/ad/300x250.mp4',
    'https://cdn.example.com/v/203/preroll_720.m3u8',
    'https://cdn.example.com/tag/vast3/master.m3u8',
    'https://cdn.example.com/x/adserver-01/index.m3u8',
  ];
  for (final url in pathAds) {
    final verdict = AdFilter.inspect(url);
    check(verdict.isAd && !verdict.highConfidence, url.split('/').last);
  }
  check(
      AdFilter.inspect('https://cdn.example.com/play?type=vast').isAd,
      'VAST 查询参数判广告');

  stdout.writeln('=== 3. 误伤防护 ===');
  final clean = <String>[
    'https://cdn.example.com/v/download.mp4',
    'https://cdn.example.com/v/shadow.mp4',
    'https://cdn.example.com/v/adapter/index.m3u8',
    'https://cdn.example.com/v/audio.m3u8',
    'https://cdn.example.com/v/road/1.ts',
    'https://cdn.example.com/v/advertise/index.m3u8',
    'https://cdn.example.com/loading/seg-1.ts',
    'blob:https://example.com/9f2c-1',
    'data:video/mp4;base64,AAAA',
    'not a url',
  ];
  for (final url in clean) {
    check(!AdFilter.isAdUrl(url), '不判广告：$url');
  }

  stdout.writeln('=== 4. 聚合与排序 ===');
  final agg = ResourceAggregator();
  final real = agg.accept(
    url: 'https://cdn.example.com/v/203/index.m3u8',
    kind: 'playlist',
    page: 'https://site.example/watch/203',
    source: 'perf',
    title: '第 203 集',
  ).item!;
  check(!real.suspectAd, '真实视频不标广告');

  final ad = agg.accept(
    url: 'https://ads.example.com/preroll/30s.mp4',
    kind: 'playlist',
    page: 'https://site.example/watch/203',
    source: 'perf',
    title: '第 203 集',
  ).item!;
  check(ad.suspectAd, '广告位被标记');
  check(ad.adReason.contains('路径段'), '标记带判定依据');

  // 广告也可能被点击捕获命中：两个标记互不覆盖
  final adHit = agg.accept(
    url: 'https://ads.example.com/preroll/30s.mp4',
    kind: 'playlist',
    page: 'https://site.example/watch/203',
    source: '点击/play',
    title: '第 203 集',
    attribution: const ClickAttribution(sessionId: 7, overlayScore: 90),
  ).item!;
  check(adHit.clickCaptured && adHit.overlayPlay, '广告也能有归因与浮层标记');
  check(adHit.suspectAd, '归因不会清掉广告标记');

  real.markSuspectAd('测试用');
  final ordered = orderForDisplay(agg.items);
  check(ordered.length == agg.items.length, '排序不丢条目');
  check(ordered.last.canonicalKey == real.canonicalKey,
      '疑似广告沉底（这里把真实项也标广告，它应落到最后）');
  real.suspectAd = false;
  final ordered2 = orderForDisplay(agg.items);
  check(identical(ordered2.first, real), '真实条目排在广告前');

  // 顺序稳定：多个真实条目保持传入先后
  final agg2 = ResourceAggregator();
  final a = agg2.accept(
    url: 'https://cdn.example.com/a/index.m3u8',
    kind: 'playlist',
    page: 'p',
    source: 'perf',
    title: 'a',
  ).item!;
  final b = agg2.accept(
    url: 'https://cdn.example.com/b/index.m3u8',
    kind: 'playlist',
    page: 'p',
    source: 'perf',
    title: 'b',
  ).item!;
  final ordered3 = orderForDisplay(agg2.items);
  check(ordered3.indexOf(b) < ordered3.indexOf(a),
      '组内保持「新的在前」的原有顺序');

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
