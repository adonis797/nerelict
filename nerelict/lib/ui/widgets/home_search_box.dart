import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/settings_state.dart';
import '../app_theme.dart';

/// 首页搜索框：唯一的输入焦点。
///
/// 主界面起始页与多窗口里的新标签页共用同一个组件：两处的输入语义一致
/// （搜索词走设置里的搜索引擎，网址直接打开），样式也不该各写一套。
///
/// 描边只在聚焦时变成主色（原来是常驻的霓虹渐变环，和其余组件不是一套语言），
/// 右侧按钮是实心主色圆——整页只有一个强调色，注意力才落得住。
class HomeSearchBox extends StatefulWidget {
  const HomeSearchBox({
    super.key,
    required this.onSubmit,
    this.autofocus = false,
    this.hint,
  });

  final void Function(String) onSubmit;

  /// 新标签页里自动聚焦，省掉一次点击（主界面起始页保持不抢焦点）。
  final bool autofocus;

  /// 覆盖默认提示文案。
  final String? hint;

  @override
  State<HomeSearchBox> createState() => _HomeSearchBoxState();
}

class _HomeSearchBoxState extends State<HomeSearchBox> {
  final TextEditingController _ctrl = TextEditingController();
  final FocusNode _focus = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!mounted) return;
      setState(() => _focused = _focus.hasFocus);
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    _focus.unfocus();
    widget.onSubmit(text);
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final engine = context.watch<SettingsState>().searchEngine;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          height: 52,
          padding: const EdgeInsets.all(1.2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            color: _focused
                ? p.accent.withValues(alpha: p.isCyber ? 0.85 : 0.55)
                : p.border,
            boxShadow: _focused
                ? <BoxShadow>[
                    BoxShadow(
                      color: p.accent.withValues(alpha: 0.22),
                      blurRadius: 14,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Container(
            padding: const EdgeInsets.only(left: 15, right: 6),
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(25),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.search,
                  size: 19,
                  color: _focused ? p.accent : p.textFaint,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    focusNode: _focus,
                    autofocus: widget.autofocus,
                    textInputAction: TextInputAction.search,
                    textAlignVertical: TextAlignVertical.center,
                    autocorrect: false,
                    style: TextStyle(fontSize: 14, color: p.text),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: widget.hint ?? '搜索或输入网址 · ${engine.label}',
                      hintStyle: TextStyle(fontSize: 13.5, color: p.textFaint),
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                ),
                InkWell(
                  onTap: _submit,
                  customBorder: const CircleBorder(),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: p.accent,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.arrow_forward,
                        size: 19, color: p.onAccent),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
