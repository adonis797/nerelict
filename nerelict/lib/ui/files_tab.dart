import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/download_task.dart';
import '../services/local_media_scanner.dart';
import '../services/playback_memory.dart';
import '../state/app_state.dart';
import 'app_theme.dart';
import 'download_tasks_page.dart';
import 'file_manager_sheet.dart';
import 'mp4_convert_sheet.dart';

/// 「文件」标签页：只负责下载目录里的文件。
///
/// 下载队列被拆到独立的「下载」分支（顶部菜单进入），因此这里不再排除
/// 已完成任务引用的文件：任务一完成，产物就能在文件列表里看到。
class FilesTab extends StatefulWidget {
  const FilesTab({super.key});

  @override
  State<FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends State<FilesTab> {
  late final AppState _app;
  PlaybackRecord? _resume;

  /// 文件类型筛选：null 表示「全部」
  LocalFileKind? _filter;

  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>();
    _app.addBackInterceptor(_handleSystemBack);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _app.refreshLocalFiles();
      _loadResume();
    });
  }

  @override
  void dispose() {
    _app.removeBackInterceptor(_handleSystemBack);
    super.dispose();
  }

  /// 系统返回：先收起类型筛选，再交回 HomeScreen 处理。
  Future<bool> _handleSystemBack() async {
    if (_filter == null) return false;
    setState(() => _filter = null);
    return true;
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

  Future<void> _openDownloads() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const DownloadTasksPage()),
    );
    if (!mounted) return;
    // 下载页里可能转换/清理过文件，回来重新扫一次
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

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final p = paletteOf(context);
    final files = state.localFiles;

    final kinds = <LocalFileKind>{...files.map((f) => f.kind)}.toList()
      ..sort((a, b) => a.index.compareTo(b.index));

    final filter = _filter;
    final visible =
        filter == null ? files : files.where((f) => f.kind == filter).toList();

    final unfinished = state.tasks.where((t) => !t.status.isFinished).toList();

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('文件', style: TextStyle(fontSize: 17)),
        actions: <Widget>[
          if (_resume != null)
            IconButton(
              tooltip: '继续观看 · 已看到 ${_resume!.progressText}',
              icon: const Icon(Icons.play_circle_outline, size: 20),
              onPressed: _openResume,
            ),
          IconButton(
            tooltip: 'MP4 转换（批量）',
            icon: const Icon(Icons.movie_creation_outlined, size: 20),
            onPressed: () => showMp4ConvertSheet(context),
          ),
          IconButton(
            tooltip: files.isEmpty ? '暂无可管理文件' : '文件管理（${files.length} 个）',
            icon: const Icon(Icons.folder_open_outlined, size: 20),
            onPressed: () => showFileManagerSheet(
              context,
              paths: files.map((f) => f.path).toList(),
              onChanged: _onFilesChanged,
            ),
          ),
          IconButton(
            tooltip: '重新扫描下载目录',
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: () {
              state.refreshLocalFiles();
              _loadResume();
            },
          ),
          // 下载队列入口：取代原来的清理扫把，扫把移到下载页里
          IconButton(
            tooltip: state.activeCount > 0
                ? '下载管理（${state.activeCount} 个进行中）'
                : '下载管理',
            icon: Badge(
              isLabelVisible: state.activeCount > 0,
              label: Text('${state.activeCount}'),
              child: const Icon(Icons.download_outlined, size: 20),
            ),
            onPressed: _openDownloads,
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          if (state.lastScanIncomplete)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              color: Theme.of(context).colorScheme.errorContainer,
              child: Row(
                children: <Widget>[
                  Icon(Icons.warning_amber_outlined,
                      size: 16,
                      color: Theme.of(context).colorScheme.onErrorContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '部分文件暂时无法读取，已保留上次的列表',
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onErrorContainer),
                    ),
                  ),
                ],
              ),
            ),
          if (_resume != null)
            _ResumeBanner(record: _resume!, onOpen: _openResume, p: p),
          if (unfinished.isNotEmpty)
            _ActiveDownloadsBanner(
              tasks: unfinished,
              p: p,
              onOpen: _openDownloads,
            ),
          if (kinds.isNotEmpty)
            _FilterBar(
              kinds: kinds,
              selected: filter,
              counts: <LocalFileKind, int>{
                for (final k in kinds)
                  k: files.where((f) => f.kind == k).length,
              },
              total: files.length,
              onSelect: (kind) => setState(() => _filter = kind),
              p: p,
            ),
          Expanded(
            child: files.isEmpty
                ? _EmptyState(
                    p: p,
                    hasTasks: state.tasks.isNotEmpty,
                    onBrowse: () => state.setTab(0),
                    onOpenDownloads: _openDownloads,
                  )
                : visible.isEmpty
                    ? _FilterEmpty(p: p, kind: filter)
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
                        itemCount: visible.length,
                        itemBuilder: (context, i) => _LocalFileTile(
                          file: visible[i],
                          onFilesChanged: _onFilesChanged,
                        ),
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
                        style: TextStyle(fontSize: 10.5, color: p.textFaint),
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

/// 文件类型筛选条：全部 + 实际出现过的类型（带数量）
class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.kinds,
    required this.selected,
    required this.counts,
    required this.total,
    required this.onSelect,
    required this.p,
  });

  final List<LocalFileKind> kinds;
  final LocalFileKind? selected;
  final Map<LocalFileKind, int> counts;
  final int total;
  final void Function(LocalFileKind? kind) onSelect;
  final AppPalette p;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: <Widget>[
          _chip('全部', total, selected == null, () => onSelect(null)),
          for (final k in kinds)
            _chip(k.label, counts[k] ?? 0, selected == k, () => onSelect(k)),
        ],
      ),
    );
  }

  Widget _chip(String label, int count, bool active, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
          decoration: BoxDecoration(
            color: active ? p.accent.withValues(alpha: 0.16) : p.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: active ? p.accent.withValues(alpha: 0.55) : p.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: active ? p.accent : p.textSub,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 10,
                  color: active ? p.accent : p.textDisabled,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 最近一次播放的续播入口：不改动原下载任务卡片布局，只在列表上方加一条。
class _ResumeBanner extends StatelessWidget {
  const _ResumeBanner({
    required this.record,
    required this.onOpen,
    required this.p,
  });

  final PlaybackRecord record;
  final VoidCallback onOpen;
  final AppPalette p;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 2),
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.border),
      ),
      child: Row(
        children: [
          const Icon(Icons.smart_display_outlined, size: 19, color: kAccent),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '继续观看 · ${record.title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: p.text),
                ),
                const SizedBox(height: 2),
                Text(
                  'MA8N · 上次看到 ${record.progressText}',
                  style: TextStyle(fontSize: 10.5, color: p.textFaint),
                ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: onOpen,
            icon: const Icon(Icons.play_arrow, size: 16),
            label: const Text('续播', style: TextStyle(fontSize: 12)),
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
          ),
        ],
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
                  : '在「浏览器」里打开视频页面，\n用 MA8N 播放后点「下载当前视频」即可',
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

