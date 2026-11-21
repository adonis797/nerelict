import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/download_task.dart';
import '../services/local_media_scanner.dart';
import '../services/media_meta.dart';
import '../services/media_probe.dart';
import '../services/playback_memory.dart';
import '../services/storage_access.dart';
import '../state/app_state.dart';
import 'app_theme.dart';
import 'download_tasks_page.dart';
import 'file_manager_sheet.dart';
import 'mp4_convert_sheet.dart';

/// 排序维度。`duration` 只对已探测过元数据的视频有意义，拿不到的排末尾。
enum _SortBy { modified, name, size, duration }

/// 「文件」标签页：下载目录的整体文件管理。
///
/// 结构对齐系统文件管理器：分类宫格 → 最近播放 → 全部文件。
/// 两条刻意的简化：
///
/// - **视频不做独立页面**：点行直接进 Nerelict 播放器，播放失败由播放器自己报；
/// - **列表行不放操作按钮**：所有管理动作收进行尾 `⋮`，避免一行四个图标。
class FilesTab extends StatefulWidget {
  const FilesTab({super.key});

  @override
  State<FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends State<FilesTab> with WidgetsBindingObserver {
  late final AppState _app;
  PlaybackRecord? _resume;

  /// 当前分类筛选；null 表示「全部」
  LocalFileKind? _filter;

  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  String _query = '';
  _SortBy _sortBy = _SortBy.modified;
  bool _sortDesc = true;

  bool _selecting = false;
  final Set<String> _selected = <String>{};

  /// 当前浏览的目录；null 表示「下载目录」（由 AppState 统一维护）
  String? _dir;

  /// 外部目录的条目（下载目录走 AppState.localFiles）
  List<LocalFile> _entries = const <LocalFile>[];
  bool _scanning = false;
  String? _externalRoot;
  bool _allFilesOk = false;

  /// 是否允许增删改：只有自家下载目录可以，别处只做浏览与播放。
  ///
  /// 这不是偷懒——在系统任意目录上放开 delete/rename，一次误触就是别人的照片没了；
  /// 先把「看得见、播得了」做扎实，写操作等有明确需求再放开。
  bool get _canManage => _dir == null;

  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>();
    _app.addBackInterceptor(_handleSystemBack);
    WidgetsBinding.instance.addObserver(this);
    _refreshAccess();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _app.refreshLocalFiles();
      _loadResume();
    });
  }

  @override
  void dispose() {
    _app.removeBackInterceptor(_handleSystemBack);
    WidgetsBinding.instance.removeObserver(this);
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// 系统返回的优先级：退多选 → 退搜索 → 退筛选 → 交给 HomeScreen。
  Future<bool> _handleSystemBack() async {
    if (_app.tabIndex != 1) return false;
    if (_selecting) {
      _clearSelection();
      return true;
    }
    if (_query.isNotEmpty) {
      _searchCtrl.clear();
      setState(() => _query = '');
      return true;
    }
    if (_dir != null) {
      _leaveDir();
      return true;
    }
    if (_filter == null) return false;
    setState(() => _filter = null);
    return true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 用户去系统设置开权限、或从别的应用回来：重新查一次，开好了立刻可用
    if (state == AppLifecycleState.resumed) _refreshAccess();
  }

  Future<void> _refreshAccess() async {
    final ok = await StorageAccess.hasAllFilesAccess();
    final root = ok ? await StorageAccess.externalRoot() : null;
    if (!mounted) return;
    if (ok != _allFilesOk || root != _externalRoot) {
      setState(() {
        _allFilesOk = ok;
        _externalRoot = root;
      });
    }
  }

  Future<void> _requestAccess() async {
    final opened = await StorageAccess.openSettings();
    if (!mounted) return;
    if (!opened) {
      _app.showHint('请在系统设置里找到「所有文件访问权限」并允许');
      return;
    }
    // 设置页回来后由 didChangeAppLifecycleState 重新检查
  }

  Future<void> _enterDir(String path) async {
    setState(() {
      _dir = path;
      _entries = const <LocalFile>[];
      _scanning = true;
      _filter = null;
      _clearSelection();
    });
    final scan = await scanDirectory(path);
    if (!mounted || _dir != path) return;
    setState(() {
      _entries = scan.files;
      _scanning = false;
    });
  }

  /// 菜单里的「浏览内部存储」：没授权就先引导，有授权就进根目录。
  Future<void> _browseStorage() async {
    if (!_allFilesOk) {
      await _requestAccess();
      return;
    }
    final root = _externalRoot ?? await StorageAccess.externalRoot();
    if (!mounted) return;
    if (root == null) {
      _app.showHint('拿不到内部存储目录，请重新授权');
      return;
    }
    await _enterDir(root);
  }

  /// 上一级；已经到内部存储根就退回下载目录。
  void _leaveDir() {
    final current = _dir;
    if (current == null) return;
    final root = _externalRoot;
    final parent = current.substring(0, current.lastIndexOf(Platform.pathSeparator));
    if (root == null ||
        current == root ||
        parent.isEmpty ||
        parent.length < root.length) {
      setState(() {
        _dir = null;
        _entries = const <LocalFile>[];
        _scanning = false;
      });
      _app.refreshLocalFiles();
      return;
    }
    _enterDir(parent);
  }

  Future<void> _loadResume() async {
    final record = await PlaybackMemory().latestResumable();
    if (mounted) setState(() => _resume = record);
  }

  void _onFilesChanged() {
    if (!mounted) return;
    setState(() {});
    _loadResume();
  }

  void _clearSelection() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  Future<void> _openDownloads() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const DownloadTasksPage()),
    );
    if (!mounted) return;
    await _app.refreshLocalFiles();
    _loadResume();
  }

  void _openResume() {
    final record = _resume;
    if (record == null) return;
    _app.resumePlayback(
      url: record.url,
      title: record.title,
      referer: record.referer,
      local: record.local,
    );
  }

  /// 点行的默认动作：视频直接播放，其它交给文件管理面板。
  void _openFile(LocalFile file) {
    if (_selecting) {
      _toggleSelect(file.path);
      return;
    }
    if (file.isDir) {
      _enterDir(file.path);
      return;
    }
    if (file.isPlayable) {
      _app.openPlayer(url: file.path, title: file.title, local: true);
      return;
    }
    showFileManagerSheet(
      context,
      paths: <String>[file.path],
      onChanged: _onFilesChanged,
    );
  }

  void _toggleSelect(String path) {
    setState(() {
      _selecting = true;
      if (!_selected.add(path)) _selected.remove(path);
      if (_selected.isEmpty) _selecting = false;
    });
  }

  void _enterSelection(String path) {
    setState(() {
      _selecting = true;
      _selected
        ..clear()
        ..add(path);
    });
  }

  Future<void> _renameFile(LocalFile file) async {
    final controller = TextEditingController(text: file.title);
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名', style: TextStyle(fontSize: 16)),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '新文件名（不含扩展名）'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (!mounted || value == null || value.trim().isEmpty) return;
    try {
      await _app.renameDownloadedFile(file.path, value);
      _onFilesChanged();
    } catch (e) {
      if (!mounted) return;
      _app.showHint(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _deleteFiles(List<LocalFile> files) async {
    if (files.isEmpty) return;
    final total = files.fold<int>(0, (sum, f) => sum + f.size);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          files.length == 1 ? '删除文件？' : '删除 ${files.length} 个文件？',
          style: const TextStyle(fontSize: 16),
        ),
        content: Text(
          '${_sizeText(total)} 将移入回收站，保留 7 天，期间可以撤销。',
          style: const TextStyle(fontSize: 13),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: kDanger),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final trashed = await _app.deleteDownloadedFiles(files.map((f) => f.path));
    _clearSelection();
    _onFilesChanged();
    if (!mounted) return;
    // 删除先落回收站，给一次反悔的机会；误触的代价从「文件没了」降到「点一下撤销」
    if (trashed.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已删除 ${files.length} 项（在回收站保留 7 天）'),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () async {
            final n = await _app.restoreFromTrash(trashed);
            _onFilesChanged();
            if (!mounted) return;
            _app.showHint(n > 0 ? '已恢复 $n 个文件' : '恢复失败，文件可能已被清理');
          },
        ),
      ),
    );
  }

  /// 行尾 `⋮`：所有管理动作集中在这里，列表本身不摊按钮。
  Future<void> _showRowMenu(LocalFile file) async {
    final p = paletteOf(context);
    final canConvert = file.kind == LocalFileKind.video && !file.isMp4;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: p.surface,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.play_circle_outline, size: 20),
              title: Text(
                file.isPlayable ? '用 Nerelict 播放' : '用系统应用打开',
                style: const TextStyle(fontSize: 13.5),
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                _openFile(file);
              },
            ),
            if (canConvert && _canManage)
              ListTile(
                leading: const Icon(Icons.movie_creation_outlined, size: 20),
                title: const Text('转成 MP4', style: TextStyle(fontSize: 13.5)),
                onTap: () {
                  Navigator.of(ctx).pop();
                  showMp4ConvertSheet(context);
                },
              ),
            if (!_canManage)
              ListTile(
                leading: const Icon(Icons.lock_outline, size: 20),
                title: Text(
                  '此目录只读：重命名与删除仅对下载目录开放',
                  style: TextStyle(fontSize: 12, color: p.textFaint),
                ),
              ),
            ListTile(
              leading: const Icon(Icons.info_outline, size: 20),
              title: const Text('文件信息', style: TextStyle(fontSize: 13.5)),
              onTap: () {
                Navigator.of(ctx).pop();
                showFileManagerSheet(
                  context,
                  paths: <String>[file.path],
                  onChanged: _onFilesChanged,
                );
              },
            ),
            if (_canManage) ...<Widget>[
              ListTile(
                leading: const Icon(Icons.drive_file_rename_outline, size: 20),
                title: const Text('重命名', style: TextStyle(fontSize: 13.5)),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _renameFile(file);
                },
              ),
              ListTile(
                leading: const Icon(Icons.checklist, size: 20),
                title: const Text('选择', style: TextStyle(fontSize: 13.5)),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _enterSelection(file.path);
                },
              ),
              ListTile(
                leading:
                    const Icon(Icons.delete_outline, size: 20, color: kDanger),
                title: const Text('删除',
                    style: TextStyle(fontSize: 13.5, color: kDanger)),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _deleteFiles(<LocalFile>[file]);
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 筛选 + 搜索 + 排序后的可见列表。
  List<LocalFile> _visibleFiles(List<LocalFile> all) {
    final q = _query.trim().toLowerCase();
    final list = all.where((f) {
      if (_filter != null && f.kind != _filter) return false;
      if (q.isEmpty) return true;
      // 除了文件名，也匹配类型词与扩展名：输「m3u8」「视频」都能命中
      return f.name.toLowerCase().contains(q) ||
          f.typeLabel.toLowerCase().contains(q) ||
          f.kind.label.contains(q) ||
          f.extension.contains(q);
    }).toList();

    int compare(LocalFile a, LocalFile b) {
      final r = switch (_sortBy) {
        _SortBy.modified => a.modifiedAt.compareTo(b.modifiedAt),
        _SortBy.name => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        _SortBy.size => a.size.compareTo(b.size),
        _SortBy.duration => _durationKey(a).compareTo(_durationKey(b)),
      };
      return _sortDesc ? -r : r;
    }

    list.sort(compare);
    return list;
  }

  /// 时长排序只读已缓存的元数据：不能为了排序把整个目录解码一遍。
  int _durationKey(LocalFile f) =>
      MediaProbe.instance.peek(f)?.duration?.inMilliseconds ?? -1;

  String get _sortLabel => switch (_sortBy) {
        _SortBy.modified => '最近更新',
        _SortBy.name => '名称',
        _SortBy.size => '大小',
        _SortBy.duration => '时长',
      };

  Future<void> _showSortSheet(AppPalette p) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: p.surface,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final entry in <(_SortBy, String)>[
              (_SortBy.modified, '最近更新'),
              (_SortBy.name, '名称'),
              (_SortBy.size, '大小'),
              (_SortBy.duration, '时长'),
            ])
              ListTile(
                title: Text(entry.$2, style: const TextStyle(fontSize: 13.5)),
                trailing: _sortBy == entry.$1
                    ? Icon(
                        _sortDesc ? Icons.arrow_downward : Icons.arrow_upward,
                        size: 18,
                      )
                    : null,
                onTap: () {
                  setState(() {
                    if (_sortBy == entry.$1) {
                      _sortDesc = !_sortDesc;
                    } else {
                      _sortBy = entry.$1;
                      _sortDesc = entry.$1 == _SortBy.modified;
                    }
                  });
                  Navigator.of(ctx).pop();
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final p = paletteOf(context);
    final files = _dir == null ? state.localFiles : _entries;
    final visible = _visibleFiles(files);

    // 缓存只为仍然存在的文件保留，避免删改后越积越多
    MediaProbe.instance.retainOnly(files.map((f) => f.path).toSet());

    final counts = <LocalFileKind, int>{};
    for (final f in files) {
      counts[f.kind] = (counts[f.kind] ?? 0) + 1;
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: _selecting ? _selectionAppBar(files) : _normalAppBar(state, visible),
      body: Column(
        children: <Widget>[
          if (state.tasks.any((t) => !t.status.isFinished))
            _ActiveDownloadsBanner(
              tasks: state.tasks,
              p: p,
              onOpen: _openDownloads,
            ),
          if (state.lastScanIncomplete) _ScanIncompleteBanner(p: p),
          _SearchField(
            controller: _searchCtrl,
            focusNode: _searchFocus,
            onChanged: (v) => setState(() => _query = v),
            p: p,
          ),
          if (_dir != null)
            _Breadcrumb(dir: _dir!, root: _externalRoot, onUp: _leaveDir, p: p)
          else if (!_allFilesOk)
            _AccessCard(p: p, onGrant: _requestAccess),
          _KindGrid(
            counts: counts,
            total: files.length,
            selected: _filter,
            onSelect: (kind) => setState(() {
              _filter = _filter == kind ? null : kind;
            }),
            p: p,
          ),
          if (!_selecting &&
              _dir == null &&
              _filter == null &&
              _query.isEmpty &&
              _resume != null)
            _RecentSection(record: _resume!, p: p, onOpen: _openResume),
          _ListHeader(
            title: _dir == null ? '全部文件' : '当前文件夹',
            count: visible.length,
            sortLabel: _sortLabel,
            onSort: () => _showSortSheet(p),
            p: p,
          ),
          Expanded(
            child: _scanning
                ? Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: p.accent),
                    ),
                  )
                : files.isEmpty && _dir != null
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Icon(Icons.folder_open_outlined,
                                size: 44, color: p.textDisabled),
                            const SizedBox(height: 10),
                            Text('这个文件夹是空的',
                                style: TextStyle(
                                    fontSize: 12.5, color: p.textFaint)),
                          ],
                        ),
                      )
                : files.isEmpty
                ? _EmptyState(
                    p: p,
                    hasTasks: state.tasks.isNotEmpty,
                    onBrowse: () => state.setTab(0),
                    onOpenDownloads: _openDownloads,
                  )
                : visible.isEmpty
                    ? _FilterEmpty(p: p, kind: _filter, query: _query)
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
                        itemCount: visible.length,
                        itemBuilder: (context, i) {
                          final file = visible[i];
                          return _FileRow(
                            key: ValueKey(file.path),
                            file: file,
                            selecting: _selecting,
                            selected: _selected.contains(file.path),
                            onTap: () => _openFile(file),
                            onLongPress: () => _enterSelection(file.path),
                            onMenu: () => _showRowMenu(file),
                          );
                        },
                      ),
          ),
        ],
      ),
      bottomNavigationBar: _selecting && _canManage
          ? _BatchBar(
              count: _selected.length,
              onDelete: () => _deleteFiles(
                files.where((f) => _selected.contains(f.path)).toList(),
              ),
              onCancel: _clearSelection,
              p: p,
            )
          : null,
    );
  }

  AppBar _normalAppBar(AppState state, List<LocalFile> visible) {
    return AppBar(
      title: const Text('文件管理', style: TextStyle(fontSize: 17)),
      actions: <Widget>[
        IconButton(
          tooltip: '搜索',
          icon: const Icon(Icons.search, size: 20),
          onPressed: () => _searchFocus.requestFocus(),
        ),
        PopupMenuButton<String>(
          tooltip: '更多',
          icon: const Icon(Icons.more_vert, size: 20),
          onSelected: (value) {
            switch (value) {
              case 'sort':
                _showSortSheet(paletteOf(context));
                break;
              case 'select':
                final first = visible.isEmpty ? null : visible.first;
                if (first != null) _enterSelection(first.path);
                break;
              case 'scan':
                state.refreshLocalFiles();
                _loadResume();
                break;
              case 'convert':
                showMp4ConvertSheet(context);
                break;
              case 'downloads':
                _openDownloads();
                break;
              case 'browse':
                _browseStorage();
                break;
              case 'home':
                setState(() {
                  _dir = null;
                  _entries = const <LocalFile>[];
                });
                state.refreshLocalFiles();
                break;
            }
          },
          itemBuilder: (_) => <PopupMenuEntry<String>>[
            const PopupMenuItem<String>(value: 'sort', child: Text('排序方式')),
            if (_canManage)
              const PopupMenuItem<String>(value: 'select', child: Text('批量选择')),
            const PopupMenuItem<String>(value: 'scan', child: Text('重新扫描')),
            const PopupMenuItem<String>(value: 'convert', child: Text('MP4 转换')),
            const PopupMenuItem<String>(value: 'downloads', child: Text('下载管理')),
            if (_dir == null)
              PopupMenuItem<String>(
                value: 'browse',
                child: Text(_allFilesOk ? '浏览内部存储' : '浏览内部存储（需授权）'),
              )
            else
              const PopupMenuItem<String>(value: 'home', child: Text('回到下载目录')),
          ],
        ),
      ],
    );
  }

  AppBar _selectionAppBar(List<LocalFile> files) {
    final total = files
        .where((f) => _selected.contains(f.path))
        .fold<int>(0, (sum, f) => sum + f.size);
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close, size: 20),
        onPressed: _clearSelection,
      ),
      title: Text(
        '已选 ${_selected.length} 项 · ${_sizeText(total)}',
        style: const TextStyle(fontSize: 15),
      ),
      actions: <Widget>[
        IconButton(
          tooltip: '全选当前列表',
          icon: const Icon(Icons.select_all, size: 20),
          onPressed: () => setState(() {
            _selected
              ..clear()
              ..addAll(_visibleFiles(files).map((f) => f.path));
          }),
        ),
      ],
    );
  }
}

