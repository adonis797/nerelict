import 'package:flutter/material.dart';

import '../models/theme_mode.dart';

/// 主色，深/浅两套主题共用
const kAccent = Color(0xFF4C8DFF);
const kSuccess = Color(0xFF3DDC97);
const kDanger = Color(0xFFFF6B6B);

/// 赛博朋克 2077 霓虹配色：加载进度、搜索框与赛博主题的点缀色。
const kNeonCyan = Color(0xFF00E5FF);
const kNeonMagenta = Color(0xFFFF2E88);
const kNeonYellow = Color(0xFFFFE94A);
const kNeonViolet = Color(0xFF7C5CFF);

/// 应用内自定义配色。深色 / 浅色 / 赛博朋克三套，
/// 通过 [ThemeExtension] 挂在 ThemeData 上，主题切换时所有引用处自动跟随。
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette._({
    required this.brightness,
    required this.bg,
    required this.navBg,
    required this.surface,
    required this.surfaceAlt,
    required this.surfaceDeep,
    required this.border,
    required this.text,
    required this.textSub,
    required this.textFaint,
    required this.textDisabled,
    required this.webBg,
    required this.progressTrack,
    required this.onAccent,
    required this.accent,
    required this.accentAlt,
    required this.glass,
    required this.glassBorder,
    required this.isCyber,
  });

  final Brightness brightness;
  final Color bg;
  final Color navBg;
  final Color surface;
  final Color surfaceAlt;
  final Color surfaceDeep;
  final Color border;
  final Color text;
  final Color textSub;
  final Color textFaint;
  final Color textDisabled;
  final Color webBg;
  final Color progressTrack;
  final Color onAccent;

  /// 当前主题的主强调色（图标 / 选中态）：深/浅色是蓝色，赛博主题是霓虹洋红
  final Color accent;

  /// 辅助强调色（赛博主题的青色）
  final Color accentAlt;

  /// 播放器浮层的玻璃拟态底色与描边
  final Color glass;
  final Color glassBorder;

  /// 是否为赛博朋克主题：少数需要额外装饰（扫描线 / 霓虹网格）的地方据此判断
  final bool isCyber;

  static const dark = AppPalette._(
    brightness: Brightness.dark,
    bg: Color(0xFF0D1016),
    navBg: Color(0xFF12151C),
    surface: Color(0xFF161B24),
    surfaceAlt: Color(0xFF1B2029),
    surfaceDeep: Color(0xFF10141B),
    border: Color(0xFF232A36),
    text: Colors.white,
    textSub: Colors.white70,
    textFaint: Colors.white38,
    textDisabled: Colors.white24,
    webBg: Color(0xFF0D1016),
    progressTrack: Color(0xFF232A36),
    onAccent: Colors.white,
    accent: kAccent,
    accentAlt: Color(0xFF2BD8C0),
    glass: Color(0xB8171D27),
    glassBorder: Color(0x1FFFFFFF),
    isCyber: false,
  );

  static const light = AppPalette._(
    brightness: Brightness.light,
    bg: Color(0xFFF4F7FC),
    navBg: Color(0xFFFFFFFF),
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFFEDF2FA),
    surfaceDeep: Color(0xFFF0F4FA),
    border: Color(0xFFDCE3EE),
    text: Color(0xFF16202E),
    textSub: Color(0xFF54627A),
    textFaint: Color(0xFF8A97AB),
    textDisabled: Color(0xFFB7C1D0),
    webBg: Color(0xFFFFFFFF),
    progressTrack: Color(0xFFE4EAF4),
    onAccent: Colors.white,
    accent: kAccent,
    accentAlt: Color(0xFF0FB5A6),
    glass: Color(0xC2FFFFFF),
    glassBorder: Color(0xE6FFFFFF),
    isCyber: false,
  );

  /// 赛博朋克 2077 × 狂野美漫：深紫黑底 + 霓虹洋红/青色描边，强对比、硬边框。
  static const cyber = AppPalette._(
    brightness: Brightness.dark,
    bg: Color(0xFF07030F),
    navBg: Color(0xFF120720),
    surface: Color(0xFF170B26),
    surfaceAlt: Color(0xFF1F1033),
    surfaceDeep: Color(0xFF0B0518),
    border: Color(0xFF4A1B70),
    text: Color(0xFFF3F8FF),
    textSub: Color(0xFFCBB6F0),
    textFaint: Color(0xFF9A82C4),
    textDisabled: Color(0xFF6A5590),
    webBg: Color(0xFF0B0518),
    progressTrack: Color(0xFF2A1440),
    onAccent: Colors.white,
    accent: kNeonMagenta,
    accentAlt: kNeonCyan,
    glass: Color(0xC20A0418),
    glassBorder: Color(0x33FF2E88),
    isCyber: true,
  );

  static AppPalette of(AppThemeMode mode) => switch (mode) {
        AppThemeMode.dark => dark,
        AppThemeMode.light => light,
        AppThemeMode.cyber => cyber,
      };

  @override
  AppPalette copyWith({
    Brightness? brightness,
    Color? bg,
    Color? navBg,
    Color? surface,
    Color? surfaceAlt,
    Color? surfaceDeep,
    Color? border,
    Color? text,
    Color? textSub,
    Color? textFaint,
    Color? textDisabled,
    Color? webBg,
    Color? progressTrack,
    Color? onAccent,
    Color? accent,
    Color? accentAlt,
    Color? glass,
    Color? glassBorder,
    bool? isCyber,
  }) {
    return AppPalette._(
      brightness: brightness ?? this.brightness,
      bg: bg ?? this.bg,
      navBg: navBg ?? this.navBg,
      surface: surface ?? this.surface,
      surfaceAlt: surfaceAlt ?? this.surfaceAlt,
      surfaceDeep: surfaceDeep ?? this.surfaceDeep,
      border: border ?? this.border,
      text: text ?? this.text,
      textSub: textSub ?? this.textSub,
      textFaint: textFaint ?? this.textFaint,
      textDisabled: textDisabled ?? this.textDisabled,
      webBg: webBg ?? this.webBg,
      progressTrack: progressTrack ?? this.progressTrack,
      onAccent: onAccent ?? this.onAccent,
      accent: accent ?? this.accent,
      accentAlt: accentAlt ?? this.accentAlt,
      glass: glass ?? this.glass,
      glassBorder: glassBorder ?? this.glassBorder,
      isCyber: isCyber ?? this.isCyber,
    );
  }

  @override
  AppPalette lerp(covariant AppPalette? other, double t) {
    if (other == null) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppPalette._(
      brightness: t < 0.5 ? brightness : other.brightness,
      bg: c(bg, other.bg),
      navBg: c(navBg, other.navBg),
      surface: c(surface, other.surface),
      surfaceAlt: c(surfaceAlt, other.surfaceAlt),
      surfaceDeep: c(surfaceDeep, other.surfaceDeep),
      border: c(border, other.border),
      text: c(text, other.text),
      textSub: c(textSub, other.textSub),
      textFaint: c(textFaint, other.textFaint),
      textDisabled: c(textDisabled, other.textDisabled),
      webBg: c(webBg, other.webBg),
      progressTrack: c(progressTrack, other.progressTrack),
      onAccent: c(onAccent, other.onAccent),
      accent: c(accent, other.accent),
      accentAlt: c(accentAlt, other.accentAlt),
      glass: c(glass, other.glass),
      glassBorder: c(glassBorder, other.glassBorder),
      isCyber: t < 0.5 ? isCyber : other.isCyber,
    );
  }
}

