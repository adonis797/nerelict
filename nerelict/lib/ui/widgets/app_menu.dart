import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_theme.dart';

/// 一个下拉菜单条目。
///
/// 用纯数据描述，菜单渲染、选中态、禁用态都在 [showAppMenu] 里统一处理，
/// 各处只需要提供数据，避免每个页面各写一套 PopupMenuItem 样式。
@immutable
class AppMenuItem<T> {
  const AppMenuItem({
    required this.value,
    required this.label,
    this.icon,
    this.trailingText,
    this.destructive = false,
    this.enabled = true,
  });

  final T value;
  final String label;
  final IconData? icon;

  /// 右侧补充说明（例如「当前」「推荐」），可为空
  final String? trailingText;

  /// 危险操作：文字用警示色
  final bool destructive;

  final bool enabled;
}

/// 主题化下拉菜单：贴着锚点弹出、自动翻转/避让屏幕边缘。
///
/// 与系统 [PopupMenuButton] 的差异：
/// - 背景、描边、圆角、阴影跟随 [AppPalette]，赛博主题是洋红硬边框；
/// - 宽度自适应锚点并限制在安全区内，右侧对齐锚点，超出底部自动向上翻；
/// - 选中项有强调色底与勾选标记，危险项用警示色；
/// - 统一 150ms 淡入与 46px 行高，避免各页面菜单高低不一。
///
/// 返回被选中的值；点击遮罩或返回键返回 null。
Future<T?> showAppMenu<T>({
  required BuildContext context,
  required List<AppMenuItem<T>> items,
  T? selected,
  String? title,
  BuildContext? anchorContext,
  GlobalKey? anchorKey,
  double minWidth = 172,
  double maxWidth = 272,
  bool alignRight = true,
}) async {
  if (items.isEmpty) return null;

  final anchor = anchorContext ?? anchorKey?.currentContext;
  final anchorBox = anchor?.findRenderObject() as RenderBox?;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  if (anchorBox == null || overlay == null || !anchorBox.hasSize) return null;

  final p = paletteOf(context);
  final media = MediaQuery.of(context);
  final screen = media.size;
  final safe = media.padding;

  final origin = anchorBox.localToGlobal(Offset.zero, ancestor: overlay);
  final rect = origin & anchorBox.size;

  final available = math.max(160.0, screen.width - 24);
  final width = math.min(
    math.max(rect.width, minWidth),
    math.min(maxWidth, available),
  );

  var left = alignRight ? rect.right - width : rect.left;
  left = left.clamp(12.0, math.max(12.0, screen.width - width - 12));

  // 估高只用于判断是否需要向上翻转，实际高度仍由内容决定。
  final estimatedHeight = items.length * 46 + (title == null ? 0 : 34) + 12;
  var top = rect.bottom + 6;
  final maxBottom = screen.height - safe.bottom - 12;
  if (top + estimatedHeight > maxBottom) {
    // 下方空间不足：优先翻到锚点上方，仍放不下就贴住可用区域底部。
    final flipped = rect.top - estimatedHeight - 6;
    top = flipped >= safe.top + 8
        ? flipped
        : math.max(safe.top + 8, maxBottom - estimatedHeight);
  }

  final value = await showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭菜单',
    barrierColor: Colors.black.withValues(alpha: p.isCyber ? 0.34 : 0.16),
    transitionDuration: const Duration(milliseconds: 150),
    pageBuilder: (dialogContext, _, __) => _AppMenuLayer<T>(
      left: left,
      top: top,
      width: width,
      title: title,
      items: items,
      selected: selected,
      palette: p,
    ),
    transitionBuilder: (_, animation, __, child) => FadeTransition(
        opacity: CurvedAnimation(
          parent: animation,
          curve: Curves.easeOut,
        ),
        child: child),
  );

  return value;
}