String _sizeText(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 || i == 0 ? 0 : 1)} ${units[i]}';
}

/// 相对时间：今天/昨天给到分钟，更早只给日期。
String _relativeDate(DateTime t) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  final diff = today.difference(day).inDays;
  final hm = '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';
  if (diff == 0) return '今天 $hm';
  if (diff == 1) return '昨天 $hm';
  if (t.year == now.year) {
    return '${t.month.toString().padLeft(2, '0')}-'
        '${t.day.toString().padLeft(2, '0')} $hm';
  }
  return '${t.year}-${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';
}

/// 面包屑：只在浏览外部目录时出现，用来知道「我在哪」并能一级级退回。
class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({
    required this.dir,
    required this.root,
    required this.onUp,
    required this.p,
  });

  final String dir;
  final String? root;
  final VoidCallback onUp;
  final AppPalette p;

  @override
  Widget build(BuildContext context) {
    final base = root ?? '';
    var tail = dir;
    if (base.isNotEmpty && dir.startsWith(base)) {
      tail = dir.substring(base.length);
    }
    final parts = tail
        .split(Platform.pathSeparator)
        .where((e) => e.isNotEmpty)
        .toList();
    final label = parts.isEmpty ? '内部存储' : '内部存储 / ${parts.join(' / ')}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 2, 10, 6),
      child: Row(
        children: <Widget>[
          InkWell(
            onTap: onUp,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.arrow_upward, size: 16, color: p.textSub),
            ),
          ),
          const SizedBox(width: 2),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: p.textFaint),
            ),
          ),
        ],
      ),
    );
  }
}

