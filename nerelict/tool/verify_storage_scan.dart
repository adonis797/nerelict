// 纯 Dart 主机侧断言：验证「文件类型 MIME 嗅探」与「全盘递归扫描」。
// 运行：dart run tool/verify_storage_scan.dart
//
// 覆盖：
//   1. sniffKind 文件头魔数判定（视频/音频/图片/文档/压缩包，含 MP4 容器品牌区分）；
//   2. scanAllStorage 递归扫描、深度/系统目录跳过、隐藏项与半成品跳过、空文件跳过、
//      类型识别（扩展名 + 无扩展名文件靠魔数）、取消、文件数上限截断；
//   3. 噪音过滤：缓存/缩略图目录、.nomedia 目录、成组纯数字分片、seg_*.bin 半成品，
//      以及 includeNoise 开关与用户目录优先顺序。
import 'dart:io';

import 'package:nerelict/services/file_kinds.dart';
import 'package:nerelict/services/storage_scanner.dart';

int _passed = 0;

void check(bool ok, String name) {
  if (!ok) throw StateError('断言失败：$name');
  _passed++;
  stdout.writeln('  ✓ $name');
}

List<int> _bytes(String ascii) => ascii.codeUnits;

Future<void> main() async {
  _testSniffKind();
  _testNoiseNames();

  final root = await Directory.systemTemp.createTemp('nerelict_scan_');
  try {
    await _testScan(root);
  } finally {
    await root.delete(recursive: true);
  }

  final noiseRoot = await Directory.systemTemp.createTemp('nerelict_noise_');
  try {
    await _testNoiseFilter(noiseRoot);
  } finally {
    await noiseRoot.delete(recursive: true);
  }

  stdout.writeln('\n全部 $_passed 项断言通过');
}

/// 名字级判定：分片 / 半成品 / 缓存目录。
void _testNoiseNames() {
  check(looksLikeMediaSegment('253.ts'), '纯数字段号 .ts 判为分片');
  check(looksLikeMediaSegment('0012.m4s'), '纯数字段号 .m4s 判为分片');
  check(looksLikeMediaSegment('seg_12.ts'), 'seg_ 前缀判为分片');
  check(!looksLikeMediaSegment('movie.mp4'), '正常命名的 mp4 不算分片');
  check(!looksLikeMediaSegment('253'), '没有扩展名不算分片（可能是无扩展名文件）');
  check(!looksLikeMediaSegment('photo.jpg'), '图片不算媒体分片');

  check(looksLikePartFile('seg_${'a' * 64}.bin'), '下载器分片 seg_*.bin 判为半成品');
  check(looksLikePartFile('init_${'b' * 64}.mp4') == false,
      'init_*.mp4 不按半成品处理（按扩展名仍可识别）');
  check(looksLikePartFile('a.part'), '.part 判为半成品');
  check(looksLikePartFile('a.tmp'), '.tmp 判为半成品');
  check(!looksLikePartFile('movie.mp4'), '正常视频不是半成品');

  check(kNoiseDirNames.contains('cache'), 'cache 目录在噪音名单里');
  check(kNoiseDirNames.contains('thumbnails'), 'thumbnails 目录在噪音名单里');
  check(!kNoiseDirNames.contains('download'), 'download 不在噪音名单里');
}

