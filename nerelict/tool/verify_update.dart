// 自动更新检查：版本比较、tag 归一、节流窗口与 Release JSON 降级。
// 不依赖 Flutter / 网络，可直接 `dart run tool/verify_update.dart`。
//
// 锁四件事：
// 1. 三段版本必须按数字比（`0.4.9` 要小于 `0.4.10`），不能按字符串；
// 2. tag 上的前缀 / 后缀（`v`、`release-`、`-beta`）不能影响版本识别；
// 3. 6 小时节流窗口的边界，以及时间被回拨时不卡死；
// 4. GitHub 返回缺 assets / 缺 apk 时只降级、不判失败，界面还能引导去网页。
import 'dart:convert';
import 'dart:io';

import 'package:nerelict/models/release_info.dart';

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

String read(String rel) => File(rel).readAsStringSync();

void main() {
  stdout.writeln('== 1. 版本号解析 ==');
  check(versionFromTag('v0.4.14') == '0.4.14', 'v 前缀被剥掉');
  check(versionFromTag('0.4.14') == '0.4.14', '裸版本原样保留');
  check(versionFromTag('release-0.5.0') == '0.5.0', '前缀文字被跳过');
  check(versionFromTag('v0.5.0-beta1') == '0.5.0', '预发布后缀不参与比较');
  check(versionFromTag('V1.2') == '1.2', '大写 V 也认，段数不补齐');
  check(versionFromTag('nightly') == null, '无数字的 tag 不认');
  check(versionFromTag('') == null, '空 tag 不认');
  check(versionFromTag(null) == null, 'null 不认');

  stdout.writeln('');
  stdout.writeln('== 2. 三段语义比较 ==');
  check(compareVersionStrings('0.4.9', '0.4.10') < 0, '0.4.9 < 0.4.10（不能按字符串比）');
  check(compareVersionStrings('0.4.14', '0.5.0') < 0, '0.4.14 < 0.5.0');
  check(compareVersionStrings('0.5.0', '0.5.0') == 0, '同版本相等');
  check(compareVersionStrings('0.5', '0.5.0') == 0, '段数不同的同版本视为相等');
  check(compareVersionStrings('1.0.0', '0.9.9') > 0, '主版本更大的更新');
  check(compareVersionStrings('0.10.0', '0.9.0') > 0, '第二段两位数正确（0.10 > 0.9）');
  check(isNewerVersion('0.5.1', '0.5.0'), '更新判定：新版本返回 true');
  check(!isNewerVersion('0.5.0', '0.5.0'), '更新判定：同版本返回 false');
  check(!isNewerVersion('0.4.14', '0.5.0'), '更新判定：自己编的更高版本不提示降级');
  check(!isNewerVersion('oops', '0.5.0'), '无法解析的最新版本不提示');

  stdout.writeln('');
  stdout.writeln('== 3. 节流窗口 ==');
  const window = Duration(hours: 6);
  final now = DateTime(2026, 11, 27, 12).millisecondsSinceEpoch;
  check(
    withinThrottle(lastMs: now - 5 * 3600 * 1000, nowMs: now, window: window),
    '5 小时前查过：窗口内，不再请求',
  );
  check(
    !withinThrottle(lastMs: now - 7 * 3600 * 1000, nowMs: now, window: window),
    '7 小时前查过：窗口外，重新请求',
  );
  check(
    !withinThrottle(lastMs: now - 6 * 3600 * 1000, nowMs: now, window: window),
    '正好 6 小时：按过期处理',
  );
  check(
    !withinThrottle(lastMs: 0, nowMs: now, window: window),
    '从未检查过（0）不节流',
  );
  check(
    !withinThrottle(lastMs: now + 3600 * 1000, nowMs: now, window: window),
    '系统时间被回拨后不永久卡死',
  );

  stdout.writeln('');
  stdout.writeln('== 4. Release JSON 解析 ==');
  final full = <String, dynamic>{
    'tag_name': 'v0.5.0',
    'body': '## 这一版\n\n- 音轨分离下载\n- 自动更新',
    'html_url': 'https://github.com/adonis797/nerelict/releases/tag/v0.5.0',
    'prerelease': false,
    'assets': <dynamic>[
      <String, dynamic>{
        'name': 'nerelict-0.5.0-arm64.apk',
        'browser_download_url':
            'https://github.com/adonis797/nerelict/releases/download/v0.5.0/nerelict-0.5.0-arm64.apk',
        'size': 21903456,
      },
    ],
  };
  final parsed = parseReleaseJson(full);
  check(parsed != null, '完整响应可解析');
  check(parsed!.version == '0.5.0', '版本取自 tag_name');
  check(parsed.asset?.name == 'nerelict-0.5.0-arm64.apk', '选中 apk 附件');
  check(parsed.asset?.size == 21903456, '附件体积被记录');
  check(parsed.plainNotes.contains('音轨分离下载'), '正文保留');
  check(!parsed.plainNotes.contains('##'), 'Markdown 标题标记被削掉');

  final multiAsset = <String, dynamic>{
    'tag_name': 'v0.5.0',
    'assets': <dynamic>[
      <String, dynamic>{
        'name': 'nerelict-0.5.0-x64.apk',
        'browser_download_url': 'https://example.com/x64.apk',
        'size': 100,
      },
      <String, dynamic>{
        'name': 'nerelict-0.5.0-arm64.apk',
        'browser_download_url': 'https://example.com/arm64.apk',
        'size': 200,
      },
      <String, dynamic>{
        'name': 'SHA256SUMS',
        'browser_download_url': 'https://example.com/hash',
        'size': 50,
      },
    ],
  };
  check(parseReleaseJson(multiAsset)?.asset?.name == 'nerelict-0.5.0-arm64.apk',
      '多个附件时优先 arm64，不取第一个');

  final noAssets = <String, dynamic>{
    'tag_name': 'v0.5.1',
    'body': '',
  };
  final degraded = parseReleaseJson(noAssets);
  check(degraded != null, '缺 assets 仍然解析出版本');
  check(degraded!.asset == null && !degraded.hasAsset, '缺 assets 时 asset 为空');
  check(!degraded.prerelease, '缺 prerelease 按正式版处理');

  final onlyZip = <String, dynamic>{
    'tag_name': 'v0.5.2',
    'assets': <dynamic>[
      <String, dynamic>{
        'name': 'source.zip',
        'browser_download_url': 'https://example.com/src.zip',
        'size': 10,
      },
    ],
  };
  check(parseReleaseJson(onlyZip)?.asset == null, '只有 zip 时不把非 apk 当安装包');

  check(parseReleaseJson(<String, dynamic>{'tag_name': 'nightly'}) == null,
      'tag 无法解析时整条响应作废');
  check(parseReleaseJson(<String, dynamic>{}) == null, '缺 tag_name 作废');
  check(
    parseReleaseJson(<String, dynamic>{
      'tag_name': 'v0.5.3',
      'prerelease': true,
    })!.prerelease,
    '预发布标记被保留（界面据此不催更新）',
  );

  stdout.writeln('');
  stdout.writeln('== 5. 缓存往返 ==');
  final cacheRaw = jsonEncode(parsed.toJson());
  final restored = ReleaseInfo.fromJson(jsonDecode(cacheRaw));
  check(restored?.version == parsed.version, '缓存能还原版本');
  check(restored?.asset?.url == parsed.asset?.url, '缓存能还原下载地址');
  check(restored?.notes == parsed.notes, '缓存能还原正文');
  check(ReleaseInfo.fromJson(<String, dynamic>{'tag': 'v1'}) == null,
      '缺字段的缓存不崩');
  check(ReleaseInfo.fromJson('oops') == null, '类型不对的缓存不崩');

  stdout.writeln('');
  stdout.writeln('== 6. 体积展示 ==');
  check(formatBytes(0) == '0 B', '0 字节');
  check(formatBytes(512) == '512 B', '1KB 以下按字节');
  check(formatBytes(21903456) == '20.9 MB', '安装包体积显示一位小数');
  check(formatBytes(1024) == '1.0 KB', 'KB 边界');

  stdout.writeln('');
  stdout.writeln('== 7. 实现要点没被改回 ==');
  final feed = read('lib/services/release_feed.dart');
  check(feed.contains("'https://api.github.com/repos/\$repo/releases/latest'"),
      '更新源指向自己的 releases/latest');
  check(feed.contains('Duration(hours: 6)'), '节流窗口仍是 6 小时');
  check(feed.contains('code == 403 || code == 429'), '限流单独给文案，不吞成未知错误');
  check(feed.contains('length == asset.size'), '下载后比对附件体积');
  check(feed.contains('attempt == 1'), '体积不符会重试一次再报错');

  final settings = read('lib/ui/settings_tab.dart');
  check(settings.contains('UpdateTile(p: p, currentVersion: SettingsTab.appVersion)'),
      '关于页接入了检查更新');
  check(!settings.contains('pickAndInstall'), '不再要求用户自己挑 APK');

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