/// 未授权时的引导卡：说清楚「为什么需要」和「开了能得到什么」，而不是只弹一个按钮。
class _AccessCard extends StatelessWidget {
  const _AccessCard({required this.p, required this.onGrant});

  final AppPalette p;
  final VoidCallback onGrant;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.border),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.folder_shared_outlined, size: 18, color: p.accent),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '浏览整个手机存储',
                  style: TextStyle(fontSize: 12.5, color: p.text),
                ),
                const SizedBox(height: 2),
                Text(
                  '需要「所有文件访问权限」，开启后可查看、播放任意目录里的文件',
                  style: TextStyle(fontSize: 11, color: p.textFaint),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          TextButton(
            onPressed: onGrant,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
            child: const Text('去授权', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

/// 搜索框：常驻但不抢眼，输入即过滤。
class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.p,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final AppPalette p;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: SizedBox(
        height: 38,
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          onChanged: onChanged,
          style: TextStyle(fontSize: 12.5, color: p.text),
          decoration: InputDecoration(
            isDense: true,
            hintText: '搜索文件或类型',
            hintStyle: TextStyle(fontSize: 12.5, color: p.textFaint),
            prefixIcon: Icon(Icons.search, size: 17, color: p.textFaint),
            prefixIconConstraints:
                const BoxConstraints(minWidth: 34, minHeight: 34),
            suffixIcon: controller.text.isEmpty
                ? null
                : IconButton(
                    icon: Icon(Icons.close, size: 15, color: p.textFaint),
                    onPressed: () {
                      controller.clear();
                      onChanged('');
                    },
                  ),
            filled: true,
            fillColor: p.surface,
            contentPadding: const EdgeInsets.symmetric(vertical: 9),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: p.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: p.border),
            ),
          ),
        ),
      ),
    );
  }
}

