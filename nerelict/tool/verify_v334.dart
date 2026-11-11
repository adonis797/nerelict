import 'dart:io';

import 'package:nerelict/models/theme_mode.dart';
import 'package:nerelict/services/file_kinds.dart';

/// v3.3.4 纯逻辑断言：文件类型分组 + 主题模式解析。
/// 运行：dart run tool/verify_v334.dart
int _passed = 0;
final List<String> _failed = <String>[];

void check(String name, bool ok) {
  if (ok) {
    _passed++;
  } else {
    _failed.add(name);
  }
}

void main() {
  // 1. 文件类型映射
  const samples = <String, LocalFileKind>{
    'movie.mp4': LocalFileKind.video,
    'segment.ts': LocalFileKind.video,
    'clip.MKV': LocalFileKind.video,
    'song.mp3': LocalFileKind.audio,
    'voice.m4a': LocalFileKind.audio,
    'cover.JPG': LocalFileKind.image,
    'shot.webp': LocalFileKind.image,
    'doc.pdf': LocalFileKind.document,
    'notes.md': LocalFileKind.document,
    'sub.srt': LocalFileKind.document,
    'pack.zip': LocalFileKind.archive,
    'data.bin': LocalFileKind.other,
    'noext': LocalFileKind.other,
    'archive.tar.gz': LocalFileKind.archive,
  };
  samples.forEach((name, kind) {
    check('kindOfName($name) == ${kind.name}', kindOfName(name) == kind);
  });

  // 2. 类型文案
  const labels = <LocalFileKind, String>{
    LocalFileKind.video: '视频',
    LocalFileKind.audio: '音频',
    LocalFileKind.image: '图片',
    LocalFileKind.document: '文档',
    LocalFileKind.archive: '压缩包',
    LocalFileKind.other: '其他',
  };
  labels.forEach((kind, label) {
    check('label(${kind.name}) == $label', kind.label == label);
  });

  // 3. 主题存储值
  for (final mode in AppThemeMode.values) {
    final restored = AppThemeModeX.fromStorage(mode.storageValue);
    check('theme roundtrip ${mode.name}', restored == mode);
  }

  // 4. 老版本布尔开关迁移
  check('legacy true -> light',
      AppThemeModeX.fromStorage(null, legacyLight: true) == AppThemeMode.light);
  check('legacy false -> dark',
      AppThemeModeX.fromStorage(null, legacyLight: false) == AppThemeMode.dark);
  check('unknown value -> dark',
      AppThemeModeX.fromStorage('weird') == AppThemeMode.dark);
  check('cyber is not light', !AppThemeMode.cyber.isLight);
  check('light is light', AppThemeMode.light.isLight);
  check('labels distinct',
      AppThemeMode.values.map((e) => e.label).toSet().length == 3);

  stdout.writeln('通过 $_passed 项断言');
  if (_failed.isEmpty) {
    stdout.writeln('全部通过');
  } else {
    stdout.writeln('失败 ${_failed.length} 项：');
    for (final f in _failed) {
      stdout.writeln(' - $f');
    }
    throw StateError('assertions failed');
  }
}
