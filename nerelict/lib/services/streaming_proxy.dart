import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'media_source.dart';
import 'app_log.dart';
import 'app_paths.dart';
import 'cookie_store.dart';
import 'header_policy.dart';
import 'playlist_rewriter.dart';

/// download_cache 层：本地 HTTP 代理实现的边下边播缓存。
///
/// 播放器指向 127.0.0.1 的代理地址，代理回源 playlist / 分片时把分片
/// 落到应用私有缓存目录；下次播放同一地址直接命中本地文件。
/// 默认关闭（设置项），关闭时播放链路完全走原来的直连地址。
/// 缓存上限默认 256MB，可在设置里调整；启动时按上限裁剪旧分片，
/// 避免和「下载完成导出」双份占空间。占用与清理对设置页公开。
class StreamingProxy {
  StreamingProxy._();

  static final StreamingProxy instance = StreamingProxy._();

  static const int kMaxCacheBytes = 256 * 1024 * 1024;
  static const String kCacheDirName = 'nerelict_play_cache';
  static const String kLegacyCacheDirName = 'ma8_play_cache';

  HttpServer? _server;
  int _port = 0;
  Directory? _cacheDir;
  int _writes = 0;
  int _cacheSeq = 0;
  int _maxCacheBytes = kMaxCacheBytes;
  bool _legacyPurged = false;

  /// 内存里合成的播放列表（分片组直接播放用）：id -> m3u8 文本。
  /// 只放最近几份，播放器取完就不需要了，不落盘。
  final Map<String, String> _localPlaylists = <String, String>{};

  /// 回源用的复用客户端。
  ///
  /// 以前每个分片请求都 `HttpClient()` 建一个再 `close(force: true)`：HLS 每 4~10 秒
  /// 就来一个分片，等于每次都重做 TCP + TLS 握手甚至重新解析 DNS。边下载边播放时
  /// 下载器本来就在抢连接与 CPU，这一串握手会直接反映成掉帧与首帧变慢。
  /// 连接池交给 dart:io 自己管，空闲 20 秒自动回收。
  HttpClient? _upstream;

  HttpClient _upstreamClient() => _upstream ??= HttpClient()
    ..connectionTimeout = const Duration(seconds: 8)
    ..idleTimeout = const Duration(seconds: 20)
    ..autoUncompress = true;

  /// 最近一次回源被拒的摘要（状态码 + Content-Type + 路径）。
  ///
  /// 播放器只会报一句 `Source error`，真正的原因在代理这一层：可能是 m3u8
  /// 被 403、分片防盗链、或者站点回了一个 HTML 防盗页。记下来供错误卡片附带，
  /// 用户复现一次就能看到「是哪一步、被什么拒绝」。
  String? lastUpstreamError;

  void _noteUpstreamError(int code, String? type, String target) {
    final path = Uri.tryParse(target)?.path ?? target;
    final short = path.length > 48 ? '…${path.substring(path.length - 48)}' : path;
    final ct = (type == null || type.isEmpty) ? '' : ' ${type.split(';').first}';
    lastUpstreamError = '$code$ct（$short）';
    logD('Proxy', 'upstream ${lastUpstreamError!}');
  }

  bool get running => _server != null;

  /// 取 Cookie 的方式。默认复用 WebView 的登录态；主机端测试可替换成假实现。
  ///
  /// 播放代理同样需要登录态：缓存关闭时 ExoPlayer 直连、缓存开启时走本代理，
  /// 如果代理不带 Cookie，会出现「关缓存能播、开缓存报错」的割裂。
  Future<String?> Function(String url) cookieResolver =
      (url) => CookieStore.instance.cookiesFor(url);

  int get maxCacheBytes => _maxCacheBytes;

  set maxCacheBytes(int value) =>
      _maxCacheBytes = value > 0 ? value : kMaxCacheBytes;

  /// 换名前的缓存目录：首次访问缓存时一次性删掉，避免旧分片白占空间。
  Future<void> _purgeLegacyDir() async {
    if (_legacyPurged) return;
    _legacyPurged = true;
    try {
      final base = await getTemporaryDirectory();
      final legacy = Directory(joinPath(base.path, kLegacyCacheDirName));
      if (await legacy.exists()) await legacy.delete(recursive: true);
    } catch (_) {}
  }