/// 分类宫格：八类，带计数；点一下筛选，再点取消。
class _KindGrid extends StatelessWidget {
  const _KindGrid({
    required this.counts,
    required this.total,
    required this.selected,
    required this.onSelect,
    required this.p,
  });

  final Map<LocalFileKind, int> counts;
  final int total;
  final LocalFileKind? selected;
  final void Function(LocalFileKind kind) onSelect;
  final AppPalette p;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: GridView.count(
        crossAxisCount: 4,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        childAspectRatio: 0.92,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
        children: <Widget>[
          for (final kind in kGridKinds)
            _KindTile(
              kind: kind,
              count: counts[kind] ?? 0,
              active: selected == kind,
              dimmed: selected != null && selected != kind,
              onTap: () => onSelect(kind),
              p: p,
            ),
        ],
      ),
    );
  }
}

class _KindTile extends StatelessWidget {
  const _KindTile({
    required this.kind,
    required this.count,
    required this.active,
    required this.dimmed,
    required this.onTap,
    required this.p,
  });

  final LocalFileKind kind;
  final int count;
  final bool active;
  final bool dimmed;
  final VoidCallback onTap;
  final AppPalette p;

  Color get _tint => switch (kind) {
        LocalFileKind.video => const Color(0xFF4C8DFF),
        LocalFileKind.audio => const Color(0xFF34D399),
        LocalFileKind.image => const Color(0xFFF0B24A),
        LocalFileKind.document => const Color(0xFFF87171),
        LocalFileKind.ebook => const Color(0xFFC084FC),
        LocalFileKind.archive => const Color(0xFFA78BFA),
        LocalFileKind.apk => const Color(0xFF38BDF8),
        LocalFileKind.other => const Color(0xFF94A3B8),
      };

