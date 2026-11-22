import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/settings_state.dart';
import '../app_theme.dart';

/// 首页搜索框：霓虹渐变描边 + 聚焦光晕，提交后交给调用方决定去哪。
///
/// 主界面起始页与多窗口里的新标签页共用同一个组件：两处的输入语义一致
/// （搜索词走设置里的搜索引擎，网址直接打开），样式也不该各写一套。
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
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          padding: const EdgeInsets.all(1.2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: _focused
                  ? const <Color>[kNeonCyan, Color(0xFF7C5CFF), kNeonMagenta]
                  : <Color>[
                      p.border,
                      p.border,
                    ],
            ),
            boxShadow: _focused
                ? <BoxShadow>[
                    BoxShadow(
                      color: kNeonCyan.withValues(alpha: 0.30),
                      blurRadius: 18,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Container(
            height: 48,
            padding: const EdgeInsets.only(left: 15, right: 7),
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(27),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.search,
                  size: 18,
                  color: _focused ? kNeonCyan : p.textFaint,
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
                    style: TextStyle(fontSize: 13.5, color: p.text),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: widget.hint ?? '搜索或输入网址 · ${engine.label}',
                      hintStyle: TextStyle(fontSize: 13, color: p.textFaint),
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                ),
                InkWell(
                  onTap: _submit,
                  borderRadius: BorderRadius.circular(18),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: <Color>[kNeonCyan, kNeonMagenta],
                      ),
                    ),
                    child: const Icon(Icons.arrow_forward,
                        size: 17, color: Colors.white),
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
