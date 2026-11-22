import 'dart:io';

import 'file_kinds.dart';

/// 递归扫描「整个内部存储」的结果。
///
/// 与 [LocalFileScanResult]（下载目录、单层）分开：全盘扫描量级完全不同，
/// 需要额外的上限、截断与取消语义，避免一次扫描把应用拖死。
class StorageScanResult {
  const StorageScanResult({
    required this.files,
    required this.complete,
    required this.truncated,
    this.errors = 0,
    this.scannedDirs = 0,
    this.ignoredSegments = 0,
    this.skippedNoiseDirs = 0,
  });

  final List<LocalFile> files;

  /// 是否完整遍历（枚举或单个条目读取出错都会置 false）
  final bool complete;

  /// 是否因达到文件数上限而提前终止（文件太多，只列了前 N 个）
  final bool truncated;

  final int errors;

  /// 实际进入并枚举过的目录数，用于日志与诊断
  final int scannedDirs;

  /// 被判定为视频分片 / 下载半成品而忽略的文件数
  final int ignoredSegments;

  /// 被当作缓存目录整体跳过的目录数
  final int skippedNoiseDirs;
}

/// 递归扫描时的上下文：可取消标记、深度与计数。
class _ScanContext {
  _ScanContext({required this.cancel});

  /// 返回 true 表示要中止扫描
  final bool Function() cancel;

  /// 已进入的目录计数
  int dirs = 0;

  /// 已收集的文件数
  int files = 0;

  /// 单个条目读取失败数
  int errors = 0;

  /// 被忽略的分片/临时文件数
  int ignoredSegments = 0;

  /// 被整体跳过的缓存目录数
  int noiseDirs = 0;

  /// 是否被取消
  bool cancelled = false;
}

/// 全盘递归扫描的默认上限。
///
/// 内部存储动辄几万文件，全列出来既慢又没意义；超过就截断并明确提示，
/// 让用户知道「只显示了前 N 个」，而不是以为漏扫了。缓存与分片已经先被
/// 过滤掉，这个上限现在主要用来挡住「真的有几万张照片」的极端情况。
const int kStorageScanMaxFiles = 12000;

/// 递归最大深度。内部存储根算 1 层，`Android/` 这类系统目录会整体跳过，
/// 真正需要深入的目录很少超过 8 层，设上限防止遇到循环链接或超深目录。
const int kStorageScanMaxDepth = 8;

/// 同一目录里出现多少个「纯数字段号」媒体文件，就认定整个目录是分片缓存。
///
/// 取 3 而不是 1：`2024.mp4`、`1.mp4` 这类正常命名不该被误杀，
/// 而真正的 HLS 缓存目录动辄几十上百个段。
const int kSegmentGroupMin = 3;

/// 全盘扫描时要跳过的顶层目录名（不含前缀 `/`）。这些目录要么是系统/应用
/// 私有数据，要么会产生海量无意义的条目（缓存、缩略图、数据库），一律不进。
///
/// `Android` 在**任意层级**都跳过：`Android/data`、`Android/obb` 是应用私有区，
/// 普通文件权限读不到；嵌套在其它目录里的同名目录同样是应用数据。
const Set<String> kStorageSkipDirs = <String>{
  'Android',
  'LOST.DIR',
  'System Volume Information',
};

/// 优先扫描的用户目录：排在其它目录前面，避免文件数上限被冷门目录吃光。
///
/// 顺序即优先级；不在此表里的目录按名字排在后面，仍然会扫到。
const List<String> kStoragePriorityDirs = <String>[
  'Download',
  'Downloads',
  'DCIM',
  'Movies',
  'Pictures',
  'Music',
  'Documents',
  'Nerelict',
  'Tencent',
  'Weixin',
  'Quark',
  'Xunlei',
];

/// 递归扫描指定存储根（调用方传入，通常是 `/storage/emulated/0`），
/// 把各类文件统一收集。
///
/// [root] 由调用方提供——扫描器本身保持纯 Dart（无 Flutter 依赖），
/// 这样 `tool/verify_*` 能用 `dart run` 直接断言；外部存储根从哪来
/// 是 `StorageAccess` 的职责，不在这里。
///
/// [includeNoise] 为 true 时关闭「缓存目录 / 分片」过滤，把原始文件也列出来，
/// 供用户排查「我的文件怎么不见了」；默认 false。
///
/// 设计约束：
/// - **异步分批**：每枚举一个目录就 `await` 一次，把控制权交还事件循环，
///   避免长时间占用 isolate 让 UI 掉帧；
/// - **可取消**：[cancel] 回调返回 true 时尽快停止，返回已收集的部分结果；
/// - **类型识别**：优先扩展名，无扩展名/未知扩展名时读文件头魔数嗅探，
///   识别逻辑集中在 [sniffKind] 与 [kindOfName]；
/// - **噪音过滤**：缓存/缩略图目录、带 `.nomedia` 标记的目录、成组的
///   纯数字分片、`seg_*.bin` 半成品都不进列表——系统媒体库同样不索引它们；
/// - **优先级**：用户目录先扫，保证上限不会先被冷门目录占满。
Future<StorageScanResult> scanAllStorage({
  required String root,
  bool Function()? cancel,
  bool includeNoise = false,
}) async {
  if (root.isEmpty) {
    return const StorageScanResult(
        files: [], complete: false, truncated: false, errors: 1);
  }
  final ctx = _ScanContext(cancel: cancel ?? (() => false));
  final files = <LocalFile>[];

  await _walk(Directory(root), files, ctx, depth: 1, includeNoise: includeNoise);

  return StorageScanResult(
    files: files,
    complete: !ctx.cancelled && ctx.errors == 0,
    truncated: files.length >= kStorageScanMaxFiles && !ctx.cancelled,
    errors: ctx.errors,
    scannedDirs: ctx.dirs,
    ignoredSegments: ctx.ignoredSegments,
    skippedNoiseDirs: ctx.noiseDirs,
  );
}