AppPalette paletteOf(BuildContext context) {
  final theme = Theme.of(context);
  return theme.extension<AppPalette>() ??
      (theme.brightness == Brightness.light
          ? AppPalette.light
          : AppPalette.dark);
}

ThemeData buildAppTheme(AppThemeMode mode) {
  final p = AppPalette.of(mode);
  final scheme = ColorScheme.fromSeed(
    seedColor: p.accent,
    brightness: p.brightness,
  ).copyWith(
    surface: p.surface,
    primary: p.accent,
    secondary: p.accentAlt,
    onPrimary: p.onAccent,
  );

  final base = (p.brightness == Brightness.light
          ? ThemeData.light()
          : ThemeData.dark())
      .textTheme
      .apply(bodyColor: p.text, displayColor: p.text);

  return ThemeData(
    useMaterial3: true,
    brightness: p.brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.bg,
    extensions: <ThemeExtension<dynamic>>[p],
    appBarTheme: AppBarTheme(
      backgroundColor: p.bg,
      foregroundColor: p.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(p.isCyber ? 4 : 16),
        side: p.isCyber ? BorderSide(color: p.border) : BorderSide.none,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(p.isCyber ? 4 : 14),
        side: p.isCyber
            ? BorderSide(color: p.accent, width: 1.1)
            : BorderSide.none,
      ),
    ),
    dividerColor: p.border,
    iconTheme: IconThemeData(color: p.textSub),
    textTheme: base,
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.isCyber ? p.surfaceAlt : null,
      shape: p.isCyber
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
              side: BorderSide(color: p.accent, width: 1),
            )
          : null,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: p.navBg,
      surfaceTintColor: Colors.transparent,
      indicatorColor: p.accent.withValues(alpha: p.isCyber ? 0.30 : 0.18),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 12,
          letterSpacing: p.isCyber ? 0.6 : 0,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.w400,
          color: states.contains(WidgetState.selected) ? p.accent : p.textFaint,
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.accent,
        foregroundColor: p.onAccent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(p.isCyber ? 3 : 8),
        ),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.white
            : p.textFaint,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? p.accent
            : p.border,
      ),
    ),
  );
}
