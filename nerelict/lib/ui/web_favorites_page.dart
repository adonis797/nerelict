import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/web_favorite.dart';
import '../state/app_state.dart';
import '../state/web_favorites_state.dart';
import 'app_theme.dart';
import 'widgets/app_menu.dart';
import 'site_icon.dart';

/// 独立的单页「全部网页收藏」。
///
/// 支持：编辑标题/地址、自定义分类、把条目长按拖到分类标题上归类
/// （拖到某条条目上则插到它前面，可跨分类）、加入首页快速访问。
/// 点条目把地址返回给浏览器页打开。
class WebFavoritesPage extends StatelessWidget {
  const WebFavoritesPage({super.key});

  Future<void> _clearAll(BuildContext context, int count) async {
    final p = paletteOf(context);
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: p.surface,
            title:
                Text('清空网页收藏', style: TextStyle(fontSize: 16, color: p.text)),
            content: Text('确定删除全部 $count 个网页收藏吗？',
                style: TextStyle(fontSize: 12.5, color: p.textSub)),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text('取消', style: TextStyle(color: p.textFaint)),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: kDanger),
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('清空'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !context.mounted) return;
    await context.read<WebFavoritesState>().clear();
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final favorites = context.watch<WebFavoritesState>();
    final List<WebFavorite> items = favorites.items;

