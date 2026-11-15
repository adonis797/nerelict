/// MP4 转换时间轴的算法回归测试（不依赖设备与 Flutter 引擎）。
///
/// 背景：`Mp4Converter.kt` 用 MediaMuxer 做 TS→MP4 转封装，而 MediaMuxer 只写
/// stts、不写 ctts，表达不了 B 帧「解码顺序 ≠ 显示顺序」。旧实现把回退的 PTS
/// 压成 `prev+1µs`，结果一半的帧显示时长为 0、剩下的帧间隔翻倍，播放就是卡顿。
///
/// 本脚本用真实 HLS TS 的 PTS 形态（I P B B …，90kHz 刻度）复刻两条时间轴算法，
/// 断言：旧算法确实会产出大量 0 时长帧（即问题真实存在），新算法产出的间隔均匀。
/// 这里镜像的是 `Mp4Converter.TrackClock` 的规则；改阈值时两边要一起改。
///
/// 用法：`dart run tool/verify_mp4_timeline.dart`
library;

import 'dart:io';

int passed = 0;
int failed = 0;

void check(bool ok, String name, [String? detail]) {
  if (ok) {
    passed++;
    stdout.writeln('  ✓ $name');
  } else {
    failed++;
    stdout.writeln('  ✗ $name${detail == null ? '' : ' — $detail'}');
  }
}

/// 模拟一条带 B 帧的 H.264 解码顺序 PTS（单位：90kHz 刻度）。
///
/// 真实形态是 I P B B / I P B B …：P 帧的 PTS 比同 GOP 的 B 帧大，
/// 所以解码顺序读出来会周期性回退约 1~2 帧。
List<int> bFramePts({int gops = 40, int start = 10000000}) {
  // 24fps，1 秒 24 帧；一个 GOP 四帧，展示顺序 = [I, B, B, P]
  const step = 41667; // 1e6 / 24，单位 µs
  final out = <int>[];
  var base = start;
  for (var g = 0; g < gops; g++) {
    final i = base;
    final p = base + step * 3;
    final b1 = base + step;
    final b2 = base + step * 2;
    // 解码顺序：I P B B
    out.addAll(<int>[i, p, b1, b2]);
    base += step * 4;
  }
  return out;
}

/// 单调流（无 B 帧）：解码顺序即显示顺序。
List<int> monoPts({int frames = 120, int start = 10000000}) {
  const step = 33367; // 1e6 / 29.97，单位 µs
  return List<int>.generate(frames, (i) => start + i * step);
}

/// 探测：帧间隔（排序后中位数）+ 是否重排。
({int frameDurUs, bool reordered}) analyze(List<int> pts) {
  final sorted = List<int>.of(pts)..sort();
  final deltas = <int>[];
  for (var i = 1; i < sorted.length; i++) {
    final d = sorted[i] - sorted[i - 1];
    if (d >= 500 && d <= 2000000) deltas.add(d);
  }
  deltas.sort();
  final frameDur = deltas.isEmpty ? 0 : deltas[deltas.length ~/ 2];
  final window = (frameDur > 0 ? frameDur : 33000) * 4;
  var lags = 0;
  for (var i = 1; i < pts.length; i++) {
    final d = pts[i] - pts[i - 1];
    if (d < 0 && -d <= window) lags++;
  }
  return (frameDurUs: frameDur, reordered: lags >= 2);
}

/// 旧实现：原始 PTS + 「回退压平到 prev+1µs」。
List<int> legacyTimeline(List<int> pts, int stepUs) {
  final base = pts.first;
  var shift = 0;
  int? prev;
  final out = <int>[];
  for (final raw in pts) {
    var value = raw - base + shift;
    if (prev != null && value <= prev) {
      final back = prev - value;
      if (back > 1000000) {
        shift += back + stepUs;
        value = prev + stepUs;
      } else {
        value = prev + 1;
      }
    }
    if (value < 0) value = 0;
    prev = value;
    out.add(value);
  }
  return out;
}

/// 新实现：解码序号 × 帧间隔（带大跳缺口补偿）。
List<int> gridTimeline(List<int> pts, int frameDurUs) {
  var count = 0;
  var gap = 0;
  int? lastRaw;
  final out = <int>[];
  for (final raw in pts) {
    if (lastRaw != null) {
      final jump = raw - lastRaw;
      if (jump > frameDurUs * 8) gap += jump - frameDurUs;
    }
    lastRaw = raw;
    out.add(gap + count * frameDurUs);
    count++;
  }
  return out;
}

