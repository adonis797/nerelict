import 'dart:convert';
import 'dart:io';

import 'package:nerelict/models/download_task.dart';
import 'package:nerelict/models/web_favorite.dart';
import 'package:nerelict/services/conversion_policy.dart';

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
  stdout.writeln('=== 1. 下载任务序列化（断点续传基础） ===');
  final task = DownloadTask(
    id: 'task_1',
    url: 'https://cdn.example.com/a.m3u8',
    title: '示例视频',
    createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
  )
    ..status = TaskStatus.downloading
    ..totalSegments = 120
    ..doneSegments = 47
    ..progress = 47 / 120
    ..bytes = 12345678
    ..referer = 'https://example.com/page'
    ..variant = '1280x720'
    ..segments = <String>['https://a/1.ts', 'https://a/2.ts'];

  final json = jsonDecode(jsonEncode(task.toJson())) as Map<String, dynamic>;
  final restored = DownloadTask.fromJson(json);
  check(restored != null, '可以还原成任务对象');
  final r = restored!;
  check(r.id == task.id && r.url == task.url, 'id / 地址保持不变');
  check(r.title == '示例视频', '标题保持不变');
  check(r.createdAt.millisecondsSinceEpoch == 1700000000000, '创建时间保持不变');
  check(r.status == TaskStatus.paused, '下载中的任务恢复为「已暂停」');
  check(r.totalSegments == 120 && r.doneSegments == 47, '分片进度保持不变');
  check((r.progress - 47 / 120).abs() < 1e-9, '进度百分比保持不变');
  check(r.bytes == 12345678, '已下载字节数保持不变');
  check(r.variant == '1280x720', '码率信息保持不变');
  check(r.referer == 'https://example.com/page', 'Referer 保持不变');
  check(r.segments?.length == 2, '分片组地址保持不变');
  check(r.recovered, '恢复标记为真（用于自动续传）');
  check(r.savedActive, '原本在下载 -> 恢复后自动续传');

  stdout.writeln('=== 2. 转换状态恢复 ===');
  final converting = DownloadTask(id: 't2', url: 'https://x/b.m3u8', title: 'b')
    ..status = TaskStatus.done
    ..filePath = '/downloads/b.ts'
    ..conversion = ConversionState.converting;
  final restoredConverting = DownloadTask.fromJson(
    jsonDecode(jsonEncode(converting.toJson())) as Map<String, dynamic>,
  )!;
  check(restoredConverting.conversion == ConversionState.idle,
      '上次被打断的转换恢复为可重试');
  check(restoredConverting.filePath == '/downloads/b.ts', '产物路径保持不变');
  check(DownloadTask.fromJson(<String, dynamic>{'id': '', 'url': 'x'}) == null,
      '缺少 id 的脏数据被丢弃');
  final pausedJson = <String, dynamic>{
    'id': 'tp',
    'url': 'https://x/p.m3u8',
    'title': 'p',
    'status': 'paused',
  };
  final restoredPaused = DownloadTask.fromJson(pausedJson)!;
  check(!restoredPaused.savedActive, '手动暂停的任务恢复后不自动续传');
  check(
      DownloadTask.fromJson(<String, dynamic>{
        'id': 't3',
        'url': 'https://x/c.m3u8',
        'status': 'unknown_state',
      })?.status ==
          TaskStatus.paused,
      '未知状态按「已暂停」兜底');

  stdout.writeln('=== 3. 手动转换条件（与设置开关解耦） ===');
  final tsTask = DownloadTask(id: 't4', url: 'https://x/d.m3u8', title: 'd')
    ..status = TaskStatus.done
    ..filePath = '/downloads/d.ts';
  check(canStartConversion(task: tsTask), '完成的 TS 允许转换');
  final mp4Task = DownloadTask(id: 't5', url: 'https://x/e.mp4', title: 'e')
    ..status = TaskStatus.done
    ..filePath = '/downloads/e.mp4';
  check(!canStartConversion(task: mp4Task), 'MP4 产物不需要转换');
  tsTask.conversion = ConversionState.converting;
  check(!canStartConversion(task: tsTask), '转换中不重复触发');
  check(!canStartConversion(task: DownloadTask(id: 't6', url: 'u', title: 'f')),
      '未完成的任务不转换');

  stdout.writeln('=== 4. 网页收藏分类 / 快速访问序列化 ===');
  final fav = WebFavorite(
    url: 'https://example.com/watch',
    title: '示例站',
    addedAt: 1700000000000,
    category: '视频站',
    quickAccess: true,
    iconUrl: 'https://example.com/icon.png',
  );
  final restoredFav = WebFavorite.fromJson(
    jsonDecode(jsonEncode(fav.toJson())),
  )!;
  check(restoredFav.category == '视频站', '分类名称保持不变');
  check(restoredFav.quickAccess, '快速访问标记保持不变');
  check(restoredFav.iconUrl == 'https://example.com/icon.png', '图标地址保持不变');
  check(restoredFav.categoryLabel == '视频站', '分类展示名正确');

  final legacy = WebFavorite.fromJson(<String, dynamic>{
    'url': 'https://old.example.com',
    'title': '旧收藏',
    'addedAt': 1600000000000,
  })!;
  check(legacy.category == '' && !legacy.quickAccess, '旧版本收藏向后兼容');
  check(legacy.categoryLabel == '未分类', '旧收藏归入「未分类」');
  check(legacy.iconUrl == null, '旧收藏没有图标时不报错');

  final copied = legacy.copyWith(category: '学习', quickAccess: true);
  check(copied.category == '学习' && copied.quickAccess, 'copyWith 可改分类与快速访问');
  check(copied.url == legacy.url && copied.title == legacy.title, '其余字段不受影响');

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