    final groups = favorites.groupOrder
        .where((g) =>
            favorites.itemsOf(g).isNotEmpty ||
            (g.isNotEmpty && favorites.categories.contains(g)))
        .toList();

    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Row(
          children: [
            Text('全部网页收藏',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: p.text,
                )),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: kNeonCyan.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${items.length}',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: kNeonCyan,
                ),
              ),
            ),
          ],
        ),
        actions: <Widget>[
          IconButton(
            tooltip: '粘贴网址收藏',
            icon: const Icon(Icons.add_link, size: 20),
            onPressed: () => _addByUrl(context, favorites),
          ),
          IconButton(
            tooltip: '新建分类',
            icon: const Icon(Icons.create_new_folder_outlined, size: 19),
            onPressed: () => _createCategory(context, favorites),
          ),
          if (items.isNotEmpty)
            TextButton.icon(
              onPressed: () => _clearAll(context, items.length),
              icon: const Icon(Icons.delete_sweep_outlined,
                  size: 16, color: kDanger),
              label: const Text('清空',
                  style: TextStyle(fontSize: 12, color: kDanger)),
            ),
          const SizedBox(width: 6),
        ],
      ),
      body: items.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.bookmarks_outlined,
                      size: 42, color: p.textDisabled),
                  const SizedBox(height: 12),
                  Text('还没有网页收藏',
                      style: TextStyle(fontSize: 13, color: p.textFaint)),
                  const SizedBox(height: 4),
                  Text('在网页页点地址栏右上角「⋮」→ 收藏本页',
                      style: TextStyle(fontSize: 11.5, color: p.textDisabled)),
                  const SizedBox(height: 14),
                  FilledButton.tonalIcon(
                    onPressed: () => _addByUrl(context, favorites),
                    icon: const Icon(Icons.add_link, size: 17),
                    label: const Text('粘贴网址收藏'),
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 9),
                    ),
                  ),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 2, 4, 8),
                  child: Row(
                    children: [
                      Icon(Icons.drag_indicator,
                          size: 14, color: p.textDisabled),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '长按拖到分类标题归类，拖到条目上调整顺序',
                          style: TextStyle(fontSize: 11, color: p.textDisabled),
                        ),
                      ),
                    ],
                  ),
                ),
                for (final group in groups)
                  _GroupSection(
                    group: group,
                    items: favorites.itemsOf(group),
                    state: favorites,
                    onOpen: (url) => Navigator.of(context).pop(url),
                  ),
              ],
            ),
    );
  }

  /// 手动粘贴网址收藏：不依赖 WebView，方便从别处复制链接进来。
  static Future<void> _addByUrl(
    BuildContext context,
    WebFavoritesState favorites,
  ) async {
    final p = paletteOf(context);
    final urlCtrl = TextEditingController();
    final titleCtrl = TextEditingController();
    final app = context.read<AppState>();
    final added = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.surface,
        title: Text('粘贴网址收藏', style: TextStyle(fontSize: 16, color: p.text)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: urlCtrl,
              autofocus: true,
              keyboardType: TextInputType.url,
              style: TextStyle(fontSize: 13, color: p.text),
              decoration: InputDecoration(
                labelText: '网址',
                hintText: 'https://example.com/page',
                labelStyle: TextStyle(fontSize: 12, color: p.textFaint),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: titleCtrl,
              style: TextStyle(fontSize: 13, color: p.text),
              decoration: InputDecoration(
                labelText: '标题（可选）',
                labelStyle: TextStyle(fontSize: 12, color: p.textFaint),
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: p.textFaint)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('收藏'),
          ),
        ],
      ),
    );
    if (added != true) {
      urlCtrl.dispose();
      titleCtrl.dispose();
      return;
    }
    final url = urlCtrl.text.trim();
    final title = titleCtrl.text.trim();
    urlCtrl.dispose();
    titleCtrl.dispose();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      app.showToast('请输入以 http(s):// 开头的网址');
      return;
    }
    final ok = await favorites.toggle(url: url, title: title);
    app.showToast(ok ? '已加入网页收藏' : '已取消收藏');
  }

  static Future<void> _createCategory(
    BuildContext context,
    WebFavoritesState favorites,
  ) async {
    final p = paletteOf(context);
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.surface,
        title: Text('新建分类', style: TextStyle(fontSize: 16, color: p.text)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: TextStyle(fontSize: 13, color: p.text),
          decoration: const InputDecoration(hintText: '例如：视频站 / 学习 / 工具'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('取消', style: TextStyle(color: p.textFaint)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.trim().isEmpty) return;
    await favorites.addCategory(name);
  }
}

class _GroupSection extends StatelessWidget {
  const _GroupSection({
    required this.group,
    required this.items,
    required this.state,
    required this.onOpen,
  });

  /// 空字符串代表「未分类」
  final String group;
  final List<WebFavorite> items;
  final WebFavoritesState state;
  final void Function(String url) onOpen;

  String get _label => group.isEmpty ? '未分类' : group;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);

    return DragTarget<String>(
      onWillAcceptWithDetails: (details) {
        final item = state.find(details.data);
        if (item == null) return false;
        return item.category.trim() != group;
      },
      onAcceptWithDetails: (details) {
        state.dragTo(url: details.data, category: group);
      },
      builder: (context, candidate, _) {
        final hot = candidate.isNotEmpty;
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: hot ? p.accent.withValues(alpha: 0.10) : p.surface,
            borderRadius: BorderRadius.circular(p.isCyber ? 4 : 12),
            border: Border.all(
              color: hot ? p.accent.withValues(alpha: 0.7) : p.border,
              width: hot ? 1.4 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 9, 4, 7),
                child: Row(
                  children: <Widget>[
                    Icon(
                      group.isEmpty
                          ? Icons.folder_off_outlined
                          : Icons.folder_open_outlined,
                      size: 15,
                      color: hot ? p.accent : p.textFaint,
                    ),
                    const SizedBox(width: 7),
                    Text(
                      _label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: hot ? p.accent : p.textSub,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${items.length}',
                      style: TextStyle(fontSize: 10.5, color: p.textDisabled),
                    ),
                    const Spacer(),
                    if (hot)
                      Text(
                        '松手放入「$_label」',
                        style: TextStyle(fontSize: 10.5, color: p.accent),
                      )
                    else if (group.isNotEmpty)
                      Builder(
                        builder: (menuContext) => IconButton(
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints.tightFor(
                              width: 30, height: 30),
                          padding: EdgeInsets.zero,
                          tooltip: '分类操作',
                          icon: Icon(Icons.more_horiz,
                              size: 17, color: p.textFaint),
                          onPressed: () async {
                            final action = await showAppMenu<String>(
                              context: menuContext,
                              anchorContext: menuContext,
                              title: _label,
                              items: const <AppMenuItem<String>>[
                                AppMenuItem<String>(
                                  value: 'rename',
                                  label: '重命名分类',
                                  icon: Icons.drive_file_rename_outline,
                                ),
                                AppMenuItem<String>(
                                  value: 'delete',
                                  label: '删除分类（收藏保留）',
                                  icon: Icons.folder_delete_outlined,
                                  destructive: true,
                                ),
                              ],
                            );
                            if (!context.mounted) return;
                            if (action == 'rename') {
                              await _renameCategory(context, p);
                            } else if (action == 'delete') {
                              await state.removeCategory(group);
                            }
                          },
                        ),
                      ),
                  ],
                ),
              ),
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: Text(
                    hot ? '松手把这条收藏放进此分类' : '把收藏拖到这里归类',
                    style: TextStyle(fontSize: 10.5, color: p.textDisabled),
                  ),
                ),
              for (var i = 0; i < items.length; i++)
                _FavoriteRow(
                  item: items[i],
                  state: state,
                  onOpen: onOpen,
                  isLast: i == items.length - 1,
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _renameCategory(BuildContext context, AppPalette p) async {
    final ctrl = TextEditingController(text: group);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.surface,
        title: Text('重命名分类', style: TextStyle(fontSize: 16, color: p.text)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: TextStyle(fontSize: 13, color: p.text),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('取消', style: TextStyle(color: p.textFaint)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.trim().isEmpty) return;
    await state.renameCategory(group, name);
  }
}

class _FavoriteRow extends StatelessWidget {
  const _FavoriteRow({
    required this.item,
    required this.state,
    required this.onOpen,
    required this.isLast,
  });

  final WebFavorite item;
  final WebFavoritesState state;
  final void Function(String url) onOpen;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);

    final tile = ListTile(
      dense: true,
      contentPadding: const EdgeInsets.fromLTRB(10, 0, 2, 0),
      leading: SiteIcon(
        url: item.url,
        iconUrl: item.iconUrl,
        size: 20,
        radius: 5,
      ),
      title: Text(
        item.displayTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 13, color: p.text),
      ),
      subtitle: Text(
        '${item.host}${item.quickAccess ? ' · 快速访问' : ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 10.5, color: p.textFaint),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (item.quickAccess)
            Padding(
              padding: const EdgeInsets.only(right: 2),
              child: Icon(Icons.bolt, size: 15, color: p.accent),
            ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: item.quickAccess ? '移出快速访问' : '加入快速访问',
            icon: Icon(
              item.quickAccess ? Icons.star : Icons.star_border,
              size: 16,
              color: item.quickAccess ? p.accent : p.textFaint,
            ),
            onPressed: () => state.toggleQuickAccess(item.url),
          ),
          Builder(
            builder: (menuContext) => IconButton(
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 30, height: 30),
              padding: EdgeInsets.zero,
              tooltip: '更多操作',
              icon: Icon(Icons.more_vert, size: 16, color: p.textFaint),
              onPressed: () async {
                final action = await showAppMenu<String>(
                  context: menuContext,
                  anchorContext: menuContext,
                  title: item.displayTitle,
                  items: <AppMenuItem<String>>[
                    const AppMenuItem<String>(
                      value: 'edit',
                      label: '编辑标题 / 地址 / 分类',
                      icon: Icons.edit_outlined,
                    ),
                    AppMenuItem<String>(
                      value: 'quick',
                      label: item.quickAccess ? '移出快速访问' : '加入快速访问',
                      icon: item.quickAccess ? Icons.star : Icons.star_border,
                    ),
                    const AppMenuItem<String>(
                      value: 'top',
                      label: '置顶',
                      icon: Icons.vertical_align_top,
                    ),
                    const AppMenuItem<String>(
                      value: 'delete',
                      label: '删除收藏',
                      icon: Icons.delete_outline,
                      destructive: true,
                    ),
                  ],
                );
                if (!context.mounted) return;
                if (action == 'edit') {
                  await _edit(context);
                } else if (action == 'quick') {
                  await state.toggleQuickAccess(item.url);
                } else if (action == 'top') {
                  final first =
                      state.items.isEmpty ? null : state.items.first.url;
                  if (first != null) {
                    await state.dragTo(url: item.url, beforeUrl: first);
                  }
                } else if (action == 'delete') {
                  await state.remove(item.url);
                }
              },
            ),
          ),
        ],
      ),
      onTap: () => onOpen(item.url),
    );

    return DragTarget<String>(
      onWillAcceptWithDetails: (details) => details.data != item.url,
      onAcceptWithDetails: (details) {
        state.dragTo(
          url: details.data,
          category: item.category,
          beforeUrl: item.url,
        );
      },
      builder: (context, candidate, _) {
        final hot = candidate.isNotEmpty;
        return Column(
          key: ValueKey<String>('fav_row_${item.url}'),
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              decoration: hot
                  ? BoxDecoration(
                      color: p.accent.withValues(alpha: 0.08),
                      border: Border(
                        top: BorderSide(color: p.accent, width: 1.2),
                      ),
                    )
                  : null,
              child: LongPressDraggable<String>(
                data: item.url,
                delay: const Duration(milliseconds: 260),
                feedback: Material(
                  color: Colors.transparent,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: p.surfaceAlt,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: p.accent),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(Icons.drag_indicator, size: 14, color: p.accent),
                        const SizedBox(width: 6),
                        Text(
                          item.displayTitle,
                          style: TextStyle(fontSize: 12, color: p.text),
                        ),
                      ],
                    ),
                  ),
                ),
                childWhenDragging: Opacity(opacity: 0.35, child: tile),
                child: tile,
              ),
            ),
            if (!isLast) Divider(height: 1, color: p.border),
          ],
        );
      },
    );
  }

  Future<void> _edit(BuildContext context) async {
    final p = paletteOf(context);
    final titleCtrl = TextEditingController(text: item.title);
    final urlCtrl = TextEditingController(text: item.url);
    final categoryCtrl = TextEditingController(text: item.category);
    String? error;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: p.surface,
          title: Text('编辑收藏', style: TextStyle(fontSize: 16, color: p.text)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                TextField(
                  controller: titleCtrl,
                  style: TextStyle(fontSize: 13, color: p.text),
                  decoration: const InputDecoration(
                    labelText: '标题',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: urlCtrl,
                  style: TextStyle(fontSize: 12.5, color: p.text),
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: '地址',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: categoryCtrl,
                  style: TextStyle(fontSize: 13, color: p.text),
                  decoration: const InputDecoration(
                    labelText: '分类（留空为未分类）',
                    isDense: true,
                  ),
                ),
                if (state.categories.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: <Widget>[
                      for (final c in state.categories)
                        ActionChip(
                          label: Text(c, style: const TextStyle(fontSize: 11)),
                          onPressed: () =>
                              setLocal(() => categoryCtrl.text = c),
                          visualDensity: VisualDensity.compact,
                        ),
                    ],
                  ),
                ],
                if (error != null) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(error!,
                      style: const TextStyle(fontSize: 11.5, color: kDanger)),
                ],
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('取消', style: TextStyle(color: p.textFaint)),
            ),
            FilledButton(
              onPressed: () async {
                final category = categoryCtrl.text.trim();
                if (category.isNotEmpty) await state.addCategory(category);
                final err = await state.updateItem(
                  oldUrl: item.url,
                  title: titleCtrl.text,
                  url: urlCtrl.text,
                  iconUrl: item.iconUrl,
                );
                if (err != null) {
                  setLocal(() => error = err);
                  return;
                }
                await state.moveToCategory(
                  urlCtrl.text.trim(),
                  category,
                );
                if (ctx.mounted) Navigator.of(ctx).pop();
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    titleCtrl.dispose();
    urlCtrl.dispose();
    categoryCtrl.dispose();
  }
}
