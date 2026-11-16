// 回源请求的浏览器等效头 + 403 诊断文案：不依赖 Flutter，可直接
// `dart run tool/verify_browser_headers.dart`。
//
// 背景见 docs/download-auth-and-challenge.md。这里锁三件事：
// 1. 头映射只补浏览器必带的项，且不碰 UA / Referer / Cookie / Range（否则会覆盖真实会话）；
// 2. Sec-Fetch-Site 的推导与浏览器一致（同源 / 跨站 / 直接访问）；
// 3. 403 的三种情况能翻译成互不相同的文案，不再一律「Cookie 未取到」。
import 'dart:io';

import 'package:nerelict/services/browser_headers.dart';
import 'package:nerelict/services/download_diagnosis.dart';
import 'package:nerelict/services/page_cookie_probe.dart';

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
  stdout.writeln('=== 1. 头的取值 ===');
  final same = browserMediaHeaders(
    'https://cdn.site.com/v/index.m3u8',
    referer: 'https://cdn.site.com/watch/1',
  );
  check(same['Accept'] == '*/*', 'Accept 取 */*（XHR 取媒体的默认值）');
  check(same['Accept-Language'] == kAcceptLanguage, 'Accept-Language 用固定权重串');
  check(same['Sec-Fetch-Dest'] == 'empty', 'Sec-Fetch-Dest 为 empty');
  check(same['Sec-Fetch-Mode'] == 'cors', 'Sec-Fetch-Mode 为 cors');
  check(same['Sec-Fetch-Site'] == 'same-origin', '同 host 同 scheme 判 same-origin');

  final cross = browserMediaHeaders(
    'https://cdn.site.com/v/index.m3u8',
    referer: 'https://www.site.com/watch/1',
  );
  check(cross['Sec-Fetch-Site'] == 'cross-site', 'host 不同判 cross-site');

  final schemeDiff = browserMediaHeaders(
    'http://cdn.site.com/v/index.m3u8',
    referer: 'https://cdn.site.com/watch/1',
  );
  check(schemeDiff['Sec-Fetch-Site'] == 'cross-site',
      '仅 scheme 不同也判 cross-site（与浏览器一致）');

  final none = browserMediaHeaders('https://cdn.site.com/v/index.m3u8');
  check(none['Sec-Fetch-Site'] == 'none', '没有 Referer 判 none');
  check(
      browserMediaHeaders('https://cdn.site.com/v/index.m3u8',
              referer: '')[ 'Sec-Fetch-Site'] ==
          'none',
      'Referer 为空串同样判 none');
  check(
      browserMediaHeaders('https://cdn.site.com/v/index.m3u8',
              referer: 'not-a-url')[ 'Sec-Fetch-Site'] ==
          'none',
      'Referer 不可解析时按 none 处理');

  stdout.writeln('=== 2. 不越权 ===');
  for (final name in <String>[
    'User-Agent',
    'Referer',
    'Cookie',
    'Range',
    'Accept-Encoding',
    'sec-ch-ua',
    'sec-ch-ua-mobile',
  ]) {
    check(!same.containsKey(name), '不产出 $name（由调用方按真实会话填）');
  }
  check(browserMediaHeaders('/relative/path.m3u8').isEmpty,
      '非绝对地址返回空表，不给调用方添乱');
  check(browserMediaHeaders('').isEmpty, '空地址返回空表');

  stdout.writeln('=== 3. 403 诊断分类 ===');
  final sent = describeAuthFailure(
    cookieSent: true,
    cookieCount: 3,
    pageCookieLength: 120,
    challenged: false,
  );
  check(sent.cookieLabel.contains('已带') && sent.cookieLabel.contains('3'),
      '带上 Cookie 时标签说明条数');
  check(sent.hint.contains('签名') || sent.hint.contains('来源页'),
      '带 Cookie 仍被拒：指向来源页校验 / 签名，而不是登录态');

  final challenged = describeAuthFailure(
    cookieSent: true,
    cookieCount: 3,
    pageCookieLength: 120,
    challenged: true,
  );
  check(challenged.hint.contains('自动化'), '带 Cookie 仍被挑战：指向请求特征差异');
  check(challenged.hint != sent.hint, '被挑战与普通被拒文案不同');

  final noCookieNoPage = describeAuthFailure(
    cookieSent: false,
    cookieCount: 0,
    pageCookieLength: 0,
    challenged: false,
  );
  check(noCookieNoPage.cookieLabel.contains('页面也没有可见 Cookie'),
      '页面也没有 Cookie 时单独成一种');
  check(noCookieNoPage.hint.contains('播放十几秒') || noCookieNoPage.hint.contains('重新登录'),
      '给出的建议是「先在页面里把挑战过掉」');

  final httpOnly = describeAuthFailure(
    cookieSent: false,
    cookieCount: 0,
    pageCookieLength: 88,
    challenged: false,
  );
  check(httpOnly.cookieLabel.contains('88'), '页面有可见 Cookie 时把长度报出来');
  check(httpOnly.hint.contains('HttpOnly'), '指向 HttpOnly：这是要上浏览器代取的那种');
  check(httpOnly.cookieLabel != noCookieNoPage.cookieLabel,
      '两种「没取到 Cookie」不会混成一句');

  final unknown = describeAuthFailure(
    cookieSent: false,
    cookieCount: 0,
    pageCookieLength: null,
    challenged: false,
  );
  check(unknown.cookieLabel.contains('不可用'),
      '读数拿不到时明说「不可用」，不冒充 0');

  stdout.writeln('=== 4. HttpOnly 判定与探针 ===');
  check(
      looksHttpOnlyOnly(cookieSent: false, pageCookieLength: 10) == true,
      '没带上但页面有可见 Cookie → 判 HttpOnly');
  check(looksHttpOnlyOnly(cookieSent: false, pageCookieLength: 0) == false,
      '页面也没有 Cookie → 不是 HttpOnly');
  check(looksHttpOnlyOnly(cookieSent: false, pageCookieLength: null) == false,
      '读数不可用 → 不下 HttpOnly 结论');
  check(looksHttpOnlyOnly(cookieSent: true, pageCookieLength: 10) == false,
      '已经带上 Cookie → 与 HttpOnly 无关');

  PageCookieProbe.clear();
  check(PageCookieProbe.lengthFor('a.com') == null, '未读数时返回 null');
  PageCookieProbe.lastLength = 42;
  PageCookieProbe.lastHost = 'a.com';
  check(PageCookieProbe.lengthFor('a.com') == 42, '同 host 返回读数');
  check(PageCookieProbe.lengthFor('A.COM') == 42, 'host 比较忽略大小写');
  check(PageCookieProbe.lengthFor('b.com') == null,
      '换站后旧读数不再适用（不把别的站的结论套过来）');
  PageCookieProbe.clear();
  check(PageCookieProbe.lastLength == null && PageCookieProbe.lastHost.isEmpty,
      'clear 把读数与 host 一起清掉');

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