/// MediaMuxer 默认时间刻度是毫秒：把 µs 时间轴按 ms 取整后再看间隔。
List<int> toMillis(List<int> us) =>
    us.map((v) => (v / 1000).round()).toList();

List<int> intervals(List<int> timeline) => <int>[
      for (var i = 1; i < timeline.length; i++) timeline[i] - timeline[i - 1],
    ];

void main() {
  stdout.writeln('=== 1. 真实形态的 B 帧流能被识别 ===');
  final pts = bFramePts();
  final probe = analyze(pts);
  check(probe.reordered, '解码顺序的 PTS 回退被判定为 B 帧重排');
  check(probe.frameDurUs >= 41000 && probe.frameDurUs <= 42000,
      '帧间隔取排序后中位数（24fps ≈ 41667µs）', '实测 ${probe.frameDurUs}µs');

  final mono = monoPts();
  final monoProbe = analyze(mono);
  check(!monoProbe.reordered, '单调流不会被误判成重排');
  check(monoProbe.frameDurUs >= 33300 && monoProbe.frameDurUs <= 33500,
      '29.97fps 实测帧间隔 ≈ 33.4ms', '实测 ${monoProbe.frameDurUs}µs');

  stdout.writeln('=== 2. 旧算法：回退压平会产出 0 时长帧 ===');
  final legacyMs = toMillis(legacyTimeline(pts, 33000));
  final legacyGaps = intervals(legacyMs);
  final zeroGaps = legacyGaps.where((d) => d == 0).length;
  final zeroRatio = zeroGaps / legacyGaps.length;
  check(zeroRatio > 0.3,
      '超过三成相邻帧的显示时长为 0（播放器直接丢掉）',
      '${(zeroRatio * 100).toStringAsFixed(1)}%');
  final fullGaps = legacyGaps.where((d) => d >= 60).length;
  check(fullGaps >= 35,
      '每个 GOP 都出现一次约 3 帧时长的定格（画面看起来就是卡住）',
      '$fullGaps/${legacyGaps.length} 帧间隔 ≥60ms');

  stdout.writeln('=== 3. 新算法：等间隔网格，帧间隔均匀 ===');
  final gridMs = toMillis(gridTimeline(pts, probe.frameDurUs));
  final gridGaps = intervals(gridMs);
  final minGap = gridGaps.reduce((a, b) => a < b ? a : b);
  final maxGap = gridGaps.reduce((a, b) => a > b ? a : b);
  check(minGap >= 40 && maxGap <= 45,
      '帧间隔集中在 41~42ms，没有 0 时长帧', '范围 $minGap~$maxGap ms');
  check(gridGaps.every((d) => d > 0), '时间轴严格递增');
  final expectMs = (pts.length - 1) * probe.frameDurUs / 1000;
  final actualMs = gridMs.last.toDouble();
  check((actualMs - expectMs).abs() < 5,
      '总时长与「帧数 × 帧间隔」一致',
      '期望 ${expectMs.round()}ms 实际 ${actualMs.round()}ms');

  stdout.writeln('=== 4. 缺段缺口不会被压缩 ===');
  // 第 40 帧后插入 2 秒缺口（模拟分片缺失 / 广告插播）
  final withGap = <int>[...pts.take(40), ...pts.skip(40).map((v) => v + 2000000)];
  final gapGrid = gridTimeline(withGap, probe.frameDurUs);
  final gapIntervals = intervals(gapGrid);
  final bigJumps = gapIntervals.where((d) => d > 1900000).length;
  check(bigJumps == 1, '缺口原样保留在时间轴上，避免与音频错位',
      '检测到 $bigJumps 处大跳');
  check(gapGrid.last > gridTimeline(pts, probe.frameDurUs).last + 1900000,
      '保留缺口后总时长相应变长');

  stdout.writeln('=== 5. 单调流仍走原始时间轴 ===');
  final monoLegacy = toMillis(legacyTimeline(mono, 33000));
  final monoGaps = intervals(monoLegacy);
  check(monoGaps.every((d) => d >= 33 && d <= 34),
      '无 B 帧的流不做网格重建，保留原始时间轴');
  final monoSourceMs = (mono.last - mono.first) / 1000;
  check((monoLegacy.last - monoSourceMs).abs() < 1,
      '单调流的时间轴与源一致',
      '源 ${monoSourceMs.round()}ms 产物 ${monoLegacy.last}ms');

  stdout.writeln();
  if (failed == 0) {
    stdout.writeln('全部 $passed 项通过');
  } else {
    stdout.writeln('通过 $passed 项，失败 $failed 项');
    exitCode = 1;
  }
}
