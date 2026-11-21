import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:pointycastle/export.dart';

import '../models/download_task.dart';
import 'browser_headers.dart';
import 'download_diagnosis.dart';
import 'hls_parser.dart';
import 'page_cookie_probe.dart';
import 'web_probe_result.dart';
import 'user_agent.dart';
import 'app_paths.dart';

class CanceledException implements Exception {
  const CanceledException();
  @override
  String toString() => '已取消';
}

class HlsDownloader {
  HlsDownloader({
    Dio? dio,
    this.concurrency = 4,
    this.resolveOutputDir,
    this.resolveTempDir,
    this.resolveCookie,
    this.invalidateCookie,
    this.captureProbe,
    this.nativeFetch,
  })  : dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 60),
              sendTimeout: const Duration(seconds: 20),
              followRedirects: true,
              maxRedirects: 8,
              responseType: ResponseType.bytes,
              // 这里只放兜底 UA。**不要**再塞 `Accept`：它会被合并进每一个请求，
              // 让「精简模式」（对齐播放器的那套头）名不副实——播放代理从不发 Accept，
              // 下载却发了，站点的 WAF 一眼就能分出这两个客户端。
              headers: {
                'User-Agent': UserAgent.kFallback,
              },
            ));

  final Dio dio;
  final int concurrency;

  /// 单个请求（含整个响应体）的最长耗时
  final Duration requestTimeout = const Duration(seconds: 45);

  /// 最近一次出站请求是否带上了 Cookie。
  ///
  /// 403 时这一个 bit 就能把范围砍一半：带上 Cookie 还被拒，多半是 UA /
  /// Referer / 签名或站点侧风控；没带上，就是登录态根本没读到。
  bool _lastCookiePresent = false;

  /// 最近一次读到（并带上）的 Cookie 条数。只用于诊断展示，不含名字与值。
  int _lastCookieCount = 0;

  /// 这次带的 Cookie 里有没有 Cloudflare 通行证。
  ///
  /// 只存布尔：判断「缺凭证」还是「有凭证仍被拒」，是两条完全不同的修法。
  bool? _lastClearanceSent;

  /// 最近一次响应是否带 `cf-mitigated`。
  ///
  /// 只认这个头：`server: cloudflare` 太宽——任何挂在 Cloudflare 后面的站点
  /// 普通防盗链 403 都会带它，据此判定「人机验证」会误导排查方向。
  bool _lastCfMitigated = false;

  /// 最近一次请求**实际**带的头名字（不含值）。
  ///
  /// 「已经用最小头了为什么还被拒」这种问题，唯一可信的证据是实际发出去的东西。
  /// 这台 ROM 会过滤第三方日志，所以把它带进错误提示，而不是只在日志里。
  String _lastHeaderNames = '';

  /// 最近一次出站请求的地址。
  ///
  /// 403 时用户只会看到「服务器拒绝」，但拒绝的可能是一条 m3u8、一个分片或
  /// 一个 AES key —— 三者的处理方式完全不同。这里记住最后一个地址，让错误
  /// 提示能说清「哪一步被拒」，不必让用户反复试。
  String _lastRequestUrl = '';

  String get _lastRequestPath {
    final uri = Uri.tryParse(_lastRequestUrl);
    if (uri == null || uri.path.isEmpty) return '';
    final path = uri.path;
    return path.length > 60 ? '…${path.substring(path.length - 60)}' : path;
  }

  /// 输出目录 / 临时目录由调用方注入，方便在主机上跑验证脚本
  final Future<Directory> Function()? resolveOutputDir;
  final Future<Directory> Function()? resolveTempDir;

  /// 按 URL 取该站点在 WebView 里的 Cookie。
  ///
  /// 很多站点的分片需要登录态，只带 Referer 会直接 403；而 WebView 播放
  /// 是通的，因为浏览器自己带 Cookie。注入后用同一身份下载。
  /// 由调用方注入是为了让主机验证脚本能替换成假实现，并且让「读不到」
  /// 可以安全降级成不带 Cookie 的请求。
  final Future<String?> Function(String url)? resolveCookie;

  /// 丢弃某个地址所属站点的 Cookie 缓存，让下一次 [resolveCookie] 回源重读。
  ///
  /// Cloudflare 的 `cf_clearance` 会轮换，90 秒的本地缓存会把重试也锁在旧值上：
  /// 三次重试用的是同一份过期 Cookie，等于白试。403 时先失效缓存再重试，
  /// 才有可能拿到浏览器刚刷新的那一张。
  final void Function(String url)? invalidateCookie;

  /// 走 WebView 上下文代取一次 Cookie（含 HttpOnly 的 `cf_clearance`）。
  ///
  /// 只在「403 + 命中人机验证 + 这次没带上通行证」时调用：`CookieManager` 看不到
  /// HttpOnly，唯一的办法是让 WebView 自己发一次请求，读它的真实出站头。
  /// 由调用方注入，主机端验证脚本可传 null。
  final Future<WebProbeResult?> Function(String url)? captureProbe;

  /// 该 host 改用「与播放器相同的最小请求头」重试。
  ///
  /// 实测依据：浮层播放器只发 `User-Agent` + `Referer` 就能 200 播，
  /// 而下载带 Cookie / `Sec-Fetch-*` / `Accept-Language` 却 403。
  /// 签名直链的 WAF 常把「带 Cookie 的下载」当成非播放器行为拒掉，
  /// 所以 403 先降级到播放器那套头试一次，比去猜凭证便宜得多。
  final Set<String> _minimalHosts = <String>{};

  /// 已经降级过头的 host：提示里要说明「这招试过了」。
  final Set<String> _minimalTriedHosts = <String>{};

  /// 用 Android 自带 HTTP 栈取字节（与 ExoPlayer 同一条链路）。
  ///
  /// 有些站点按 TLS / HTTP 栈识别客户端：同样的头，ExoPlayer 能过、`dart:io` 被拒。
  /// 注入方式是回调，保持本模块纯 Dart；主机端验证脚本传 null 即可。
  final Future<({int status, Uint8List bytes, String url})?> Function(
    String url,
    Map<String, String> headers,
    String? range,
  )? nativeFetch;

  /// 代取失败的说明（按 host 存）：直接进错误提示。
  ///
  /// 这台 ROM 会过滤第三方应用的 `Log.d`，靠日志问用户「卡在哪」不现实，
  /// 所以把诊断写进用户能看到的那句话里。
  final Map<String, String> _captureNotes = <String, String>{};

  /// 代取到的 Cookie，按 host 存，仅本次下载器实例内存活（不落盘、不进任务 JSON）。
  final Map<String, String> _clearanceOverrides = <String, String>{};

  /// 上一个 403 是否值得去代取一次（由 `_onRequestRejected` 标记）。
  String? _captureTarget;

  /// 已经代取过的 host：代取完仍失败时，文案要说「已试过」，不能再劝用户重复同一步。
  final Set<String> _captureTriedHosts = <String>{};

  /// 代取真的拿到 Cookie 的 host。「没拿到」和「拿到仍被拒」要分开说。
  final Set<String> _captureGotCookieHosts = <String>{};

  /// 按任务保存所有在途请求的 CancelToken，暂停/删除时立刻全部中断。
  final Map<String, Set<CancelToken>> _tokens = <String, Set<CancelToken>>{};

  Set<CancelToken> _bag(String id) =>
      _tokens.putIfAbsent(id, () => <CancelToken>{});

  /// 立即中断某任务的全部网络请求（不等待超时、不等待重试）。
  void interrupt(String taskId) {
    final bag = _tokens[taskId];
    if (bag == null) return;
    for (final t in bag.toList()) {
      if (!t.isCancelled) t.cancel('interrupted');
    }
    bag.clear();
  }

  /// 删除某个任务残留的临时分片目录（任务被移除时调用，避免长期占用空间）。
  Future<void> discardParts(String taskId) async {
    try {
      final root = await (resolveTempDir?.call() ??
          Future<Directory>.value(Directory.systemTemp));
      final dir = Directory(joinPath(root.path, 'ss_$taskId'));
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  /// 扫描分片根目录，清掉不属于任何活跃任务的 `ss_*` 目录。
  ///
  /// 正常结束/失败时下载器会自行清理，但进程被强杀、系统回收或旧版本残留
  /// 会留下孤儿目录，里面可能有几十 MB 分片。传入当前仍可能续传的任务 id，
  /// 其余一律删除；返回清理的目录数与释放字节数，供界面展示。
  Future<({int dirs, int bytes})> cleanupStaleParts(
      Set<String> activeTaskIds) async {
    var dirs = 0;
    var bytes = 0;
    try {
      final root = await (resolveTempDir?.call() ??
          Future<Directory>.value(Directory.systemTemp));
      if (!await root.exists()) return (dirs: 0, bytes: 0);
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final name = entity.path.split(Platform.pathSeparator).last;
        if (!name.startsWith('ss_')) continue;
        if (activeTaskIds.contains(name.substring(3))) continue;
        final size = await _directoryBytes(entity);
        try {
          await entity.delete(recursive: true);
          dirs++;
          bytes += size;
        } catch (_) {}
      }
    } catch (_) {}
    return (dirs: dirs, bytes: bytes);
  }

  Future<int> _directoryBytes(Directory dir) async {
    var total = 0;
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        try {
          total += await entity.length();
        } catch (_) {}
      }
    } catch (_) {}
    return total;
  }

  Future<void> run(
    DownloadTask task, {
    void Function()? onUpdate,
    bool Function()? isCanceled,
    int? limitSegments,
    bool resume = false,
  }) async {
    // 任务被删除后，后台协程不得再触发任何 UI 刷新
    void tick() {
      if (!task.detached) onUpdate?.call();
    }

    bool canceled() =>
        task.cancelRequested ||
        task.pauseRequested ||
        task.detached ||
        (isCanceled?.call() ?? false);

    try {
      task.status = TaskStatus.parsing;
      task.error = null;
      if (!resume) {
        task.bytes = 0;
        task.progress = 0;
      }
      tick();

      // 分片组资源：把聚合后的全部分片作为「一个视频」下载并合并
      final segs = task.segments;
      if (segs != null && segs.isNotEmpty) {
        final media = HlsMediaPlaylist(
          segments: <HlsSegment>[
            for (var i = 0; i < segs.length; i++)
              HlsSegment(
                uri: Uri.parse(segs[i]),
                key: null,
                sequence: i,
                duration: 0,
              ),
          ],
          initUri: null,
          isFmp4: false,
          isLive: false,
        );
        await _downloadMedia(task, media, tick, canceled, resume: resume);
        return;
      }

      final playlistUri = Uri.parse(task.url);
      // DASH（.mpd）是 XML 清单，HLS 解析器读不懂：直接说清楚，
      // 别让它落到「播放列表里没有分片」这种误导性错误上。
      if (playlistUri.path.toLowerCase().endsWith('.mpd')) {
        throw Exception('暂不支持下载 DASH（.mpd）视频，可直接在线播放');
      }
      if (isDirectMediaUrl(playlistUri)) {
        await _downloadDirect(task, tick, canceled, resume: resume);
        return;
      }
      // HTTP 可能把 m3u8 重定向到另一个路径/域名，相对分片必须基于
      // 重定向后的最终 URI 解析，否则会全部指向旧地址而 404。
      final first = await _fetchText(task.url, task.referer, task, canceled);
      if (canceled()) throw const CanceledException();
      var text = first.body;
      var base = first.uri;

      if (isMasterPlaylist(text)) {
        final master = parseMasterPlaylistFull(text, base);
        if (master.isEmpty) {
          throw Exception('主播放列表里没有可用码率');
        }
        // 默认仍是最高码率（与旧行为一致）；用户选过档时按持久化的 key 还原，
        // 站点换了列表就退到同高度的最近一档，实在没有才回落最高。
        var chosen = master.pick(task.variantKey) ?? master.variants.first;
        // 每次重新解析都清空旧提示，避免续传后残留上一次的说明
        String? note;
        // 音轨被拆成独立流时，只下视频变体会得到没有声音的成品。
        // 用户明确点了这一档就如实拒绝；只是默认落到这里，则自动退到
        // 第一个音轨内嵌的档位并说明原因——不让「点了下载直接失败」变成
        // 新的坑，也不静默降质。
        if (master.separateAudioFor(chosen).isNotEmpty) {
          final requested = task.variantKey;
          final usable = master.variants
              .where((v) => master.separateAudioFor(v).isEmpty)
              .toList();
          if (requested != null && requested.isNotEmpty) {
            throw Exception(
                '该清晰度把音轨拆成了独立流（${master.separateAudioFor(chosen).first.label}），'
                '当前版本无法与画面合并；请改选内置音轨的清晰度');
          }
          if (usable.isEmpty) {
            throw Exception('这个视频的所有清晰度都把音轨拆成了独立流，'
                '当前版本无法合并音画');
          }
          note = '最高清晰度音轨独立，已自动改用 ${usable.first.label}';
          chosen = usable.first;
        }
        task.variant = chosen.label;
        task.variantKey = chosen.key;
        task.variantNote = note;
        final subs = master.subtitlesFor(chosen);
        task.subtitleNote = subs.isEmpty
            ? null
            : subs.map((s) => s.label).where((s) => s.isNotEmpty).join(' / ');
        final second = await _fetchText(
            chosen.uri.toString(), task.referer, task, canceled);
        if (canceled()) throw const CanceledException();
        text = second.body;
        base = second.uri;
        final media = parseMediaPlaylist(text, base);
        await _downloadMedia(task, media, tick, canceled,
            limitSegments: limitSegments, resume: resume);
      } else {
        final media = parseMediaPlaylist(text, base);
        await _downloadMedia(task, media, tick, canceled,
            limitSegments: limitSegments, resume: resume);
      }
    } on CanceledException {
      if (task.detached) return;
      task.status = task.pauseRequested
          ? TaskStatus.paused
          : TaskStatus.canceled;
      tick();
    } catch (e) {
      if (task.detached) return;
      // 掐断在途请求时底层可能抛 DioException / SocketException，
      // 只要已经标记暂停或取消，就统一收敛到对应状态，不显示为失败。
      if (canceled()) {
        task.status = task.pauseRequested
            ? TaskStatus.paused
            : TaskStatus.canceled;
        tick();
        return;
      }
      task.status = TaskStatus.failed;
      task.error = _friendlyError(e);
      tick();
    } finally {
      _tokens.remove(task.id);
    }
  }

  /// 直链视频（mp4/m4v 等）：写到固定的临时文件，暂停后可用 Range 续传。
  Future<void> _downloadDirect(
    DownloadTask task,
    void Function() tick,
    bool Function() canceled, {
    required bool resume,
  }) async {
    final root = await (resolveTempDir?.call() ??
        Future<Directory>.value(Directory.systemTemp));
    final tmp = Directory(joinPath(root.path, 'ss_${task.id}'));
    await tmp.create(recursive: true);
    final part = File(joinPath(tmp.path, 'direct_${task.id}.part'));
    final meta = File(joinPath(tmp.path, 'direct.meta'));

    var offset = 0;
    String? validator;
    if (resume && await part.exists()) {
      offset = await part.length();
      try {
        validator = (await meta.readAsString()).trim();
      } catch (_) {}
    } else {
      if (await part.exists()) await part.delete();
      if (await meta.exists()) await meta.delete();
    }

    final outDir = await _outputDir();
    final ext = directMediaExtension(Uri.parse(task.url));

    task.status = TaskStatus.downloading;
    task.totalSegments = 1;
    task.doneSegments = 0;
    task.bytes = offset;
    task.progress = 0;
    tick();

    try {
      // 直链同样需要登录态：很多站点把整段视频也放在鉴权后面
      _lastRequestUrl = task.url;
      final host = Uri.tryParse(task.url)?.host.toLowerCase() ?? '';

      Future<Response<ResponseBody>> start() async {
        // 每次重试都重算头：代取到通行证后要立刻生效
        final directHeaders =
            await _headersFor(task.url, task.referer, task.requestHeaders);
        if (offset > 0) directHeaders['Range'] = 'bytes=$offset-';
        // 源文件在暂停期间被替换时，服务端会忽略 Range 返回 200；
        // 现有逻辑随即从头重写，避免把新旧两个版本拼在一起。
        if (offset > 0 && validator != null && validator.isNotEmpty) {
          directHeaders['If-Range'] = validator;
        }
        return _guarded(
          const Duration(minutes: 10),
          (token) => dio.get<ResponseBody>(
            task.url,
            cancelToken: token,
            options: Options(
              responseType: ResponseType.stream,
              headers: directHeaders,
            ),
          ),
          taskId: task.id,
        );
      }

      Response<ResponseBody> response;
      try {
        response = await start();
      } catch (e) {
        // 直链以前完全没有重试：被挑战时只能直接失败。
        // 这里先按 403 诊断走一遍代取，真补到凭证才重试，否则原样抛出。
        if (e is DioException) _onRequestRejected(e, task.url);
        await _captureBeforeRetry();
        if (host.isEmpty || !_clearanceOverrides.containsKey(host)) rethrow;
        response = await start();
      }

      // 服务端不支持 Range 或校验值不匹配时会返回 200，此时从头重写，
      // 保证不会把暂停前后两个不同版本的源文件拼在一起。
      if (offset > 0 && response.statusCode != 206) {
        offset = 0;
        task.bytes = 0;
      }
      // 记下本次响应的校验值，供下次续传做 If-Range。
      final fresh = response.headers.value('etag') ??
          response.headers.value('last-modified');
      try {
        if (fresh != null && fresh.isNotEmpty) {
          await meta.writeAsString(fresh, flush: true);
        } else if (await meta.exists()) {
          await meta.delete();
        }
      } catch (_) {}
      final len = int.tryParse(
          response.headers.value('content-length') ?? '');
      final total = len == null ? null : offset + len;

      final sink = part.openWrite(
          mode: offset > 0 ? FileMode.writeOnlyAppend : FileMode.write);
      var received = offset;
      try {
        // addStream 会等 IOSink 缓冲排空后再取下一块，形成背压。
        // 旧写法在 forEach 里直接 sink.add：网络比磁盘快时所有分片都会
        // 堆在内存里，大文件容易触发 OOM；map 里同步更新进度，语义不变。
        await sink.addStream(
          response.data!.stream
              .takeWhile((_) => !canceled())
              .map<List<int>>((Uint8List chunk) {
            received += chunk.length;
            task.bytes = received;
            task.progress = (total != null && total > 0)
                ? (received / total).clamp(0.0, 1.0)
                : 0;
            tick();
            return chunk;
          }),
        );
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (canceled()) throw const CanceledException();
      // 已知长度时必须收满：连接中途断开却仍走「完成」，会让合并出的文件
      // 看似成功、实际尾部缺失，自动转换还会把坏文件发给用户。
      if (total != null && received != total) {
        throw Exception('下载不完整（已收 $received / $total 字节）');
      }

      final out = _uniqueFile(outDir, task.title, ext);
      try {
        await part.rename(out.path);
      } catch (_) {
        await part.copy(out.path);
      }
      task.bytes = await out.length();
      if (task.bytes == 0) throw Exception('下载内容为空');
      task.doneSegments = 1;
      task.filePath = out.path;
      task.progress = 1;
      task.status = TaskStatus.done;
      tick();
    } finally {
      if (!task.pauseRequested) {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  Future<void> _downloadMedia(
    DownloadTask task,
    HlsMediaPlaylist media,
    void Function() tick,
    bool Function() canceled, {
    int? limitSegments,
    required bool resume,
  }) async {
    if (limitSegments != null && media.segments.length > limitSegments) {
      final kept = media.segments.take(limitSegments).toList();
      media = HlsMediaPlaylist(
        segments: kept,
        initUri: media.initUri,
        isFmp4: media.isFmp4,
        isLive: media.isLive,
        discontinuities: kept.where((s) => s.discontinuityBefore).length,
      );
    }
    if (media.segments.isEmpty) {
      throw Exception('播放列表里没有分片，可能已结束或需要登录');
    }
    // 直播流没有 #EXT-X-ENDLIST：这里只能保存当前窗口的片段。
    // 标记到任务上，让下载页与完成提示明确告知用户，不再假装是完整视频。
    task.isLive = media.isLive;
    // 时间轴中途跳变（插播 / 换源 / 换编码）：直接拼接仍能播，但时间戳会跳，
    // 转 MP4 后时长可能对不上。记下来如实告知，不假装产出了连续时间轴。
    task.discontinuities = media.discontinuities;
    tick();
    // 只实现了 AES-128：SAMPLE-AES / 其他 METHOD 若不解密直接合并，
    // 会产出一个看似成功、实际打不开的文件。提前报错，别静默交付坏文件。
    for (final seg in media.segments) {
      final key = seg.key;
      if (key != null && !key.isAes128) {
        throw Exception('暂不支持 ${key.method} 加密的视频');
      }
    }

    final root = await (resolveTempDir?.call() ??
        Future<Directory>.value(Directory.systemTemp));
    final tmp = Directory(joinPath(root.path, 'ss_${task.id}'));
    await tmp.create(recursive: true);

    try {
      final total = media.segments.length;
      final partPaths = List<String?>.filled(total, null);
      var done = 0;
      var written = 0;

      // 分片按 URL(+密钥) 身份命名：直播 / 滑动窗口 playlist 会变化，
      // 按索引复用会把上一轮的分片错拼进这一轮的视频。
      final expected = <String>{
        for (final seg in media.segments) _partName(seg),
        for (final seg in media.segments)
          if (seg.mapUri != null) _initFileName(seg),
      };
      if (resume) {
        // 清掉不属于当前 playlist 的旧分片（含旧版 part_xxxxxx.bin 和
        // 上次写到一半的 .tmp），既省空间也避免误复用。
        final stale = <File>[];
        try {
          await for (final entity in tmp.list(followLinks: false)) {
            if (entity is! File) continue;
            final name = entity.path.split(Platform.pathSeparator).last;
            if (expected.contains(name)) continue;
            if (name.startsWith('seg_') ||
                name.startsWith('init_') ||
                name.startsWith('part_') ||
                name.endsWith('.tmp')) {
              stale.add(entity);
            }
          }
        } catch (_) {}
        for (final f in stale) {
          try {
            await f.delete();
          } catch (_) {}
        }
        for (var i = 0; i < total; i++) {
          final f = File(joinPath(tmp.path, _partName(media.segments[i])));
          if (await f.exists()) {
            final size = await f.length();
            if (size > 0) {
              partPaths[i] = f.path;
              done++;
              written += size;
            }
          }
        }
      }

      task.status = TaskStatus.downloading;
      task.totalSegments = total;
      task.doneSegments = done;
      task.bytes = written;
      task.progress = total == 0 ? 0 : done / total;
      tick();

      // fMP4 的初始化分片：播放列表里可能有多段 #EXT-X-MAP（换编码 / 插播），
      // 每一段都要取，否则它后面那些分片缺少 moov，拼出来就是坏文件。
      final initPaths = <String, String>{}; // mapKey -> 本地文件
      for (final seg in media.segments) {
        final mapUri = seg.mapUri;
        if (mapUri == null) continue;
        final key = seg.mapKey;
        if (initPaths.containsKey(key)) continue;
        final initFile = File(joinPath(tmp.path, _initFileName(seg)));
        if (resume && await initFile.exists()) {
          initPaths[key] = initFile.path;
          continue;
        }
        final bytes = await _fetchBytes(
          mapUri.toString(),
          task.referer,
          task,
          canceled,
          range: seg.hasMapRange
              ? (offset: seg.mapRangeOffset ?? 0, length: seg.mapRangeLength!)
              : null,
        );
        await _writeAtomic(initFile, bytes);
        initPaths[key] = initFile.path;
      }
      // 合并时按分片切换 init，不存在「只有一个 init」的假设

      final keyCache = <String, Uint8List>{};
      var cursor = 0;

      Future<void> worker() async {
        while (true) {
          if (canceled()) throw const CanceledException();
          final idx = cursor++;
          if (idx >= total) return;
          if (partPaths[idx] != null) continue;

          final seg = media.segments[idx];
          var data = await _fetchBytes(
            seg.uri.toString(),
            task.referer,
            task,
            canceled,
            range: seg.hasRange
                ? (offset: seg.rangeOffset ?? 0, length: seg.rangeLength!)
                : null,
          );

          final key = seg.key;
          if (key != null && key.isAes128 && key.uri != null) {
            final keyId = key.uri.toString();
            var keyBytes = keyCache[keyId];
            if (keyBytes == null) {
              keyBytes = await _fetchBytes(keyId, task.referer, task, canceled);
              if (keyBytes.length != 16) {
                throw Exception('AES 密钥长度异常（${keyBytes.length} 字节）');
              }
              keyCache[keyId] = keyBytes;
            }
            data = aes128Decrypt(
              data,
              keyBytes,
              key.iv ?? ivFromSequence(seg.sequence),
            );
          }

          // 先写 .tmp 再 rename：进程被杀 / 写满时不会留下一个「看起来
          // 完整」的残缺分片被下次续传复用。
          final part = File(joinPath(tmp.path, _partName(seg)));
          await _writeAtomic(part, data);
          partPaths[idx] = part.path;

          done++;
          task.doneSegments = done;
          task.progress = done / total;
          task.bytes += data.length;
          tick();
        }
      }

      await Future.wait<void>(<Future<void>>[
        for (var i = 0; i < concurrency; i++) worker(),
      ]);

      if (canceled()) throw const CanceledException();

      task.status = TaskStatus.merging;
      tick();

      final outDir = await _outputDir();
      final ext = media.isFmp4 ? 'mp4' : 'ts';
      final out = _uniqueFile(outDir, task.title, ext);

      final sink = out.openWrite();
      try {
        String writtenInit = '';
        for (var i = 0; i < media.segments.length; i++) {
          final seg = media.segments[i];
          final key = seg.mapKey;
          // 第一个分片、或 init 变了：先把对应的 init 写进去
          if (key.isNotEmpty && key != writtenInit) {
            final path = initPaths[key];
            if (path != null) {
              await sink.addStream(File(path).openRead());
              writtenInit = key;
            }
          }
          final p = partPaths[i];
          if (p == null) continue;
          await sink.addStream(File(p).openRead());
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      task.bytes = await out.length();
      task.filePath = out.path;
      task.progress = 1;
      task.status = TaskStatus.done;
      tick();
    } finally {
      // 暂停时保留临时分片供续传，其余情况（完成/失败/删除）清理
      if (!task.pauseRequested) {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  /// 分片文件名由「URL + 加密方式 + 密钥 / IV + 字节区间」摘要决定，
  /// 与播放列表中的位置无关。
  ///
  /// 滑动窗口变化后只有同一 URL 的分片才会被续传复用，避免串片；
  /// 字节区间必须进 identity——同一个文件被 #EXT-X-BYTERANGE 切成多段时
  /// URI 完全相同，不带区间会让所有段共用一个文件名，后写的段覆盖前面的。
  String _partName(HlsSegment seg) {
    final key = seg.key;
    final range = seg.hasRange ? '${seg.rangeOffset ?? 0}+${seg.rangeLength}' : '';
    final identity = key == null
        ? '${seg.uri}|$range'
        : '${seg.uri}|$range|${key.method}|${key.uri ?? ''}|'
            '${key.iv?.join(',') ?? seg.sequence}';
    return _hashName('seg', identity, 'bin');
  }

  String _initName(Uri uri) => _hashName('init', uri.toString(), 'mp4');

  /// 分片对应的 init 文件名：同一 URI 的不同字节区间是两份 init
  String _initFileName(HlsSegment seg) => seg.hasMapRange
      ? _hashName('init', '${seg.mapUri}#${seg.mapRangeOffset}+${seg.mapRangeLength}', 'mp4')
      : _initName(seg.mapUri!);

  String _hashName(String prefix, String identity, String ext) {
    final hash =
        SHA256Digest().process(Uint8List.fromList(utf8.encode(identity)));
    final name = StringBuffer(prefix)..write('_');
    for (final b in hash) {
      name.write(b.toRadixString(16).padLeft(2, '0'));
    }
    name.write('.');
    name.write(ext);
    return name.toString();
  }

  /// 原子写：先落 .tmp 再改名，中途被杀只会留下会被续传清理的临时文件，
  /// 不会留下一个「看起来完整」的残缺分片。
  Future<void> _writeAtomic(File target, Uint8List data) async {
    final staging = File('${target.path}.tmp');
    await staging.writeAsBytes(data, flush: true);
    try {
      await staging.rename(target.path);
    } catch (_) {
      await staging.copy(target.path);
      try {
        await staging.delete();
      } catch (_) {}
    }
  }

  /// 所有出站请求共用的头：Referer 供防盗链校验，Cookie 供登录态校验，
  /// 页面带来的 Authorization / X-* 供自定义鉴权校验。
  ///
  /// Cookie 只在内存里按站点取，既不写进任务 JSON 也不进日志；
  /// 取不到就当作匿名请求继续，不让 Cookie 失败挡住整条下载链路。
  Future<Map<String, dynamic>> _headersFor(
    String url,
    String? referer, [
    Map<String, String>? extra,
  ]) async {
    final headers = <String, dynamic>{};
    final reqHost = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    // 精简模式：对齐播放器（只有 UA + Referer），不写 Cookie、不写浏览器特征头。
    // 一旦代取到通行证就退出精简模式——那时凭证才是缺的那一环。
    final minimal = _minimalHosts.contains(reqHost) &&
        !_clearanceOverrides.containsKey(reqHost);
    if (minimal) {
      headers['User-Agent'] = UserAgent.current;
      if (referer != null && referer.isNotEmpty) headers['Referer'] = referer;
      if (extra != null && extra.isNotEmpty) headers.addAll(extra);
      _lastCookiePresent = false;
      _lastCookieCount = 0;
      _lastClearanceSent = null;
      _minimalTriedHosts.add(reqHost);
      _lastHeaderNames = _headerNamesOf(headers);
      return headers;
    }
    // 每次都显式带上当前 UA：BaseOptions 里的是构造时的兜底值，
    // WebView 建好后会换成真实 UA，下载器必须跟着变
    headers['User-Agent'] = UserAgent.current;
    if (referer != null && referer.isNotEmpty) headers['Referer'] = referer;
    // 浏览器等效头（Accept / Accept-Language / Sec-Fetch-*）。
    // 少了这几项，挂在 Cloudflare 后面的站点很容易把请求判成自动化；
    // 页面带来的白名单头在下面合并，仍然优先。
    headers.addAll(browserMediaHeaders(url, referer: referer));
    if (extra != null && extra.isNotEmpty) {
      // 已过白名单，这里直接展开；若与上面的 Referer 同名，白名单已排除该情况
      headers.addAll(extra);
    }
    _lastCookiePresent = false;
    _lastCookieCount = 0;
    _lastClearanceSent = null;
    try {
      final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
      // 代取值优先：那是 WebView 真实发出的那一份，含 HttpOnly 凭证
      final override = _clearanceOverrides[host];
      final cookie = override ?? await resolveCookie?.call(url);
      if (cookie != null && cookie.trim().isNotEmpty) {
        headers['Cookie'] = cookie.trim();
        _lastCookiePresent = true;
        _lastCookieCount = _countCookies(cookie);
        _lastClearanceSent = hasClearanceCookie(cookie);
      }
    } catch (_) {
      // 平台通道不可用（如主机验证脚本未注入）时按匿名请求处理
    }
    _lastHeaderNames = _headerNamesOf(headers);
    return headers;
  }

  /// 头名字列表（小写、排序、不含值）：给错误提示用，不泄露内容。
  String _headerNamesOf(Map<String, dynamic> headers) {
    final names = headers.keys.map((e) => e.toLowerCase()).toList()..sort();
    return names.join(', ');
  }

  /// 数 Cookie 条数。
  ///
  /// 只统计，不记录名字与值：这个模块必须保持纯 Dart（`app_log` 依赖 Flutter，
  /// 引进来会让 `verify_download` / `verify_v042` 编译不过）。条数已经够诊断——
  /// 真正要区分的是「有没有带上」，名字留给需要深挖时由调用方自己看。
  int _countCookies(String raw) {
    return raw
        .split(';')
        .map((e) => e.trim())
        .where((e) => e.contains('='))
        .length;
  }

  /// 返回正文与**重定向后的最终 URI**，供相对分片解析使用。
  Future<({String body, Uri uri})> _fetchText(
    String url,
    String? referer,
    DownloadTask task,
    bool Function() canceled,
  ) async {
    _lastRequestUrl = url;
    try {
    final res = await _withRetry<Response<String>>(
      () async {
        // 每轮重试都重新算头：代取到通行证后，重试必须带上新的 Cookie，
        // 否则三次重试发的还是第一次那份头，代取等于白做
        final headers = await _headersFor(url, referer, task.requestHeaders);
        return _guarded<Response<String>>(
          requestTimeout,
          (token) => dio.get<String>(
            url,
            cancelToken: token,
            options: Options(
              responseType: ResponseType.plain,
              headers: headers,
            ),
          ),
          taskId: task.id,
        );
      },
      shouldStop: canceled,
      onFail: (e) => _onRequestRejected(e, url),
    );
    final body = res.data ?? '';
    if (!body.trimLeft().startsWith('#EXTM3U')) {
      throw Exception('返回内容不是有效的 m3u8');
    }
    // 服务端常用相对 Location，此时 Dio 的 realUri 只是 "/path/index.m3u8"
    // 这类相对引用；必须基于请求地址解析成绝对 URI，否则分片 URL 会缺 host。
    final uri = Uri.parse(url).resolveUri(res.realUri);
    return (body: body, uri: uri);
    } catch (_) {
      // Dio 走不通时，换**播放代理同款**的 dart:io `HttpClient` 再取一次。
      //
      // 依据：同一个地址、同样只剩 UA + Referer 的头，播放代理（`StreamingProxy`
      // 用的就是 HttpClient）能取到，Dio 却一直 403。差异只可能在客户端本身
      // （连接复用、头处理）。这里直接复用「已经跑通」的那套实现，不再调整头。
      final alt = await _fetchTextFallback(url, referer);
      if (alt != null) return alt;
      rethrow;
    }
  }

  /// 最小请求头：只有 UA 与 Referer，与播放器直连时发的一致。
  Map<String, String> _minimalHeaders(String? referer) => <String, String>{
        'User-Agent': UserAgent.current,
        if (referer != null && referer.isNotEmpty) 'Referer': referer,
      };

  /// 兜底取文本：先走 Android 原生栈，再退回 dart:io。
  Future<({String body, Uri uri})?> _fetchTextFallback(
    String url,
    String? referer,
  ) async {
    final headers = _minimalHeaders(referer);
    final native = await _tryNative(url, headers, null);
    if (native != null) {
      if (native.status < 200 || native.status >= 300) return null;
      final body = utf8.decode(native.bytes, allowMalformed: true);
      if (!body.trimLeft().startsWith('#EXTM3U')) return null;
      return (body: body, uri: Uri.parse(native.url));
    }
    return _fetchTextViaClient(url, referer);
  }

  Future<({int status, Uint8List bytes, String url})?> _tryNative(
    String url,
    Map<String, String> headers,
    String? range,
  ) async {
    final fn = nativeFetch;
    if (fn == null) return null;
    try {
      return await fn(url, headers, range);
    } catch (_) {
      return null;
    }
  }

  /// 用与播放代理完全相同的客户端取文本。
  ///
  /// 刻意只设 `User-Agent` / `Referer`：跟代理的 `_applyHeaders` 保持一致，
  /// 不加 Cookie、不加浏览器特征头、不加任何 Dio 的默认头。
  Future<({String body, Uri uri})?> _fetchTextViaClient(
    String url,
    String? referer,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', UserAgent.current);
      if (referer != null && referer.isNotEmpty) {
        req.headers.set('Referer', referer);
      }
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final body = await res.transform(utf8.decoder).join();
      if (!body.trimLeft().startsWith('#EXTM3U')) return null;
      final base = Uri.parse(url);
      final finalUri = res.redirects.isEmpty
          ? base
          : base.resolveUri(res.redirects.last.location);
      return (body: body, uri: finalUri);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// 读取任意二进制资源（分片 / init 段 / 密钥）。
  ///
  /// [range] 对应 #EXT-X-BYTERANGE：同一文件被切成多段时只能取指定字节区间，
  /// 整段下载会把前后几段一起写进同一个分片文件，合并后必然错位。
  Future<Uint8List> _fetchBytes(
    String url,
    String? referer,
    DownloadTask task,
    bool Function() canceled, {
    ({int offset, int length})? range,
  }) async {
    _lastRequestUrl = url;
    try {
    final res = await _withRetry(
      () async {
        final headers = await _headersFor(url, referer, task.requestHeaders);
        if (range != null) {
          headers['Range'] =
              'bytes=${range.offset}-${range.offset + range.length - 1}';
        }
        return _guarded(
          requestTimeout,
          (token) => dio.get<List<int>>(
            url,
            cancelToken: token,
            options: Options(
              responseType: ResponseType.bytes,
              headers: headers,
            ),
          ),
          taskId: task.id,
        );
      },
      shouldStop: canceled,
      onFail: (e) => _onRequestRejected(e, url),
    );
    final data = res.data;
    if (data == null || data.isEmpty) {
      throw Exception('空响应：${Uri.parse(url).pathSegments.lastOrNull ?? url}');
    }
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    // 服务端忽略 Range 返回整个文件时，取错区间会静默产出坏分片，
    // 这里直接报错而不是把整段当成本段写下去。
    if (range != null && bytes.length != range.length) {
      final status = res.statusCode;
      throw Exception(
          '字节区间不符（期望 ${range.length}，收到 ${bytes.length}，状态 $status）');
    }
    return bytes;
    } catch (_) {
      // 分片同理：清单能过、分片却 403 时也走代理同款客户端
      final alt = await _fetchBytesFallback(url, referer, range);
      if (alt != null) return alt;
      rethrow;
    }
  }

  /// 兜底取字节：先走 Android 原生栈，再退回 dart:io。
  Future<Uint8List?> _fetchBytesFallback(
    String url,
    String? referer,
    ({int offset, int length})? range,
  ) async {
    final headers = _minimalHeaders(referer);
    final rangeHeader = range == null
        ? null
        : 'bytes=${range.offset}-${range.offset + range.length - 1}';
    final native = await _tryNative(url, headers, rangeHeader);
    if (native != null) {
      if (native.status < 200 || native.status >= 300) return null;
      if (native.bytes.isEmpty) return null;
      if (range != null && native.bytes.length != range.length) return null;
      return native.bytes;
    }
    return _fetchBytesViaClient(url, referer, range);
  }

  /// 用播放代理同款客户端取字节（含 Range）。
  Future<Uint8List?> _fetchBytesViaClient(
    String url,
    String? referer,
    ({int offset, int length})? range,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', UserAgent.current);
      if (referer != null && referer.isNotEmpty) {
        req.headers.set('Referer', referer);
      }
      if (range != null) {
        req.headers.set(HttpHeaders.rangeHeader,
            'bytes=${range.offset}-${range.offset + range.length - 1}');
      }
      final res = await req.close().timeout(const Duration(seconds: 40));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final builder = BytesBuilder(copy: false);
      await for (final chunk in res) {
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      if (bytes.isEmpty) return null;
      if (range != null && bytes.length != range.length) return null;
      return bytes;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// 解析主播放列表，供下载前选清晰度 / 查看音轨。
  ///
  /// 返回 null 表示这个地址不是主播放列表（单码率或直链），调用方不必弹选择。
  Future<HlsMasterPlaylist?> probeMaster(
    String url, {
    String? referer,
    Map<String, String> headers = const <String, String>{},
  }) async {
    try {
      final requestHeaders = await _headersFor(url, referer, headers);
      final res = await dio
          .get<String>(
            url,
            options: Options(
              responseType: ResponseType.plain,
              headers: requestHeaders,
            ),
          )
          .timeout(const Duration(seconds: 20));
      final body = res.data ?? '';
      if (!body.trimLeft().startsWith('#EXTM3U')) return null;
      if (!isMasterPlaylist(body)) return null;
      final base = Uri.parse(url).resolveUri(res.realUri);
      final master = parseMasterPlaylistFull(body, base);
      return master.isEmpty ? null : master;
    } catch (_) {
      // 探测失败就按「没有可选清晰度」处理，下载仍走原有链路
      return null;
    }
  }

  /// 整体超时保护：dio 的 receiveTimeout 只在两次数据之间计时，
  /// 慢速滴流的连接会一直挂着，这里用 CancelToken 兜住。
  Future<T> _guarded<T>(
    Duration limit,
    Future<T> Function(CancelToken token) request, {
    String? taskId,
  }) {
    final token = CancelToken();
    final bag = taskId == null ? null : _bag(taskId);
    bag?.add(token);
    return request(token).timeout(limit, onTimeout: () {
      token.cancel('timeout');
      throw TimeoutException('请求超时（${limit.inSeconds}s）', limit);
    }).whenComplete(() {
      bag?.remove(token);
    });
  }

  /// 真正去代取一次，并把结果挂到 host 上；失败就保持原样，让重试按旧身份跑。
  Future<void> _captureBeforeRetry() async {
    final target = _captureTarget;
    _captureTarget = null;
    final capture = captureProbe;
    if (target == null || capture == null) return;
    final host = Uri.tryParse(target)?.host.toLowerCase() ?? '';
    if (host.isEmpty || _clearanceOverrides.containsKey(host)) return;
    try {
      _captureTriedHosts.add(host);
      final probe = await capture(target);
      if (probe == null) {
        _captureNotes[host] = '代取通道不可用';
        return;
      }
      final cookie = probe.cookie;
      if (cookie == null || cookie.trim().isEmpty) {
        _captureNotes[host] = probe.note;
        return;
      }
      _clearanceOverrides[host] = cookie.trim();
      _captureGotCookieHosts.add(host);
    } catch (_) {
      // 代取失败不是致命错误：按原身份重试，失败照常报给用户
    }
  }

  Future<T> _withRetry<T>(
    Future<T> Function() fn, {
    int attempts = 3,
    bool Function()? shouldStop,
    void Function(Object error)? onFail,
  }) async {
    Object? last;
    for (var i = 0; i < attempts; i++) {
      if (shouldStop?.call() ?? false) throw const CanceledException();
      try {
        return await fn();
      } catch (e) {
        if (e is CanceledException || (shouldStop?.call() ?? false)) {
          throw const CanceledException();
        }
        last = e;
        onFail?.call(e);
        // 先补凭证再重试：顺序反了就白跑一次
        await _captureBeforeRetry();
        await Future<void>.delayed(Duration(milliseconds: 400 * (i + 1)));
      }
    }
    throw last ?? Exception('请求失败');
  }

  /// 403 时先让 Cookie 缓存失效，下一次重试才会回源重读。
  ///
  /// 站点的人机验证 Cookie（`cf_clearance` 之类）轮换很快，而本地缓存有 90 秒；
  /// 不失效的话，三次重试实际都在用同一份旧凭证，全部失败。
  void _onRequestRejected(Object error, String url) {
    if (error is! DioException) return;
    // 先把能说明「为什么被拒」的响应特征留下来，错误文案要用
    _lastCfMitigated = error.response?.headers.value('cf-mitigated') != null;
    if (error.response?.statusCode != 403) return;
    invalidateCookie?.call(url);
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    if (host.isEmpty) return;
    // 第一步先降级到播放器那套最小请求头：这一步最便宜，也最可能直接解决
    if (!_minimalHosts.contains(host)) {
      _minimalHosts.add(host);
      return;
    }
    // 已经是精简头还被拒：这才轮到「缺凭证」的假设，去 WebView 代取一次
    final missingClearance = _lastCookiePresent && (_lastClearanceSent == false);
    final noCookieAtAll = !_lastCookiePresent;
    if ((missingClearance || noCookieAtAll) && captureProbe != null) {
      if (!_clearanceOverrides.containsKey(host)) _captureTarget = url;
    }
  }

  Future<Directory> _outputDir() async {
    // 目录来源优先级：调用方注入 > 环境变量 > 系统临时目录下的默认子目录。
    // 不再依赖当前工作目录或项目位置，注入方式保持原有接口不变。
    final injected = await resolveOutputDir?.call();
    final dir = injected ??
        await defaultOutputDirectory(
            configured: readEnvPath(kDownloadDirEnv));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  File _uniqueFile(Directory dir, String title, String ext) {
    var safe = title.replaceAll(RegExp(r'[\\/:*?"<>|\r\n]+'), '_').trim();
    if (safe.isEmpty) safe = 'video';
    if (safe.length > 60) safe = safe.substring(0, 60);
    final stamp = DateTime.now();
    final suffix = '${stamp.year}'
        '${stamp.month.toString().padLeft(2, '0')}'
        '${stamp.day.toString().padLeft(2, '0')}_'
        '${stamp.hour.toString().padLeft(2, '0')}'
        '${stamp.minute.toString().padLeft(2, '0')}';
    var file = File(joinPath(dir.path, '${safe}_$suffix.$ext'));
    var n = 1;
    while (file.existsSync()) {
      file = File(joinPath(dir.path, '${safe}_${suffix}_$n.$ext'));
      n++;
    }
    return file;
  }

  /// 从被拒响应里取一小段可读文本。
  ///
  /// CDN 的 403 往往带一句说明（`referer not allowed`、`token expired`、
  /// `hotlink protection`），比任何猜测都准。这里只取前 120 字、去掉标签，
  /// 二进制响应则只保留可打印 ASCII，避免把乱码塞进提示里。
  String? _responseSnippet(Object? data) {
    String? text;
    if (data is String) {
      text = data;
    } else if (data is List<int>) {
      text = String.fromCharCodes(
        data.take(200).where((b) => b == 10 || (b >= 32 && b < 127)),
      );
    }
    if (text == null) return null;
    final cleaned = text
        // style / script 的内容不是标签，光去标签会留下一大段 CSS 噪声
        .replaceAll(
          RegExp(r'<(script|style)[^>]*>[\s\S]*?</\1>', caseSensitive: false),
          ' ',
        )
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty) return null;
    return cleaned.length > 120 ? '${cleaned.substring(0, 120)}…' : cleaned;
  }

  /// 是否被 Cloudflare 一类的人机验证拦下。
  ///
  /// 这类 403 与「没登录」「防盗链」不是一回事：页面是挑战页，重试和改 Cookie
  /// 都未必有用，提示必须说清楚，否则用户会一直在网页里反复播放。
  bool _isBotChallenge(DioException e) {
    // 先用 _onRequestRejected 留下的响应特征：正文可能被截断或换成二进制，
    // 头里的 `cf-mitigated` 是更早、更可靠的证据
    if (_lastCfMitigated) return true;
    final response = e.response;
    final headers = response?.headers;
    if (headers != null) {
      // 只看明确的挑战信号。以前「server 含 cloudflare 就算被挑战」是误判：
      // 任何挂在 Cloudflare 后面的站点，普通防盗链 403 都会带这个头，
      // 结果把「多带了 Cookie 被拒」误诊成「人机验证」。
      if (headers.value('cf-mitigated') != null) return true;
    }
    final snippet = _responseSnippet(response?.data) ?? '';
    if (snippet.contains('Attention Required') ||
        snippet.contains('Just a moment') ||
        snippet.contains('cf-browser-verification') ||
        snippet.contains('__cf_chl')) {
      return true;
    }
    // 有些站点把挑战页包在别的壳里，靠原始 HTML 里的标记兜底
    final raw = response?.data is String ? response!.data as String : '';
    return raw.contains('__cf_chl') || raw.contains('cf-chl-');
  }

  String _friendlyError(Object e) {
    if (e is DioException) {
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.sendTimeout:
          return '网络超时，请检查网络或换一个源';
        case DioExceptionType.connectionError:
          return '连接失败：目标站点不可达';
        case DioExceptionType.badResponse:
          final code = e.response?.statusCode;
          final where = _lastRequestPath;
          final at = where.isEmpty ? '' : '（$where）';
          final detail = _responseSnippet(e.response?.data);
          final tail = detail == null ? '' : ' · 服务端原文：$detail';
          if (code == 401 || code == 403) {
            final challenged = _isBotChallenge(e);
            final host = Uri.tryParse(_lastRequestUrl)?.host ?? '';
            final pageHost = PageCookieProbe.lastHost;
            final crossHost = pageHost.isNotEmpty &&
                host.isNotEmpty &&
                pageHost != host.toLowerCase();
            final diag = describeAuthFailure(
              cookieSent: _lastCookiePresent,
              cookieCount: _lastCookieCount,
              // 跨域时 lengthFor 会返回 null（那是页面那个域的读数），
              // 但文案要靠 crossHost 说清「是跨域」，不能含糊成「读数不可用」
              pageCookieLength: PageCookieProbe.lengthFor(host),
              challenged: challenged,
              clearanceSent: _lastClearanceSent,
              captureTried: _captureTriedHosts.contains(host.toLowerCase()),
              captureNote: _captureNotes[host.toLowerCase()] ?? '',
              minimalTried: _minimalTriedHosts.contains(host.toLowerCase()),
              headerNames: _lastHeaderNames,
              captureGotCookie:
                  _captureGotCookieHosts.contains(host.toLowerCase()),
              crossHost: crossHost,
            );
            // 诊断只增不改：文案仍以用户能照做的事开头，细节放后半段
            if (challenged) {
              // master 播放列表常是站点的入口页，规则比实际 media 播放列表更严。
              // 但换源只能绕过「入口页更严」这一层，Cookie 缺失这条仍在——
              // 所以措辞不能写成「换那条就能过」。
              final isMaster = _lastRequestUrl.toLowerCase().contains('playlist');
              final alt = isMaster
                  ? '换 video.m3u8 只能绕过入口页更严的规则，Cookie 这条仍然存在；'
                  : '';
              return '被站点的 Cloudflare 人机验证拦下$at（${diag.cookieLabel}）。'
                  '$alt${diag.hint}';
            }
            return '服务器返回 $code$at（${diag.cookieLabel}）：${diag.hint}$tail';
          }
          return '服务器返回 $code$at，可能需要 Referer 或链接已失效$tail';
        default:
          return '网络错误：${e.message ?? e.type.name}';
      }
    }
    final msg = e.toString().replaceFirst('Exception: ', '');
    return msg.length > 160 ? '${msg.substring(0, 160)}…' : msg;
  }
}

/// HLS AES-128：CBC 模式 + PKCS7 填充
Uint8List aes128Decrypt(Uint8List data, Uint8List key, Uint8List iv) {
  final usable = data.length - (data.length % 16);
  if (usable == 0) return data;

  final cipher = CBCBlockCipher(AESEngine())
    ..init(false, ParametersWithIV<KeyParameter>(KeyParameter(key), iv));

  final out = Uint8List(usable);
  for (var offset = 0; offset < usable; offset += 16) {
    cipher.processBlock(data, offset, out, offset);
  }

  final pad = out.isEmpty ? 0 : out.last;
  if (pad > 0 && pad <= 16 && pad <= out.length) {
    return Uint8List.sublistView(out, 0, out.length - pad);
  }
  return out;
}

extension _FirstOrNull<T> on List<T> {
  T? get lastOrNull => isEmpty ? null : last;
}

final RegExp _directMediaPattern =
    RegExp(r'\.(mp4|m4v|mov|webm|mkv)(?:[?#]|$)', caseSensitive: false);

bool isDirectMediaUrl(Uri uri) => _directMediaPattern.hasMatch(uri.path);

String directMediaExtension(Uri uri) {
  final m = _directMediaPattern.firstMatch(uri.path);
  return m?.group(1)?.toLowerCase() ?? 'mp4';
}