Future<void> _walk(
  Directory dir,
  List<LocalFile> out,
  _ScanContext ctx, {
  required int depth,
  required bool includeNoise,
}) async {
  if (ctx.cancelled) return;
  if (ctx.files >= kStorageScanMaxFiles) return;
  if (depth > kStorageScanMaxDepth) return;

  final name = _baseName(dir.path);
  // 任意层级的隐藏目录跳过
  if (name.startsWith('.')) return;
  // 系统/应用私有目录任意层级都跳过
  if (kStorageSkipDirs.contains(name)) return;
  if (!includeNoise && kNoiseDirNames.contains(name.toLowerCase())) {
    ctx.noiseDirs++;
    return;
  }
  // 带 .nomedia 的目录等于「声明此处不是媒体」——缓存、缩略图、解密前的
  // 私有素材都会这么标；系统媒体库同样不索引，这里保持一致。
  if (depth > 1 && !includeNoise && await _hasNoMediaMarker(dir)) {
    ctx.noiseDirs++;
    return;
  }

  ctx.dirs++;
  await Future<void>.delayed(Duration.zero); // 交还事件循环

  final dirs = <Directory>[];
  final files = <File>[];
  try {
    await for (final entity in dir.list(followLinks: false)) {
      if (ctx.cancel()) {
        ctx.cancelled = true;
        return;
      }
      if (_baseName(entity.path).startsWith('.')) continue;
      if (entity is Directory) {
        dirs.add(entity);
      } else if (entity is File) {
        files.add(entity);
      }
    }
  } catch (_) {
    // 目录枚举中断：跳过它，但不中止整次扫描
    ctx.errors++;
  }

  // 分片成组判定：整个目录先看一遍，再决定这批文件是不是缓存分片，
  // 而不是逐个文件猜（单个 `1.mp4` 是正常文件，三十个 `1.ts`/`2.ts` 才是分片）。
  var segmentLike = 0;
  for (final f in files) {
    if (looksLikeMediaSegment(_baseName(f.path))) segmentLike++;
  }
  final dropSegments = !includeNoise && segmentLike >= kSegmentGroupMin;

  for (final file in files) {
    if (ctx.cancel()) {
      ctx.cancelled = true;
      return;
    }
    if (ctx.files >= kStorageScanMaxFiles) return;

    final itemName = _baseName(file.path);
    if (looksLikePartFile(itemName)) {
      ctx.ignoredSegments++;
      continue;
    }
    if (dropSegments && looksLikeMediaSegment(itemName)) {
      ctx.ignoredSegments++;
      continue;
    }

    try {
      final stat = await file.stat();
      if (stat.size <= 0) continue;
      var kind = kindOfName(itemName);
      // 无扩展名或未知扩展名时读文件头魔数，把识别做准
      if (kind == LocalFileKind.other) {
        final sniffed = await _sniffFile(file);
        if (sniffed != null) kind = sniffed;
      }
      out.add(LocalFile(
        path: file.path,
        name: itemName,
        size: stat.size,
        modifiedAt: stat.modified,
        kind: kind,
      ));
      ctx.files++;
    } catch (_) {
      ctx.errors++;
    }
  }

  // 用户目录优先：先扫 Download / DCIM / Movies 这些，冷门目录放到后面，
  // 这样即使真的撞上文件数上限，被截掉的也是最不可能是用户要找的东西。
  dirs.sort((a, b) {
    final byPriority = _dirPriority(_baseName(a.path))
        .compareTo(_dirPriority(_baseName(b.path)));
    return byPriority != 0 ? byPriority : a.path.compareTo(b.path);
  });

  for (final child in dirs) {
    if (ctx.cancelled || ctx.files >= kStorageScanMaxFiles) return;
    await _walk(child, out, ctx,
        depth: depth + 1, includeNoise: includeNoise);
  }
}

int _dirPriority(String name) {
  final index = kStoragePriorityDirs.indexOf(name);
  return index >= 0 ? index : kStoragePriorityDirs.length;
}

/// 目录里是否有 `.nomedia` 标记文件。
Future<bool> _hasNoMediaMarker(Directory dir) async {
  try {
    return await File('${dir.path}${Platform.pathSeparator}.nomedia').exists();
  } catch (_) {
    return false;
  }
}

/// 读文件头做魔数嗅探。只读前 32 字节，足够覆盖所有已登记的魔数。
Future<LocalFileKind?> _sniffFile(File file) async {
  try {
    final raf = await file.open();
    final header = await raf.read(32);
    await raf.close();
    return sniffKind(header);
  } catch (_) {
    return null;
  }
}

String _baseName(String path) {
  final i = path.lastIndexOf(Platform.pathSeparator);
  return i >= 0 ? path.substring(i + 1) : path;
}