  Future<Directory> _cacheDirectory() async {
    final base = await getTemporaryDirectory();
    return Directory(joinPath(base.path, kCacheDirName));
  }

  Future<Directory> _dir() async {
    final dir = _cacheDir;
    if (dir != null) return dir;
    await _purgeLegacyDir();
    final created = await _cacheDirectory();
    if (!await created.exists()) await created.create(recursive: true);
    _cacheDir = created;
    await trimCache();
    return created;
  }

  Future<HttpServer> _ensureServer() async {
    final existing = _server;
    if (existing != null) return existing;
    await _dir();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _port = server.port;
    _server = server;
    server.listen(_handle, onError: (_) {});
    return server;
  }

  /// 返回交给播放器的本地地址；失败时抛错，由调用方回退到直连。
  Future<String> playbackUrl(MediaSource source) async {
    final server = await _ensureServer();
    _port = server.port;
    final path = source.kind == MediaKind.hls ? '/hls' : '/raw';
    final token = _registerHeaders(source.url, source.customHeaders);
    if (token.isNotEmpty) {
      logD('Proxy', 'pass ${source.customHeaders.length} auth headers');
    }
    return _proxyUrl(path, source.url, source.referer, h: token);
  }

  /// 把「只嗅探到分片」的一组地址合成一份播放列表，交给播放器边下边播。
  ///
  /// 播放列表本身在内存里（不落盘、不写公共目录），分片仍走本代理，
  /// 因此 Cookie / Referer / 鉴权头与在线播放一致，不会因为「代理只认识 m3u8」而丢鉴权。
  ///
  /// 返回 null 表示这组分片不适合播放（太少，或含 fMP4 分片但没有 init）。
  Future<String?> playbackUrlForSegments(
    List<String> segments, {
    String? referer,
    Map<String, String> headers = const <String, String>{},
  }) async {
    final usable = segments
        .where((u) => u.startsWith('http'))
        .where((u) => !u.contains('.m4s') && !u.contains('.mp4'))
        .toList();
    // 少于 2 段时不值得起播放器；fMP4 分片缺 init，拼出来播不了
    if (usable.length < 2) return null;
    final server = await _ensureServer();
    _port = server.port;
    final id = stableCacheKey(usable.join('|')).substring(0, 16);
    final token = _registerHeaders(usable.first, headers);
    _localPlaylists[id] = _buildSegmentPlaylist(usable, referer, token);
    while (_localPlaylists.length > 8) {
      _localPlaylists.remove(_localPlaylists.keys.first);
    }
    final query = <String>[
      if (referer != null && referer.isNotEmpty)
        'r=${Uri.encodeComponent(referer)}',
      if (token.isNotEmpty) 'h=$token',
    ].join('&');
    // 文件名后缀必须能被 ExoPlayer 认成 HLS
    return 'http://127.0.0.1:$_port/local/$id.m3u8'
        '${query.isEmpty ? '' : '?$query'}';
  }

  /// 合成 VOD 播放列表：分片地址全部改写成本代理地址。
  ///
  /// 时长未知，统一给 6 秒：只影响进度条估算与拖动精度，不影响播放。
  String _buildSegmentPlaylist(
    List<String> segments,
    String? referer,
    String headerToken,
  ) {
    final b = StringBuffer()
      ..writeln('#EXTM3U')
      ..writeln('#EXT-X-VERSION:3')
      ..writeln('#EXT-X-PLAYLIST-TYPE:VOD')
      ..writeln('#EXT-X-TARGETDURATION:6')
      ..writeln('#EXT-X-MEDIA-SEQUENCE:0');
    for (final seg in segments) {
      b.writeln('#EXTINF:6.000,');
      b.writeln(_proxyUrl('/seg', seg, referer, h: headerToken));
    }
    b.writeln('#EXT-X-ENDLIST');
    return b.toString();
  }

  /// 鉴权头的内存登记表：token -> 头集合。
  ///
  /// 为什么不把头塞进 URL：`Authorization` 常是几百字节的 JWT，放 query 会
  /// 让地址膨胀、还会被截图和日志带出去。这里只把由地址派生的短 token 写进
  /// URL，代理回源时按 token 取出完整的头。LRU 上限 120 组，够覆盖当前
  /// 会话里同时存在的播放任务。
  final Map<String, Map<String, String>> _headersByToken =
      <String, Map<String, String>>{};
  final List<String> _headerOrder = <String>[];