  IconData get _icon => switch (kind) {
        LocalFileKind.video => Icons.play_arrow_rounded,
        LocalFileKind.audio => Icons.graphic_eq,
        LocalFileKind.image => Icons.image_outlined,
        LocalFileKind.document => Icons.description_outlined,
        LocalFileKind.ebook => Icons.menu_book_outlined,
        LocalFileKind.archive => Icons.folder_zip_outlined,
        LocalFileKind.apk => Icons.android,
        LocalFileKind.other => Icons.insert_drive_file_outlined,
      };

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Opacity(
        opacity: dimmed ? 0.45 : 1,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: _tint.withValues(alpha: active ? 0.28 : 0.14),
                borderRadius: BorderRadius.circular(11),
                border: Border.all(
                  color: active ? _tint : Colors.transparent,
                  width: 1,
                ),
              ),
              child: Icon(_icon, size: 20, color: _tint),
            ),
            const SizedBox(height: 6),
            Text(
              kind.label,
              style: TextStyle(
                fontSize: 11.5,
                color: active ? p.text : p.textSub,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
            const SizedBox(height: 1),
            Text('$count', style: TextStyle(fontSize: 11, color: p.textFaint)),
          ],
        ),
      ),
    );
  }
}

/// 最近播放：只放一条，来自播放记忆；点开直接续播。
class _RecentSection extends StatelessWidget {
  const _RecentSection({
    required this.record,
    required this.p,
    required this.onOpen,
  });

