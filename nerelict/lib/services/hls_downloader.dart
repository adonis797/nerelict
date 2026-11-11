import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:pointycastle/export.dart';

import '../models/download_task.dart';
import 'hls_parser.dart';
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
  })  : dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 60),
              sendTimeout: const Duration(seconds: 20),
              followRedirects: true,
              maxRedirects: 8,
              responseType: ResponseType.bytes,
              headers: {
                'User-Agent':
                    'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
                        '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
                'Accept': '*/*',
              },
            ));

  final Dio dio;
  final int concurrency;

  /// 单个请求（含整个响应体）的最长耗时
  final Duration requestTimeout = const Duration(seconds: 45);

  /// 输出目录 / 临时目录由调用方注入，方便在主机上跑验证脚本
  final Future<Directory> Function()? resolveOutputDir;
  final Future<Directory> Function()? resolveTempDir;

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
        final variants = parseMasterPlaylist(text, base);
        if (variants.isEmpty) {
          throw Exception('主播放列表里没有可用码率');
        }
        final best = variants.first;
        task.variant = best.label;
        final second = await _fetchText(
            best.uri.toString(), task.referer, task, canceled);
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
      final response = await _guarded(
        const Duration(minutes: 10),
        (token) => dio.get<ResponseBody>(
          task.url,
          cancelToken: token,
          options: Options(
            responseType: ResponseType.stream,
            headers: <String, dynamic>{
              if (task.referer != null) 'Referer': task.referer!,
              if (offset > 0) 'Range': 'bytes=$offset-',
              // 源文件在暂停期间被替换时，服务端会忽略 Range 返回 200；
              // 现有逻辑随即从头重写，避免把新旧两个版本拼在一起。
              if (offset > 0 && validator != null && validator.isNotEmpty)
                'If-Range': validator,
            },
          ),
        ),
        taskId: task.id,
      );

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
      media = HlsMediaPlaylist(
        segments: media.segments.take(limitSegments).toList(),
        initUri: media.initUri,
        isFmp4: media.isFmp4,
        isLive: media.isLive,
      );
    }
    if (media.segments.isEmpty) {
      throw Exception('播放列表里没有分片，可能已结束或需要登录');
    }
    // 直播流没有 #EXT-X-ENDLIST：这里只能保存当前窗口的片段。
    // 标记到任务上，让下载页与完成提示明确告知用户，不再假装是完整视频。
    task.isLive = media.isLive;
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
        if (media.initUri != null) _initName(media.initUri!),
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

      // fMP4 的初始化分片
      String? initPath;
      if (media.initUri != null) {
        // fMP4 的 init 段也按 URI 身份命名，编码参数变化时不会复用旧 init。
        final initFile = File(joinPath(tmp.path, _initName(media.initUri!)));
        if (resume && await initFile.exists()) {
          initPath = initFile.path;
        } else {
          final bytes = await _fetchBytes(
              media.initUri.toString(), task.referer, task, canceled);
          await _writeAtomic(initFile, bytes);
          initPath = initFile.path;
        }
      }

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
              seg.uri.toString(), task.referer, task, canceled);

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
        if (initPath != null) {
          await sink.addStream(File(initPath).openRead());
        }
        for (final p in partPaths) {
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

  /// 分片文件名由「URL + 加密方式 + 密钥 / IV」摘要决定，与播放列表中的
  /// 位置无关。滑动窗口变化后只有同一 URL 的分片才会被续传复用，避免串片。
  String _partName(HlsSegment seg) {
    final key = seg.key;
    final identity = key == null
        ? seg.uri.toString()
        : '${seg.uri}|${key.method}|${key.uri ?? ''}|'
            '${key.iv?.join(',') ?? seg.sequence}';
    return _hashName('seg', identity, 'bin');
  }

  String _initName(Uri uri) => _hashName('init', uri.toString(), 'mp4');

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

  /// 返回正文与**重定向后的最终 URI**，供相对分片解析使用。
  Future<({String body, Uri uri})> _fetchText(
    String url,
    String? referer,
    DownloadTask task,
    bool Function() canceled,
  ) async {
    final res = await _withRetry<Response<String>>(
      () => _guarded<Response<String>>(
        requestTimeout,
        (token) => dio.get<String>(
          url,
          cancelToken: token,
          options: Options(
            responseType: ResponseType.plain,
            headers: referer == null ? null : {'Referer': referer},
          ),
        ),
        taskId: task.id,
      ),
      shouldStop: canceled,
    );
    final body = res.data ?? '';
    if (!body.trimLeft().startsWith('#EXTM3U')) {
      throw Exception('返回内容不是有效的 m3u8');
    }
    // 服务端常用相对 Location，此时 Dio 的 realUri 只是 "/path/index.m3u8"
    // 这类相对引用；必须基于请求地址解析成绝对 URI，否则分片 URL 会缺 host。
    final uri = Uri.parse(url).resolveUri(res.realUri);
    return (body: body, uri: uri);
  }

  Future<Uint8List> _fetchBytes(
    String url,
    String? referer,
    DownloadTask task,
    bool Function() canceled,
  ) async {
    final res = await _withRetry(
      () => _guarded(
        requestTimeout,
        (token) => dio.get<List<int>>(
          url,
          cancelToken: token,
          options: Options(
            responseType: ResponseType.bytes,
            headers: referer == null ? null : {'Referer': referer},
          ),
        ),
        taskId: task.id,
      ),
      shouldStop: canceled,
    );
    final data = res.data;
    if (data == null || data.isEmpty) {
      throw Exception('空响应：${Uri.parse(url).pathSegments.lastOrNull ?? url}');
    }
    return data is Uint8List ? data : Uint8List.fromList(data);
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

  Future<T> _withRetry<T>(
    Future<T> Function() fn, {
    int attempts = 3,
    bool Function()? shouldStop,
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
        await Future<void>.delayed(Duration(milliseconds: 400 * (i + 1)));
      }
    }
    throw last ?? Exception('请求失败');
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
          return '服务器返回 ${e.response?.statusCode}，可能需要 Referer 或已失效';
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