class _AppMenuLayer<T> extends StatelessWidget {
  const _AppMenuLayer({
    required this.left,
    required this.top,
    required this.width,
    required this.items,
    required this.selected,
    required this.palette,
    this.title,
  });

  final double left;
  final double top;
  final double width;
  final String? title;
  final List<AppMenuItem<T>> items;
  final T? selected;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final radius = p.isCyber ? 4.0 : 14.0;

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: <Widget>[
          Positioned(
            left: left,
            top: top,
            width: width,
            child: Container(
              decoration: BoxDecoration(
                color: p.isCyber
                    ? p.surfaceAlt
                    : (p.brightness == Brightness.light
                        ? p.surface
                        : p.surfaceAlt),
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(
                  color:
                      p.isCyber ? p.accent.withValues(alpha: 0.60) : p.border,
                  width: p.isCyber ? 1.1 : 1,
                ),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(
                      alpha: p.isCyber ? 0.55 : 0.22,
                    ),
                    blurRadius: p.isCyber ? 18 : 24,
                    offset: const Offset(0, 8),
                  ),
                  if (p.isCyber)
                    BoxShadow(
                      color: p.accent.withValues(alpha: 0.18),
                      blurRadius: 22,
                      spreadRadius: 1,
                    ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Material(
                type: MaterialType.transparency,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (title != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 11, 14, 5),
                        child: Text(
                          (title ?? '').toUpperCase(),
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: p.isCyber ? 1.2 : 0.6,
                            color: p.textDisabled,
                          ),
                        ),
                      ),
                    for (final item in items)
                      _AppMenuRow<T>(
                        item: item,
                        selected: selected == item.value,
                        palette: p,
                      ),
                    const SizedBox(height: 5),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AppMenuRow<T> extends StatelessWidget {
  const _AppMenuRow({
    required this.item,
    required this.selected,
    required this.palette,
  });

  final AppMenuItem<T> item;
  final bool selected;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final color = !item.enabled
        ? p.textDisabled
        : item.destructive
            ? kDanger
            : selected
                ? p.accent
                : p.text;

    return InkWell(
      onTap:
          item.enabled ? () => Navigator.of(context).pop<T>(item.value) : null,
      child: Container(
        height: 46,
        padding: const EdgeInsets.symmetric(horizontal: 13),
        color: selected
            ? p.accent.withValues(alpha: p.isCyber ? 0.16 : 0.09)
            : null,
        child: Row(
          children: <Widget>[
            if (item.icon != null) ...<Widget>[
              Icon(item.icon, size: 17, color: color),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: color,
                ),
              ),
            ),
            if (item.trailingText != null)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  item.trailingText!,
                  style: TextStyle(fontSize: 10.5, color: p.textFaint),
                ),
              ),
            if (selected) ...<Widget>[
              const SizedBox(width: 6),
              Icon(Icons.check, size: 16, color: p.accent),
            ],
          ],
        ),
      ),
    );
  }
}

/// 带锚点的菜单按钮：写法与 IconButton 一致，但菜单样式统一。
class AppMenuIconButton extends StatelessWidget {
  const AppMenuIconButton({
    super.key,
    required this.icon,
    required this.items,
    required this.onSelected,
    this.tooltip,
    this.size = 20,
    this.color,
    this.selected,
    this.title,
  });

  final IconData icon;
  final List<AppMenuItem<Object?>> items;
  final ValueChanged<Object?> onSelected;
  final String? tooltip;
  final double size;
  final Color? color;
  final Object? selected;
  final String? title;

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (buttonContext) => IconButton(
        tooltip: tooltip,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 36, height: 36),
        icon:
            Icon(icon, size: size, color: color ?? paletteOf(context).textSub),
        onPressed: () async {
          final value = await showAppMenu<Object?>(
            context: buttonContext,
            anchorContext: buttonContext,
            items: items,
            selected: selected,
            title: title,
          );
          if (value != null) onSelected(value);
        },
      ),
    );
  }
}