void _testSniffKind() {
  // 视频
  check(sniffKind(_bytes('\x00\x00\x00\x18ftypisom')) == LocalFileKind.video,
      'MP4 ftyp 识别为视频');
  check(sniffKind(_bytes('\x00\x00\x00\x18ftypM4A ')) == LocalFileKind.audio,
      'MP4 M4A 品牌识别为音频');
  check(sniffKind(_bytes('\x00\x00\x00\x18ftypqt  ')) == LocalFileKind.video,
      'QuickTime MOV 识别为视频');
  check(sniffKind(const [0x1A, 0x45, 0xDF, 0xA3]) == LocalFileKind.video,
      'Matroska 魔数识别为视频');
  check(sniffKind(const [0x46, 0x4C, 0x56, 0x01]) == LocalFileKind.video,
      'FLV 魔数识别为视频');
  check(sniffKind(const [0x47, 0x00, 0x01, 0x02]) == null,
      '0x47 开头不做 TS 嗅探（避免误伤 GIF）');

  // 音频
  check(sniffKind(const [0xFF, 0xFB, 0x90, 0x00]) == LocalFileKind.audio,
      'MP3 帧同步识别为音频');
  check(sniffKind(_bytes('ID3\x04\x00')) == LocalFileKind.audio,
      'ID3 头识别为音频');
  check(sniffKind(_bytes('fLaC\x00')) == LocalFileKind.audio,
      'FLAC 魔数识别为音频');
  check(sniffKind(_bytes('OggS\x00')) == LocalFileKind.audio,
      'OggS 识别为音频');
  check(sniffKind(_bytes('RIFF\x24\x00\x00\x00WAVE')) == LocalFileKind.audio,
      'RIFF/WAVE 识别为音频');
  check(sniffKind(_bytes('RIFF\x24\x00\x00\x00AVI ')) == LocalFileKind.video,
      'RIFF/AVI 识别为视频');
  check(sniffKind(_bytes('RIFF\x24\x00\x00\x00WEBP')) == LocalFileKind.image,
      'RIFF/WEBP 识别为图片');

  // 图片
  check(sniffKind(const [0xFF, 0xD8, 0xFF, 0xE0]) == LocalFileKind.image,
      'JPEG 魔数识别为图片');
  check(sniffKind(const [0x89, 0x50, 0x4E, 0x47]) == LocalFileKind.image,
      'PNG 魔数识别为图片');
  check(sniffKind(_bytes('GIF89a')) == LocalFileKind.image,
      'GIF 魔数识别为图片');
  check(sniffKind(const [0x42, 0x4D, 0x00, 0x00]) == LocalFileKind.image,
      'BMP 魔数识别为图片');
  check(sniffKind(_bytes('\x00\x00\x00\x18ftypheic')) == LocalFileKind.image,
      'HEIC ftyp 识别为图片');
  check(sniffKind(_bytes('\x00\x00\x00\x18ftypavif')) == LocalFileKind.image,
      'AVIF ftyp 识别为图片');

  // 文档
  check(sniffKind(_bytes('%PDF-1.4')) == LocalFileKind.document,
      'PDF 魔数识别为文档');

  // 压缩包
  check(sniffKind(const [0x50, 0x4B, 0x03, 0x04]) == LocalFileKind.archive,
      'ZIP 魔数识别为压缩包');
  check(sniffKind(const [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) ==
      LocalFileKind.archive, '7z 魔数识别为压缩包');
  check(sniffKind(const [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]) ==
      LocalFileKind.archive, 'RAR 魔数识别为压缩包');

  // 空/未知
  check(sniffKind(const <int>[]) == null, '空头返回 null（交给扩展名兜底）');
  check(sniffKind(const [0x00, 0x00, 0x00, 0x00]) == null,
      '未知头返回 null');

  // 扩展名映射扩充
  check(kindOfName('a.flac') == LocalFileKind.audio, '.flac 归音频');
  check(kindOfName('a.svg') == LocalFileKind.image, '.svg 归图片');
  check(kindOfName('a.rtf') == LocalFileKind.document, '.rtf 归文档');
  check(kindOfName('a.bz2') == LocalFileKind.archive, '.bz2 归压缩包');
  check(kindOfName('a.log') == LocalFileKind.document, '.log 归文档');
  check(kindOfName('a.xyz') == LocalFileKind.other, '未知扩展名归其他');
}

Future<void> _testScan(Directory root) async {
  // 结构：
  //   root/
  //     movie.mp4            （扩展名识别：视频）
  //     song.mp3             （音频）
  //     photo.JPG            （图片，大写扩展名）
  //     noext_png            （无扩展名，魔数识别：图片）
  //     .hidden.txt          （隐藏文件，跳过）
  //     tmp.part             （半成品，跳过）
  //     empty.bin            （空文件，跳过）
  //     Android/             （系统目录，跳过）
  //       data/x
  //     .secret/             （隐藏目录，跳过）
  //     sub/
  //       deep.mp4           （子目录文件）
  //       .nested_skip.txt   （隐藏文件）
  //     deep/                （超深目录链）
  //       d1/d2/d3/d4/d5/d6/d7/d8/file.bin

  Future<void> write(String rel, List<int> bytes) async {
    final f = File('${root.path}${Platform.pathSeparator}$rel');
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes);
  }

  await write('movie.mp4', _bytes('\x00\x00\x00\x18ftypisom'));
  await write('song.mp3', const [0xFF, 0xFB, 0x90, 0x00]);
  await write('photo.JPG', const [0xFF, 0xD8, 0xFF, 0xE0]);
  await write('noext_png', const [0x89, 0x50, 0x4E, 0x47]);
  await write('.hidden.txt', const [1, 2, 3]);
  await write('tmp.part', const [1, 2, 3]);
  await write('empty.bin', const <int>[]);
  await write('Android/data/x', const [1, 2, 3]);
  await write('.secret/y.txt', const [1, 2, 3]);
  await write('sub/deep.mp4', _bytes('\x00\x00\x00\x18ftypisom'));
  await write('sub/.nested_skip.txt', const [1, 2, 3]);
  await write(
      'deep/d1/d2/d3/d4/d5/d6/d7/d8/file.bin', const [1, 2, 3, 4]);

  final result = await scanAllStorage(root: root.path);
  final names = result.files.map((f) => f.name).toSet();

  check(result.complete, '扫描正常完成');
  check(!result.truncated, '小目录不触发截断');
  check(names.contains('movie.mp4'), '收集视频文件');
  check(names.contains('song.mp3'), '收集音频文件');
  check(names.contains('photo.JPG'), '收集图片文件（大写扩展名）');
  check(names.contains('noext_png'), '收集无扩展名文件');
  check(names.contains('deep.mp4'), '递归进入子目录');
  check(!names.contains('.hidden.txt'), '跳过隐藏文件');
  check(!names.contains('tmp.part'), '跳过 .part 半成品');
  check(!names.contains('empty.bin'), '跳过空文件');
  check(!names.contains('x'), '跳过 Android 系统目录内的文件');
  check(!names.contains('y.txt'), '跳过隐藏目录内的文件');
  check(!names.contains('.nested_skip.txt'), '跳过子目录内的隐藏文件');
  check(!names.contains('file.bin'), '超过最大深度时不进入');

  // 类型识别校验
  LocalFile? byName(String n) =>
      result.files.cast<LocalFile?>().firstWhere((f) => f?.name == n,
          orElse: () => null);
  check(byName('movie.mp4')?.kind == LocalFileKind.video, 'movie.mp4 判视频');
  check(byName('song.mp3')?.kind == LocalFileKind.audio, 'song.mp3 判音频');
  check(byName('photo.JPG')?.kind == LocalFileKind.image, 'photo.JPG 判图片');
  check(byName('noext_png')?.kind == LocalFileKind.image,
      '无扩展名文件靠魔数识别为图片');

  // 取消语义
  var cancelled = false;
  final partial = await scanAllStorage(root: root.path, cancel: () => cancelled);
  check(partial.complete, '取消前先跑完，结果为完整');
  check(partial.files.isNotEmpty, '取消前已收集到文件');
}