/// 选中某类型但该类型下没有文件时的占位提示
class _FilterEmpty extends StatelessWidget {
  const _FilterEmpty({required this.p, this.kind});

  final AppPalette p;
  final LocalFileKind? kind;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.filter_alt_off_outlined, size: 40, color: p.textDisabled),
          const SizedBox(height: 10),
          Text(
            '当前筛选下没有文件',
            style: TextStyle(fontSize: 12.5, color: p.textFaint),
          ),
          const SizedBox(height: 4),
          Text(
            '点上方「全部」查看所有已下载文件',
            style: TextStyle(fontSize: 11, color: p.textDisabled),
          ),
        ],
      ),
    );
  }
}

/// 点击整条直接用 MA8N播放：视频可播放，其他类型打开文件管理（信息 / 重命名 / 删除）
class _LocalFileTile extends StatelessWidget {
  const _LocalFileTile({required this.file, required this.onFilesChanged});

  final LocalFile file;
  final VoidCallback onFilesChanged;

  static String _date(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';

  IconData get _icon => switch (file.kind) {
        LocalFileKind.video =>
          file.isMp4 ? Icons.video_file_outlined : Icons.movie_outlined,
        LocalFileKind.audio => Icons.audiotrack_outlined,
        LocalFileKind.image => Icons.image_outlined,
        LocalFileKind.document => Icons.description_outlined,
        LocalFileKind.archive => Icons.folder_zip_outlined,
        LocalFileKind.other => Icons.insert_drive_file_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final state = context.read<AppState>();

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.border),
      ),
      child: ListTile(
        dense: true,
        leading: Icon(_icon, size: 20, color: p.accent),
        title: Text(
          file.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 13, color: p.text),
        ),
        subtitle: Text(
          '${file.typeLabel} · ${file.sizeText} · ${_date(file.modifiedAt)}',
          style: TextStyle(fontSize: 10.5, color: p.textFaint),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: '文件信息 / 重命名 / 删除',
              icon: Icon(Icons.tune, size: 18, color: p.textFaint),
              onPressed: () => showFileManagerSheet(
                context,
                paths: <String>[file.path],
                onChanged: onFilesChanged,
              ),
            ),
            if (file.isPlayable)
              Icon(Icons.play_circle_outline, size: 20, color: p.accent)
            else
              Icon(Icons.chevron_right, size: 20, color: p.textFaint),
          ],
        ),
        onTap: file.isPlayable
            ? () => state.openPlayer(
                  url: file.path,
                  title: file.title,
                  local: true,
                )
            : () => showFileManagerSheet(
                  context,
                  paths: <String>[file.path],
                  onChanged: onFilesChanged,
                ),
      ),
    );
  }
}
