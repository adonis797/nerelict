import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'media_source.dart';
import 'app_paths.dart';
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

  bool get running => _server != null;

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
    return _proxyUrl(path, source.url, source.referer);
  }

  String _proxyUrl(String path, String target, String? referer) {
    final u = Uri.encodeComponent(target);
    final r = Uri.encodeComponent(referer ?? '');
    // 路径末尾带可推断的文件名，否则 ExoPlayer 会把 /hls 当成渐进式流
    return 'http://127.0.0.1:$_port$path${proxyPathSuffix(path, target)}'
        '?u=$u&r=$r';
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final q = request.uri.queryParameters;
      final target = q['u'];
      if (target == null || target.isEmpty) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }
      final referer = (q['r'] ?? '').isEmpty ? null : q['r'];
      // 代理只回源 http(s)，不让设备内其它页面借 127.0.0.1 探测本地文件
      final scheme = Uri.tryParse(target)?.scheme.toLowerCase() ?? '';
      if (scheme != 'http' && scheme != 'https') {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }
      final route = request.uri.path;
      if (route.startsWith('/hls')) {
        await _playlist(request, target, referer);
      } else if (route.startsWith('/seg')) {
        await _binary(request, target, referer, cache: true);
      } else if (route.startsWith('/key') || route.startsWith('/raw')) {
        await _binary(request, target, referer, cache: false);
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

  /// 回源 m3u8 并把其中所有 URI 改写成本代理地址。
  Future<void> _playlist(
    HttpRequest request,
    String target,
    String? referer,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..autoUncompress = true;
    try {
      final requested = Uri.parse(target);
      final req = await client.getUrl(requested);
      _applyHeaders(req, referer);
      req.followRedirects = true;
      req.maxRedirects = 8;
      final response = await req.close().timeout(const Duration(seconds: 12));
      final body = await response.fold<BytesBuilder>(
          BytesBuilder(copy: false), (b, chunk) => b..add(chunk));
      final text = decodePlaylistText(body.takeBytes());
      if (response.statusCode != 200) {
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
        (path, abs, ref) => _proxyUrl(path, abs, ref),
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
      request.response.statusCode = HttpStatus.ok;
      request.response.headers
          .set(HttpHeaders.contentTypeHeader, cachedContentType(target));
      request.response.headers.set(HttpHeaders.contentLengthHeader, bytes.length);
      request.response.headers.set('X-Nerelict-Cache', 'HIT');
      request.response.add(bytes);
      await request.response.close();
      return;
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..autoUncompress = true;
    try {
      final req = await client.getUrl(Uri.parse(target));
      _applyHeaders(req, referer);
      if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
      final response = await req.close().timeout(const Duration(seconds: 20));

      request.response.statusCode = response.statusCode;
      final type = response.headers.contentType?.value;
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
      } else {
        await request.response.addStream(response);
        await request.response.close();
      }
    } finally {
      client.close(force: true);
    }
  }

  void _applyHeaders(HttpClientRequest req, String? referer) {
    req.headers.set('User-Agent', MediaSource.kDefaultUserAgent);
    if (referer != null && referer.startsWith('http')) {
      req.headers.set('Referer', referer);
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
  }
}