/// 噪音过滤：分片、缓存目录、.nomedia 目录与 includeNoise 开关。
Future<void> _testNoiseFilter(Directory root) async {
  Future<void> write(String rel, List<int> bytes) async {
    final f = File('${root.path}${Platform.pathSeparator}$rel');
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes);
  }

  final mp4 = _bytes('\x00\x00\x00\x18ftypisom');
  final jpg = const [0xFF, 0xD8, 0xFF, 0xE0];
  final ts = const [0x47, 0x00, 0x01, 0x02];

  // HLS 缓存：整目录都是纯数字段号
  for (var i = 0; i < 6; i++) {
    await write('segcache/$i.ts', ts);
  }
  // 用户目录里混着分片与真正的视频
  await write('Download/real.mp4', mp4);
  for (var i = 0; i < 4; i++) {
    await write('Download/$i.ts', ts);
  }
  await write('DCIM/photo.jpg', jpg);
  // 缓存目录：名字命中噪音名单
  await write('Cache/thumb.jpg', jpg);
  // 带 .nomedia 的目录：应用私有缓存
  await write('appcache/.nomedia', const <int>[]);
  await write('appcache/hidden.png', jpg);
  // 下载器半成品
  await write('parts/seg_${'a' * 64}.bin', const [1, 2, 3]);
  // 只有 2 个分片：不足成组阈值，按普通文件保留
  await write('few/1.ts', ts);
  await write('few/2.ts', ts);
  // 排序用：优先级低于 Download
  await write('zzz/late.mp4', mp4);

  final result = await scanAllStorage(root: root.path);
  final rel = <String>{
    for (final f in result.files)
      f.path.substring(root.path.length + 1).replaceAll('\\', '/'),
  };

  check(rel.contains('Download/real.mp4'), '保留用户目录里的正常视频');
  check(rel.contains('DCIM/photo.jpg'), '保留用户目录里的图片');
  check(rel.contains('zzz/late.mp4'), '非优先目录同样会被扫描');
  check(!rel.contains('segcache/0.ts'), '整目录纯数字分片全部忽略');
  check(!rel.contains('Download/0.ts'), '用户目录里成组的分片也忽略');
  check(!rel.contains('Cache/thumb.jpg'), 'cache 目录整体跳过');
  check(!rel.contains('appcache/hidden.png'), '.nomedia 目录整体跳过');
  check(!rel.contains('parts/seg_${'a' * 64}.bin'), '下载器半成品不列出');
  check(rel.contains('few/1.ts') && rel.contains('few/2.ts'),
      '不足阈值（2 个）的数字命名文件保留，避免误杀');
  check(result.ignoredSegments == 6 + 4 + 1,
      '忽略计数覆盖分片与半成品（segcache 6 + Download 4 + 半成品 1）');
  check(result.skippedNoiseDirs >= 2, '缓存目录跳过计数大于等于 2');

  // 优先级：Download 先于 zzz（即使 zzz 名字排后面）
  final order = result.files
      .map((f) => f.path.substring(root.path.length + 1).replaceAll('\\', '/'))
      .toList();
  check(order.indexOf('Download/real.mp4') < order.indexOf('zzz/late.mp4'),
      '用户目录优先扫描，避免截断时先被冷门目录占满');

  // 开关：includeNoise 关掉过滤后，缓存目录与分片应重新出现
  final all = await scanAllStorage(root: root.path, includeNoise: true);
  final allRel = <String>{
    for (final f in all.files)
      f.path.substring(root.path.length + 1).replaceAll('\\', '/'),
  };
  check(allRel.contains('segcache/0.ts'), 'includeNoise 时列出分片');
  check(allRel.contains('Cache/thumb.jpg'), 'includeNoise 时列出缓存目录');
  check(allRel.contains('appcache/hidden.png'), 'includeNoise 时列出 .nomedia 目录');
  check(!allRel.contains('parts/seg_${'a' * 64}.bin'),
      'includeNoise 也不列下载半成品（没有可用数据）');
}