  static const int _kMaxHeaderTokens = 120;

  /// 登记一批鉴权头，返回可写进代理 URL 的 token；没有可透传的头时返回空串。
  String _registerHeaders(String url, Map<String, String> headers) {
    final clean = HeaderPolicy.sanitize(headers);
    if (clean.isEmpty) return '';
    final token = HeaderPolicy.tokenFor(url);
    _headersByToken[token] = clean;
    _headerOrder
      ..remove(token)
      ..add(token);
    while (_headerOrder.length > _kMaxHeaderTokens) {
      _headersByToken.remove(_headerOrder.removeAt(0));
    }
    return token;
  }

  String _proxyUrl(
    String path,
    String target,
    String? referer, {
    String h = '',
  }) {
    final u = Uri.encodeComponent(target);
    final r = Uri.encodeComponent(referer ?? '');
    final extra = h.isEmpty ? '' : '&h=$h';
    // 路径末尾带可推断的文件名，否则 ExoPlayer 会把 /hls 当成渐进式流
    return 'http://127.0.0.1:$_port$path${proxyPathSuffix(path, target)}'
        '?u=$u&r=$r$extra';
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final q = request.uri.queryParameters;
      final target = q['u'];
      // 内存合成的播放列表没有远端地址，直接按 id 取
      if (request.uri.path.startsWith('/local')) {
        await _localPlaylist(request);
        return;
      }
      if (target == null || target.isEmpty) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }
      final referer = (q['r'] ?? '').isEmpty ? null : q['r'];
      // 鉴权头只以 token 形式出现在 URL 里，真实值留在内存表中
      final headerToken = q['h'] ?? '';
      // 代理只回源 http(s)，不让设备内其它页面借 127.0.0.1 探测本地文件
      final scheme = Uri.tryParse(target)?.scheme.toLowerCase() ?? '';
      if (scheme != 'http' && scheme != 'https') {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }
      final route = request.uri.path;
      if (route.startsWith('/local')) {
        await _localPlaylist(request);
      } else if (route.startsWith('/hls')) {
        await _playlist(request, target, referer, headerToken);
      } else if (route.startsWith('/seg')) {
        await _binary(request, target, referer,
            cache: true, h: headerToken);
      } else if (route.startsWith('/key') || route.startsWith('/raw')) {
        await _binary(request, target, referer,
            cache: false, h: headerToken);
      } else {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      }
    } catch (_) {
      try {
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
      } catch (_) {}
    }
  }

  /// 返回内存里合成的播放列表（分片组直接播放）。
  Future<void> _localPlaylist(HttpRequest request) async {
    final name = request.uri.pathSegments.isEmpty
        ? ''
        : request.uri.pathSegments.last;
    final id = name.split('.').first;
    final body = _localPlaylists[id];
    if (body == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final bytes = utf8.encode(body);
    request.response.statusCode = 200;
    request.response.headers
        .set(HttpHeaders.contentTypeHeader, 'application/vnd.apple.mpegurl');
    request.response.headers.set(HttpHeaders.contentLengthHeader, bytes.length);
    request.response.add(bytes);
    await request.response.close();
  }

  /// 回源 m3u8 并把其中所有 URI 改写成本代理地址。
  Future<void> _playlist(
    HttpRequest request,
    String target,
    String? referer,
    String headerToken,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..autoUncompress = true;
    try {
      final requested = Uri.parse(target);
      final req = await client.getUrl(requested);
      await _applyHeaders(req, referer, target, headerToken);
      req.followRedirects = true;
      req.maxRedirects = 8;
      final response = await req.close().timeout(const Duration(seconds: 12));
      final body = await response.fold<BytesBuilder>(
          BytesBuilder(copy: false), (b, chunk) => b..add(chunk));
      final text = decodePlaylistText(body.takeBytes());
      if (response.statusCode != 200) {
        _noteUpstreamError(
            response.statusCode, response.headers.contentType?.value, target);
        request.response.statusCode = response.statusCode;
        await request.response.close();
        return;
      }
      // 服务端 302 到另一路径/域名后，相对分片必须基于最终 URI 解析
      final base = finalUriAfterRedirects(requested, response.redirects);
      final rewritten = rewritePlaylistUris(
        text,
        base,
        referer,
        // 分片与 key 沿用同一个 token：鉴权头对一个 host 通常整体有效，
        // 分片换到 CDN 域名时也照样带上（无效会被服务端忽略）
        (path, abs, ref) => _proxyUrl(path, abs, ref, h: headerToken),
      );
      final bytes = utf8.encode(rewritten);
      request.response.statusCode = 200;
      request.response.headers
          .set(HttpHeaders.contentTypeHeader, 'application/vnd.apple.mpegurl');
      request.response.headers.set(HttpHeaders.contentLengthHeader, bytes.length);
      request.response.add(bytes);
      await request.response.close();
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _binary(
    HttpRequest request,
    String target,
    String? referer, {
    required bool cache,
    String h = '',
  }) async {
    final range = request.headers.value(HttpHeaders.rangeHeader);
    // Range / HEAD 请求必须保留字节范围语义，只有普通 GET 才能命中整文件缓存；
    // 否则播放器对已缓存分片发 Range 会收到 200 + 全量数据。
    final canCache = cache && request.method == 'GET' && range == null;
    final cacheFile = canCache
        ? File(joinPath((await _dir()).path, stableCacheKey(target)))
        : null;

    if (cacheFile != null && await cacheFile.exists()) {
      final bytes = await cacheFile.readAsBytes();
      // 0 字节缓存是上一次「200 + 空 body」的防盗响应留下的。继续命中它，
      // 等于把一个偶发的错误永久化（表现为「这个视频再也打不开了」），
      // 所以直接删掉重新回源。
      if (bytes.isNotEmpty) {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers
            .set(HttpHeaders.contentTypeHeader, cachedContentType(target));
        request.response.headers
            .set(HttpHeaders.contentLengthHeader, bytes.length);
        request.response.headers.set('X-Nerelict-Cache', 'HIT');
        request.response.add(bytes);
        await request.response.close();
        return;
      }
      try {
        await cacheFile.delete();
      } catch (_) {}
    }

    final client = _upstreamClient();
    try {
      final req = await client.getUrl(Uri.parse(target));
      await _applyHeaders(req, referer, target, h);
      if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
      final response = await req.close().timeout(const Duration(seconds: 20));

      request.response.statusCode = response.statusCode;
      final type = response.headers.contentType?.value;
      if (response.statusCode >= 400) {
        _noteUpstreamError(response.statusCode, type, target);
      }
      if (type != null) {
        request.response.headers.set(HttpHeaders.contentTypeHeader, type);
      }
      final contentRange = response.headers.value('content-range');
      if (contentRange != null) {
        request.response.headers.set('content-range', contentRange);
      }

      if (request.method == 'HEAD') {
        await request.response.close();
        return;
      }

      if (cacheFile != null && response.statusCode == HttpStatus.ok) {
        final builder = BytesBuilder(copy: false);
        await response.fold<BytesBuilder>(builder, (b, chunk) => b..add(chunk));
        final Uint8List bytes = builder.takeBytes();
        request.response.headers
            .set(HttpHeaders.contentLengthHeader, bytes.length);
        request.response.headers.set('X-Nerelict-Cache', 'MISS');
        request.response.add(bytes);
        await request.response.close();
        // 防盗链常见手法是回 200 + 空 body 或一段 HTML，状态码看着正常。
        // 这种响应一旦落进缓存，之后每次播放都命中坏文件，所以先校验再写。
        if (_cacheWorthy(bytes, type)) {
          try {
            // 并发 MISS 同一分片时各自写独立暂存文件，再原子改名，避免交错写坏缓存
            final staging =
                File('${cacheFile.path}.${_cacheSeq++}.tmp');
            await staging.writeAsBytes(bytes, flush: false);
            try {
              await staging.rename(cacheFile.path);
            } catch (_) {
              await staging.copy(cacheFile.path);
              await staging.delete();
            }
            _writes++;
            if (_writes % 40 == 0) await trimCache();
          } catch (_) {}
        }
      } else {
        await request.response.addStream(response);
        await request.response.close();
      }
    } finally {
      // 共享连接池**不能**在这里 close：每片一次握手正是要消掉的成本。
      // 空闲连接由 `idleTimeout`（20 秒）回收，进程内整体关闭走 `stop()`。
    }
  }

  /// 这份响应值不值得落进播放缓存。
  ///
  /// 只挡两种明确有害的：空响应、以及 HTML（防盗页 / 错误页 / 登录跳转）。
  /// 二进制分片不做内容嗅探——TS、fMP4、加密分片的首字节都不一样，
  /// 判断错了会误伤正常缓存。
  bool _cacheWorthy(Uint8List bytes, String? contentType) {
    if (bytes.isEmpty) return false;
    final ct = contentType?.toLowerCase() ?? '';
    if (ct.contains('text/html') || ct.contains('application/xhtml')) {
      return false;
    }
    // 有些 CDN 不带 Content-Type，直接回一段 <html>。只看开头一个字节即可：
    // TS 是 0x47、fMP4 是长度前缀、m3u8 是 #EXTM3U，都不会以 '<' 开头。
    if (bytes.length >= 5) {
      final head = String.fromCharCodes(bytes.take(16)).trimLeft();
      if (head.startsWith('<')) return false;
    }
    return true;
  }

  Future<void> _applyHeaders(
    HttpClientRequest req,
    String? referer,
    String url, [
    String headerToken = '',
  ]) async {
    req.headers.set('User-Agent', MediaSource.userAgent);
    if (referer != null && referer.startsWith('http')) {
      req.headers.set('Referer', referer);
    }
    // 这里**刻意不加**浏览器特征头（`Accept` / `Accept-Language` / `Sec-Fetch-*`）。
    //
    // 播放是已经跑通的路径：站点接受「UA + Referer + Cookie」这套最小身份。
    // 0.4.6 为了「让下载看起来像浏览器」曾在这里也加了一份，结果把本来能播的
    // HLS 站点打回 403——拿可用功能做实验，方向错了。浏览器特征头只留给下载器。
    // 页面侧带来的鉴权头仍然照转（Authorization / X-* 等白名单项）。
    final extra = headerToken.isEmpty ? null : _headersByToken[headerToken];
    if (extra != null) {
      extra.forEach((name, value) => req.headers.set(name, value));
    }
    try {
      final cookie = await cookieResolver(url);
      if (cookie != null && cookie.trim().isNotEmpty) {
        req.headers.set(HttpHeaders.cookieHeader, cookie.trim());
      }
    } catch (_) {
      // 平台通道不可用时按匿名请求继续，不让播放整条链路因此失败
    }
  }

  /// 当前缓存占用字节数（供设置页展示）；顺带清理换名前的旧目录。
  Future<int> cacheSizeBytes() async {
    try {
      await _purgeLegacyDir();
      final dir = await _cacheDirectory();
      if (!await dir.exists()) return 0;
      var total = 0;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        try {
          total += (await entity.stat()).size;
        } catch (_) {}
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// 清空播放缓存并返回释放的字节数；已打开的响应流不受影响。
  Future<int> clearCache() async {
    final before = await cacheSizeBytes();
    try {
      final dir = await _cacheDirectory();
      if (!await dir.exists()) return 0;
      await for (final entity in dir.list(followLinks: false)) {
        try {
          await entity.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
    _cacheDir = null;
    return before;
  }

  /// 按修改时间从新到旧保留，超过上限的旧分片删除。
  Future<void> trimCache() async {
    try {
      final dir = await _cacheDirectory();
      if (!await dir.exists()) return;
      final files = await dir
          .list()
          .where((e) => e is File)
          .cast<File>()
          .toList();
      final stats = <MapEntry<File, FileStat>>[];
      for (final f in files) {
        stats.add(MapEntry(f, await f.stat()));
      }
      stats.sort((a, b) => b.value.modified.compareTo(a.value.modified));
      var total = 0;
      for (final e in stats) {
        total += e.value.size;
        if (total > _maxCacheBytes) {
          try {
            await e.key.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _upstream?.close(force: true);
    _upstream = null;
  }
}
