// 文件页的数据层：类型分组 + 媒体元数据。不依赖 Flutter，可直接
// `dart run tool/verify_media_meta.dart`。
//
// 锁三件事：
// 1. 分类宫格覆盖全部类型且不重不漏（新增类型忘了进宫格，用户就永远看不到它）；
// 2. `.m3u8` 被认成清单而不是普通视频（否则会去读时长，显示一列空白）；
// 3. 元信息的拼装与缓存序列化稳定——这两处错了，列表整行就都是错的。
import 'dart:io';

import 'package:nerelict/services/file_kinds.dart';
import 'package:nerelict/services/media_meta.dart';

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
  stdout.writeln('=== 1. 分类宫格 ===');
  check(kGridKinds.length == LocalFileKind.values.length,
      '宫格覆盖全部 ${LocalFileKind.values.length} 个类型');
  check(kGridKinds.toSet().length == kGridKinds.length, '宫格里没有重复类型');
  for (final kind in LocalFileKind.values) {
    check(kGridKinds.contains(kind), '宫格包含「${kind.label}」');
  }
  check(kGridKinds.first == LocalFileKind.video, '视频排在第一位');

  stdout.writeln('=== 2. 扩展名归类 ===');
  check(kindOfName('a.mp4') == LocalFileKind.video, 'mp4 归视频');
  check(kindOfName('a.m3u8') == LocalFileKind.video, 'm3u8 归视频（可播放）');
  check(kindOfName('a.ts') == LocalFileKind.video, 'ts 归视频');
  check(kindOfName('a.apk') == LocalFileKind.apk, 'apk 独立成「安装包」');
  check(kindOfName('a.XAPK') == LocalFileKind.apk, 'xapk 也归安装包（大小写无关）');
  check(kindOfName('a.epub') == LocalFileKind.ebook, 'epub 归电子书');
  check(kindOfName('a.azw3') == LocalFileKind.ebook, 'azw3 归电子书');
  check(kindOfName('a.zip') == LocalFileKind.archive, 'zip 归压缩包');
  check(kindOfName('a.unknown') == LocalFileKind.other, '未知扩展名归其他');
  check(kindOfName('noext') == LocalFileKind.other, '无扩展名归其他');

  stdout.writeln('=== 3. 清单识别 ===');
  check(isPlaylistName('index.m3u8'), 'm3u8 认作清单');
  check(isPlaylistName('manifest.MPD'), 'mpd 认作清单');
  check(!isPlaylistName('movie.mp4'), 'mp4 不是清单');

  stdout.writeln('=== 4. 清单解析 ===');
  const media = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXT-X-KEY:METHOD=AES-128,URI="key.bin"
#EXTINF:6.000,
seg0.ts
#EXTINF:6.000,
seg1.ts
#EXTINF:6.000,
seg2.ts
#EXT-X-ENDLIST
''';
  final m = parsePlaylistText(media);
  check(m.valid, '普通清单判为有效');
  check(m.segments == 3, '数出 3 个分片');
  check(m.encrypted, '识别出 AES-128 加密');
  check(!m.isMaster, '不是 master');
  check(m.targetDuration == const Duration(seconds: 6), '读到目标时长 6 秒');
  check(m.uris.length == 3 && m.uris.first == 'seg0.ts', '保留分片地址');

  const master = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
v/360/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
v/720/index.m3u8
''';
  final masterSummary = parsePlaylistText(master);
  check(masterSummary.isMaster, '识别出 master 清单');
  check(masterSummary.segments == 2, 'master 里数出 2 个子清单');

  const plainKey = '''
#EXTM3U
#EXT-X-KEY:METHOD=NONE
#EXTINF:6,
seg0.ts
''';
  check(!parsePlaylistText(plainKey).encrypted, 'METHOD=NONE 不算加密');

  final broken = parsePlaylistText('<html>403 forbidden</html>');
  check(!broken.valid, 'HTML 内容判为无效清单');

  stdout.writeln('=== 5. 文案格式 ===');
  check(formatDuration(const Duration(seconds: 724)) == '12:04', '724 秒 → 12:04');
  check(formatDuration(const Duration(seconds: 3723)) == '1:02:03',
      '超一小时带小时位');
  check(formatDuration(Duration.zero).isEmpty, '零时长返回空串（不显示 00:00）');
  check(resolutionLabel(3840, 2160) == '4K', '2160 是 4K');
  check(resolutionLabel(1920, 1080) == '1080p', '1080 是 1080p');
  check(resolutionLabel(1280, 720) == '720p', '720 是 720p');
  check(resolutionLabel(640, 400) == '640×400', '非标准档位写宽×高');
  check(resolutionLabel(720, 1280) == '720p', '竖屏按短边报档位');
  check(resolutionLabel(1080, 1920) == '1080p', '竖屏 1080 同样是 1080p');
  check(resolutionLabel(0, 0).isEmpty, '没有分辨率返回空串');

  stdout.writeln('=== 6. 行内元信息 ===');
  const video = MediaMeta(
    duration: Duration(seconds: 724),
    width: 1920,
    height: 1080,
  );
  check(video.inlineInfo == '12:04 · 1080p', '视频行内：时长 · 分辨率');
  check(!video.attention, '正常视频不需要标红');

  const playlist = MediaMeta(isPlaylist: true, segments: 8);
  check(playlist.inlineInfo == '8 分片 · 齐全', '清单行内：分片数 · 齐全');
  check(!playlist.inlineInfo.contains('1080p'), '清单不冒充分辨率');

  const missing = MediaMeta(isPlaylist: true, segments: 8, missingSegments: 2);
  check(missing.inlineInfo.contains('缺 2 段'), '缺分片写进行内');
  check(missing.attention, '缺分片要标出来');

  const unreadable = MediaMeta(isPlaylist: true, failed: true);
  check(unreadable.segmentStatus == '清单不可读', '解析失败说「不可读」而不是「0 段」');
  check(unreadable.attention, '解析失败同样标出来');

  const remote = MediaMeta(isPlaylist: true, segments: 5, note: '远程分片');
  check(remote.inlineInfo.contains('远程分片'), '远程分片如实说明');

  const encryptedList = MediaMeta(
    isPlaylist: true,
    segments: 4,
    encrypted: true,
  );
  check(encryptedList.inlineInfo.contains('加密'), '加密清单标出来');

  stdout.writeln('=== 7. 缓存序列化 ===');
  final round = MediaMeta.fromJson(playlist.toJson());
  check(round.isPlaylist && round.segments == 8, '清单标记与分片数往返一致');
  final videoRound = MediaMeta.fromJson(video.toJson());
  check(videoRound.duration == video.duration && videoRound.height == 1080,
      '视频元数据往返一致');
  final missingRound = MediaMeta.fromJson(missing.toJson());
  check(missingRound.missingSegments == 2, '缺失分片数往返一致');
  final failedRound = MediaMeta.fromJson(unreadable.toJson());
  check(failedRound.failed, '失败标记往返一致');
  check(MediaMeta.fromJson(<String, dynamic>{}).duration == null,
      '空 JSON 解析成「拿不到」，不是 0');

  stdout.writeln();
  if (failures.isEmpty) {
    stdout.writeln('全部通过：$passed 项断言');
  } else {
    stdout.writeln('失败 ${failures.length} 项：');
    for (final f in failures) {
      stdout.writeln(' - $f');
    }
    exitCode = 1;
  }
}
