// 音轨独立流的下载能力：解析、选轨、进度合并与双轨收尾。
// 不依赖 Flutter，可直接 `dart run tool/verify_hls_audio.dart`。
//
// 锁四件事：
// 1. 主播放列表里的 AUDIO rendition 能被认出来，并且「带 URI 才算独立」；
// 2. 默认音轨的选择顺序固定（DEFAULT → 中文 → 第一条），不按声道数乱挑；
// 3. 双轨任务的进度分母是两段之和，且旧任务缺字段也能安全恢复；
// 4. 关键实现点没被改回去——音轨失败要删无声成品，双轨必须强制合并一次。
import 'dart:io';

import 'package:nerelict/models/download_task.dart';
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

const String _masterWithDefault = '''
#EXTM3U
#EXT-X-VERSION:6
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",LANGUAGE="en",DEFAULT=YES,URI="audio/en.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="中文",LANGUAGE="zh-CN",URI="audio/zh.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="国语 5.1",LANGUAGE="zh-CN",CHANNELS="6",URI="audio/zh51.m3u8"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="sub",NAME="中文",LANGUAGE="zh",URI="sub/zh.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,AUDIO="aud",SUBTITLES="sub"
v720/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
v360/index.m3u8
''';

/// 同一份列表，但没有任何 DEFAULT=YES：此时应优先中文，而不是第一条英文。
const String _masterNoDefault = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",LANGUAGE="en",URI="audio/en.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="中文",LANGUAGE="zh-CN",URI="audio/zh.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,AUDIO="aud"
v720/index.m3u8
''';

/// 音轨写在同一变体里（没有 URI）：不需要单独下载，也不该被当成独立音轨。
const String _masterInlineAudio = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Main",LANGUAGE="zh",DEFAULT=YES
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,AUDIO="aud"
v720/index.m3u8
''';

String read(String path) => File(path).readAsStringSync();