  final PlaybackRecord record;
  final AppPalette p;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 2),
          child: Row(
            children: <Widget>[
              Text(
                '最近播放',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: p.textSub,
                ),
              ),
              const Spacer(),
              Text(
                record.progressText,
                style: TextStyle(fontSize: 11, color: p.textFaint),
              ),
            ],
          ),
        ),
        InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 8),
            child: Row(
              children: <Widget>[
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: p.accent.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.play_arrow_rounded,
                      size: 19, color: p.accent),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        record.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.5, color: p.text),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '上次看到 ${record.progressText}',
                        style: TextStyle(fontSize: 11, color: p.textFaint),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, size: 18, color: p.textFaint),
              ],
            ),
          ),
        ),
        Divider(height: 1, color: p.border),
      ],
    );
  }
}

class _ListHeader extends StatelessWidget {
  const _ListHeader({
    required this.title,
    required this.count,
    required this.sortLabel,
    required this.onSort,
    required this.p,
  });

  final String title;
  final int count;
  final String sortLabel;
  final VoidCallback onSort;
  final AppPalette p;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 4),
      child: Row(
        children: <Widget>[
          Text(
            title,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: p.textSub,
            ),
          ),
          const SizedBox(width: 6),
          Text('$count', style: TextStyle(fontSize: 11, color: p.textFaint)),
          const Spacer(),
          InkWell(
            onTap: onSort,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: p.border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(sortLabel,
                      style: TextStyle(fontSize: 11, color: p.textSub)),
                  Icon(Icons.expand_more, size: 14, color: p.textFaint),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单行文件：图标/缩略图 + 名字 + 一行元信息 + `⋮`。
///
/// 元数据懒加载：首帧同步读缓存，没有就异步补一次；补完只重建这一行。
class _FileRow extends StatefulWidget {
  const _FileRow({
    super.key,
    required this.file,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onMenu,
  });

  final LocalFile file;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onMenu;

  @override
  State<_FileRow> createState() => _FileRowState();
}

class _FileRowState extends State<_FileRow> {
  MediaMeta? _meta;

  @override
  void initState() {
    super.initState();
    _meta = MediaProbe.instance.peek(widget.file);
    if (_meta == null) _loadMeta();
  }

  @override
  void didUpdateWidget(_FileRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path ||
        oldWidget.file.size != widget.file.size) {
      _meta = MediaProbe.instance.peek(widget.file);
      if (_meta == null) _loadMeta();
    }
  }

  Future<void> _loadMeta() async {
    final meta = await MediaProbe.instance.probe(widget.file);
    if (!mounted || meta == null) return;
    setState(() => _meta = meta);
  }

  IconData get _icon => switch (widget.file.kind) {
        LocalFileKind.video => widget.file.isMp4
            ? Icons.video_file_outlined
            : Icons.movie_outlined,
        LocalFileKind.audio => Icons.audiotrack_outlined,
        LocalFileKind.image => Icons.image_outlined,
        LocalFileKind.document => Icons.description_outlined,
        LocalFileKind.ebook => Icons.menu_book_outlined,
        LocalFileKind.archive => Icons.folder_zip_outlined,
        LocalFileKind.apk => Icons.android,
        LocalFileKind.other => Icons.insert_drive_file_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final file = widget.file;
    final meta = _meta;

    // 元信息压成一行：类型 · 专有信息 · 大小 · 时间，超出直接省略
    final parts = <String>[file.typeLabel];
    final inline = meta?.inlineInfo ?? '';
    if (inline.isNotEmpty) parts.add(inline);
    // 目录没有「大小」，别显示成一个破折号
    if (!file.isDir) parts.add(file.sizeText);
    parts.add(_relativeDate(file.modifiedAt));
    final subtitle = parts.join(' · ');

    final warn = meta?.attention ?? false;
    final isImage = file.kind == LocalFileKind.image;

    return Material(
      color: widget.selected
          ? p.accent.withValues(alpha: 0.10)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 6, 2, 6),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: p.border, width: 0.5)),
          ),
          child: Row(
            children: <Widget>[
              if (widget.selecting)
                Padding(
                  padding: const EdgeInsets.only(right: 8, left: 4),
                  child: Icon(
                    widget.selected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 20,
                    color: widget.selected ? p.accent : p.textDisabled,
                  ),
                ),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 38,
                  height: 38,
                  child: isImage
                      ? Image.file(
                          File(file.path),
                          fit: BoxFit.cover,
                          cacheWidth: 96,
                          errorBuilder: (ctx2, err, stack) =>
                              _IconBox(icon: _icon, p: p),
                        )
                      : _IconBox(icon: _icon, p: p, highlight: file.isPlayable),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      file.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: p.text),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: warn ? kDanger : p.textFaint,
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.selecting)
                const SizedBox(width: 4)
              else
                // 44dp 触控区：图标只有 18dp，热区太小会被整行的点击抢走
                SizedBox(
                  width: 44,
                  height: 44,
                  child: InkWell(
                    onTap: widget.onMenu,
                    borderRadius: BorderRadius.circular(22),
                    child: Center(
                      child: Icon(Icons.more_vert,
                          size: 18, color: p.textFaint),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IconBox extends StatelessWidget {
  const _IconBox({required this.icon, required this.p, this.highlight = false});

  final IconData icon;
  final AppPalette p;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: highlight
          ? p.accent.withValues(alpha: 0.14)
          : p.surface.withValues(alpha: 0.9),
      alignment: Alignment.center,
      child: Icon(icon, size: 19, color: highlight ? p.accent : p.textSub),
    );
  }
}

class _BatchBar extends StatelessWidget {
  const _BatchBar({
    required this.count,
    required this.onDelete,
    required this.onCancel,
    required this.p,
  });

  final int count;
  final VoidCallback onDelete;
  final VoidCallback onCancel;
  final AppPalette p;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        decoration: BoxDecoration(
          color: p.navBg,
          border: Border(top: BorderSide(color: p.border)),
        ),
        child: Row(
          children: <Widget>[
            Text(
              '已选 $count 项',
              style: TextStyle(fontSize: 12.5, color: p.textSub),
            ),
            const Spacer(),
            TextButton(
              onPressed: onCancel,
              child: const Text('取消', style: TextStyle(fontSize: 12.5)),
            ),
            const SizedBox(width: 4),
            FilledButton.icon(
              onPressed: count == 0 ? null : onDelete,
              icon: const Icon(Icons.delete_outline, size: 17),
              label: const Text('删除', style: TextStyle(fontSize: 12.5)),
              style: FilledButton.styleFrom(
                backgroundColor: kDanger,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScanIncompleteBanner extends StatelessWidget {
  const _ScanIncompleteBanner({required this.p});

  final AppPalette p;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF3A2A12),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.warning_amber_outlined,
              size: 15, color: Color(0xFFF0B24A)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '部分文件暂时无法读取，已保留上次的列表',
              style: TextStyle(fontSize: 11.5, color: p.textSub),
            ),
          ),
        ],
      ),
    );
  }
}

