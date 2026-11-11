/// 应用主题模式。
///
/// 独立成文件是为了让 `state` 与 `ui` 两层都能引用，避免状态层反向依赖 UI。
enum AppThemeMode { dark, light, cyber }

extension AppThemeModeX on AppThemeMode {
  String get label => switch (this) {
        AppThemeMode.dark => '深色',
        AppThemeMode.light => '浅色',
        AppThemeMode.cyber => '赛博朋克 · 狂野美漫',
      };

  String get shortLabel => switch (this) {
        AppThemeMode.dark => '深色',
        AppThemeMode.light => '浅色',
        AppThemeMode.cyber => '赛博朋克',
      };

  String get storageValue => switch (this) {
        AppThemeMode.dark => 'dark',
        AppThemeMode.light => 'light',
        AppThemeMode.cyber => 'cyber',
      };

  bool get isLight => this == AppThemeMode.light;

  /// 读取存储值；老版本只有布尔开关 `light_theme`，这里做一次兼容迁移。
  static AppThemeMode fromStorage(String? value, {bool legacyLight = false}) {
    return switch (value) {
      'light' => AppThemeMode.light,
      'cyber' => AppThemeMode.cyber,
      'dark' => AppThemeMode.dark,
      _ => legacyLight ? AppThemeMode.light : AppThemeMode.dark,
    };
  }
}