void main() {
  final base = Uri.parse('https://cdn.example.com/show/master.m3u8');

  stdout.writeln('=== 1. 独立音轨识别 ===');
  final withDefault = parseMasterPlaylistFull(_masterWithDefault, base);
  final v720 = withDefault.variants.firstWhere((v) => v.resolution == '1280x720');
  final v360 = withDefault.variants.firstWhere((v) => v.resolution == '640x360');
  check(withDefault.separateAudioFor(v720).length == 3,
      '720p 认出声明的 3 条独立音轨');
  check(withDefault.separateAudioFor(v360).isEmpty,
      '没有 AUDIO 属性的档位不会凭空多出音轨');
  check(withDefault.subtitlesFor(v720).length == 1, '字幕组仍按变体取到 1 条');

  final inline = parseMasterPlaylistFull(_masterInlineAudio, base);
  check(inline.separateAudioFor(inline.variants.first).isEmpty,
      'AUDIO 组没写 URI 时不算独立音轨（音轨内嵌在变体里）');
  check(inline.preferredAudioFor(inline.variants.first) == null,
      '内嵌音轨不产生“要另外下载的音轨”');

  stdout.writeln('=== 2. 默认音轨的选择顺序 ===');
  final picked = withDefault.preferredAudioFor(v720);
  check(picked != null, '有独立音轨时一定选得出一条');
  check(picked?.language == 'en', 'DEFAULT=YES 优先于“中文更顺耳”');
  check(picked?.uri == 'https://cdn.example.com/show/audio/en.m3u8',
      '音轨的相对地址按清单地址解析成绝对地址（否则下载 404）');

  final noDefault = parseMasterPlaylistFull(_masterNoDefault, base);
  final zh = noDefault.preferredAudioFor(noDefault.variants.first);
  check(zh?.language == 'zh-CN', '没有 DEFAULT 时优先中文，而不是列表第一条');
  check(zh?.label.contains('中文') == true, '音轨标签可直接展示给用户');

  stdout.writeln('=== 3. 双轨任务的进度与序列化 ===');
  final task = DownloadTask(id: 't1', url: 'https://x/a.m3u8', title: '示例')
    ..status = TaskStatus.done
    ..filePath = '/tmp/示例.ts'
    ..audioPath = '/tmp/示例.audio.ts'
    ..audioUrl = 'https://cdn.example.com/show/audio/zh.m3u8'
    ..audioName = 'zh-CN · 中文';
  final restored = DownloadTask.fromJson(task.toJson());
  check(restored != null, '带音轨字段的任务可以落盘再恢复');
  check(restored?.audioPath == task.audioPath, '音轨路径往返一致');
  check(restored?.audioUrl == task.audioUrl, '音轨清单地址往返一致');
  check(restored?.audioName == task.audioName, '音轨名称往返一致');

  // 0.4.x 及以前的任务没有这三个字段：不能因为缺字段就恢复失败
  final legacy = DownloadTask.fromJson(<String, dynamic>{
    'id': 'old',
    'url': 'https://x/a.m3u8',
    'title': '旧任务',
    'status': 'done',
    'filePath': '/tmp/旧任务.ts',
  });
  check(legacy != null, '旧版本任务记录仍能恢复');
  check(legacy?.audioPath == null && legacy?.audioUrl == null,
      '缺音轨字段时按 null 恢复，不抛异常');

  stdout.writeln('=== 4. 转换入口的判定 ===');
  check(task.canConvert, '双轨：视频轨是 ts 且有待合并的音轨时可转换');
  final mp4TwoTrack = DownloadTask(id: 't2', url: 'https://x', title: 'fmp4')
    ..status = TaskStatus.done
    ..filePath = '/tmp/fmp4.mp4'
    ..audioPath = '/tmp/fmp4.audio.m4a';
  check(mp4TwoTrack.canConvert,
      '视频轨本身是 mp4（fMP4）时，只要还有音轨待合并就必须能转');
  final mp4Single = DownloadTask(id: 't3', url: 'https://x', title: 'mp4')
    ..status = TaskStatus.done
    ..filePath = '/tmp/plain.mp4';
  check(!mp4Single.canConvert, '单轨 mp4 不需要再转一次');
  check(mp4TwoTrack.needsAudioMux && !mp4Single.needsAudioMux,
      'needsAudioMux 只在有音轨分轨产物时为真');

  stdout.writeln('=== 5. 实现点回归 ===');
  final downloader = read('lib/services/hls_downloader.dart');
  check(downloader.contains('progressOffset + done'),
      '进度按两段分片数合并，音轨开始时不回跳');
  check(downloader.contains('isAudio ? task.bytes : 0'),
      '音轨段累加字节，不冲掉视频段已下载的量');
  check(downloader.contains('音轨抓取失败'),
      '音轨失败会明确说明是哪条轨失败');
  check(downloader.contains('await _deleteQuietly(task.filePath)'),
      '音轨失败时删掉无声成品，不让它冒充下载完成');
  check(downloader.contains('deferDone: audioMedia != null'),
      '双轨时视频段不提前置成 done');
  check(downloader.contains('preferredAudioFor(chosen)'),
      '下载器按解析层的选轨结果取音轨');
  check(!downloader.contains('当前版本无法与画面合并'),
      '旧的「直接拒绝」文案已彻底移除');

  final appState = read('lib/state/app_state.dart');
  check(appState.contains('final mustMux = task.needsAudioMux'),
      '双轨任务必须合并一次，与自动转换开关无关');
  check(appState.contains('audioPath: audioSource'), '转换时把音轨路径传给原生');
  check(appState.contains('if (path == null && task.needsAudioMux) return;'),
      '音轨未合并前不导出，避免导出无声文件');

  final picker = read('lib/ui/variant_picker.dart');
  check(!picker.contains('final blocked = separateAudio.isNotEmpty'),
      '选流面板不再把音轨独立的档位标成不可选');
  check(picker.contains('会一并下载后合并'), '档位说明改成“会一并下载”');

  final converter = read('lib/services/mp4_converter.dart');
  check(converter.contains("'audioPath': audioPath"), '通道参数带上音轨路径');

  final kotlin = read(
      'android/app/src/main/kotlin/com/nerelict/nerelict/Mp4Converter.kt');
  check(kotlin.contains('private fun remuxTwo'), '原生侧有双输入归并实现');
  check(kotlin.contains('val globalMin = minOf(vFirst, aFirst)'),
      '两条轨统一按较早的起点归零，保留相对偏移');
  check(kotlin.contains('if (audio == null)'), '单轨路径保持原逻辑不变');

  stdout.writeln('');
  if (failures.isEmpty) {
    stdout.writeln('全部通过：$passed 项断言');
  } else {
    stdout.writeln('失败 ${failures.length} 项：');
    for (final f in failures) {
      stdout.writeln('  - $f');
    }
    exitCode = 1;
  }
}