/// 顶部「有任务在跑」提示：不切页也能看到下载进度，点一下进下载分支。
class _ActiveDownloadsBanner extends StatelessWidget {
  const _ActiveDownloadsBanner({
    required this.tasks,
    required this.p,
    required this.onOpen,
  });

  final List<DownloadTask> tasks;
  final AppPalette p;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final running = tasks.where((t) => t.status.isActive).toList();
    final paused = tasks.where((t) => t.status == TaskStatus.paused).length;
    final progress = running.isEmpty
        ? 0.0
        : running.map((t) => t.progress).reduce((a, b) => a + b) /
            running.length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onOpen,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 9, 10, 9),
            decoration: BoxDecoration(
              color: p.accent.withValues(alpha: p.isCyber ? 0.12 : 0.07),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: p.accent.withValues(alpha: 0.35)),
            ),
            child: Row(
              children: <Widget>[
                Icon(Icons.downloading, size: 19, color: p.accent),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        running.isNotEmpty
                            ? '${running.length} 个任务下载中'
                            : '$paused 个任务已暂停',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: p.text,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        running.isNotEmpty
                            ? '平均进度 ${(progress * 100).round()}% · 点此查看下载队列'
                            : '点此查看下载队列并继续',
                        style: TextStyle(fontSize: 11, color: p.textFaint),
                      ),
                      if (running.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: 3,
                            backgroundColor: p.progressTrack,
                            valueColor: AlwaysStoppedAnimation(p.accent),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.chevron_right, size: 18, color: p.textFaint),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.p,
    required this.hasTasks,
    required this.onBrowse,
    required this.onOpenDownloads,
  });

  final AppPalette p;

  /// 有下载任务但还没产出文件：说明文件会在完成后出现
  final bool hasTasks;
  final VoidCallback onBrowse;
  final VoidCallback onOpenDownloads;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.folder_open_outlined, size: 54, color: p.textDisabled),
            const SizedBox(height: 14),
            Text(
              hasTasks ? '下载完成后文件会显示在这里' : '还没有文件',
              style: TextStyle(color: p.textFaint),
            ),
            const SizedBox(height: 6),
            Text(
              hasTasks
                  ? '任务还在进行，去「下载」查看进度；完成后无需手动刷新'
                  : '在「浏览器」里打开视频页面，\n用 Nerelict 播放后点「下载当前视频」即可',
              textAlign: TextAlign.center,
              style: TextStyle(color: p.textFaint, fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: <Widget>[
                FilledButton.tonalIcon(
                  onPressed: onBrowse,
                  icon: const Icon(Icons.travel_explore, size: 17),
                  label: const Text('去浏览器嗅探'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                  ),
                ),
                if (hasTasks)
                  TextButton.icon(
                    onPressed: onOpenDownloads,
                    icon: const Icon(Icons.download_outlined, size: 17),
                    label: const Text('查看下载'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 筛选或搜索无结果：与「整个目录为空」分开说，避免误导用户去下载。
class _FilterEmpty extends StatelessWidget {
  const _FilterEmpty({required this.p, this.kind, this.query = ''});

  final AppPalette p;
  final LocalFileKind? kind;
  final String query;

  @override
  Widget build(BuildContext context) {
    final hasQuery = query.trim().isNotEmpty;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            hasQuery ? Icons.search_off : Icons.filter_alt_off_outlined,
            size: 40,
            color: p.textDisabled,
          ),
          const SizedBox(height: 10),
          Text(
            hasQuery ? '没有匹配「${query.trim()}」的文件' : '这个分类下还没有文件',
            style: TextStyle(fontSize: 12.5, color: p.textFaint),
          ),
          const SizedBox(height: 4),
          Text(
            hasQuery ? '换个关键词，或清除搜索' : '点一下分类或「全部」查看其他文件',
            style: TextStyle(fontSize: 11, color: p.textDisabled),
          ),
        ],
      ),
    );
  }
}
