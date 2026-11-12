import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/theme_mode.dart';
import '../services/streaming_proxy.dart';

/// 播放缓存上限的可选档位（MB），设置页与持久化共用。
const List<int> kCacheLimitOptionsMb = <int>[64, 128, 256, 512, 1024];
const int kDefaultCacheLimitMb = 256;

/// 地址栏搜索使用的搜索引擎。
enum SearchEngine { google, bing }

extension SearchEngineX on SearchEngine {
  String get label => switch (this) {
        SearchEngine.google => 'Google',
        SearchEngine.bing => 'Bing',
      };

  String get storageValue => switch (this) {
        SearchEngine.google => 'google',
        SearchEngine.bing => 'bing',
      };

  String searchUrl(String query) {
    final q = Uri.encodeQueryComponent(query);
    return switch (this) {
      SearchEngine.google => 'https://www.google.com/search?q=$q',
      SearchEngine.bing => 'https://www.bing.com/search?q=$q',
    };
  }

  static SearchEngine fromStorage(String? value) =>
      value == 'bing' ? SearchEngine.bing : SearchEngine.google;
}

/// 全局设置：持久化到 SharedPreferences，启动时同步载入避免主题闪烁。
class SettingsState extends ChangeNotifier {
  static const _kLightTheme = 'light_theme'; // 旧版本布尔开关，仅用于迁移
  static const _kThemeMode = 'theme_mode';
  static const _kAutoTakeover = 'auto_takeover';
  static const _kMp4Conversion = 'mp4_conversion';
  static const _kSearchEngine = 'search_engine';

  // 播放器与运行偏好，全部有保守默认值
  static const _kPlayerMediaControls = 'player_media_controls';
  static const _kPlayerAutoResume = 'player_auto_resume';
  static const _kPlayerGestures = 'player_gestures';
  static const _kPlayerStreamingCache = 'player_streaming_cache';
  static const _kPlayerCacheLimitMb = 'player_cache_limit_mb';
  static const _kPlayerSpeed = 'player_speed';
  static const _kKeepScreenOn = 'keep_screen_on';
  static const _kDownloadConcurrency = 'download_concurrency';
  static const _kWifiOnly = 'download_wifi_only';
  static const _kDownloadRetries = 'download_retries';
  static const _kGestureTipSeen = 'player_gesture_tip_seen';

  /// 用户自选下载位置（SAF 目录树 URI）与友好名称，由 AppState 读取
  static const kDownloadDirUri = 'download_dir_uri';
  static const kDownloadDirName = 'download_dir_name';

  AppThemeMode _themeMode = AppThemeMode.dark;
  bool _autoTakeover = true;
  bool _mp4Conversion = true;
  SearchEngine _searchEngine = SearchEngine.google;
  String? _downloadDirUri;
  String? _downloadDirName;

  bool _playerMediaControls = false;
  bool _playerAutoResume = true;
  bool _playerGestures = true;
  bool _playerStreamingCache = false;
  int _playerCacheLimitMb = kDefaultCacheLimitMb;
  double _playerSpeed = 1.0;

  /// 应用在前台时保持屏幕常亮（默认开启，避免下载/转换被息屏打断）
  bool _keepScreenOn = true;

  /// 同时进行的下载任务数（1-3，默认 2）
  int _downloadConcurrency = 2;

  /// 仅在 Wi-Fi 下下载（默认关闭）
  bool _wifiOnly = false;

  /// 失败自动重试次数（0-3，默认 1）
  int _downloadRetries = 1;

  /// 播放器手势引导是否已展示过（只提示一次）
  bool _gestureTipSeen = false;

  bool _ready = false;

  AppThemeMode get themeMode => _themeMode;

  /// 兼容旧调用：只有浅色主题才算「浅色」
  bool get lightTheme => _themeMode == AppThemeMode.light;
  bool get autoTakeover => _autoTakeover;
  bool get mp4Conversion => _mp4Conversion;
  SearchEngine get searchEngine => _searchEngine;
  bool get ready => _ready;
  String? get downloadDirUri => _downloadDirUri;
  String? get downloadDirName => _downloadDirName;

  /// 通知栏 / 锁屏媒体控制与音频焦点（默认关闭，避免影响原有播放）
  bool get playerMediaControls => _playerMediaControls;

  /// 从上次位置续播
  bool get playerAutoResume => _playerAutoResume;

  /// 画面手势（亮度 / 音量 / 进度 / 长按倍速）
  bool get playerGestures => _playerGestures;

  /// 边下边播：本地代理缓存 HLS 分片（默认关闭）
  bool get playerStreamingCache => _playerStreamingCache;

  /// 播放缓存上限（MB），默认 256；写入时同步给本地代理
  int get playerCacheLimitMb => _playerCacheLimitMb;

  /// 默认倍速，播放器中调整后会记住
  double get playerSpeed => _playerSpeed;

  /// 倍速的展示文案：整数去掉小数位
  String get playerSpeedLabel => _playerSpeed == _playerSpeed.roundToDouble()
      ? '${_playerSpeed.toInt()}x'
      : '${_playerSpeed}x';

  bool get gestureTipSeen => _gestureTipSeen;

  /// 屏幕常亮：前台运行时阻止系统自动息屏
  bool get keepScreenOn => _keepScreenOn;

  int get downloadConcurrency => _downloadConcurrency;
  bool get wifiOnly => _wifiOnly;
  int get downloadRetries => _downloadRetries;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _themeMode = AppThemeModeX.fromStorage(
        prefs.getString(_kThemeMode),
        legacyLight: prefs.getBool(_kLightTheme) ?? false,
      );
      _autoTakeover = prefs.getBool(_kAutoTakeover) ?? true;
      _mp4Conversion = prefs.getBool(_kMp4Conversion) ?? true;
      _searchEngine =
          SearchEngineX.fromStorage(prefs.getString(_kSearchEngine));
      _downloadDirUri = prefs.getString(kDownloadDirUri);
      _downloadDirName = prefs.getString(kDownloadDirName);
      _playerMediaControls = prefs.getBool(_kPlayerMediaControls) ?? false;
      _playerAutoResume = prefs.getBool(_kPlayerAutoResume) ?? true;
      _playerGestures = prefs.getBool(_kPlayerGestures) ?? true;
      _playerStreamingCache = prefs.getBool(_kPlayerStreamingCache) ?? false;
      final savedLimitMb = prefs.getInt(_kPlayerCacheLimitMb) ?? kDefaultCacheLimitMb;
      _playerCacheLimitMb = kCacheLimitOptionsMb.contains(savedLimitMb)
          ? savedLimitMb
          : kDefaultCacheLimitMb;
      _playerSpeed = prefs.getDouble(_kPlayerSpeed) ?? 1.0;
      _keepScreenOn = prefs.getBool(_kKeepScreenOn) ?? true;
      _downloadConcurrency =
          (prefs.getInt(_kDownloadConcurrency) ?? 2).clamp(1, 3);
      _wifiOnly = prefs.getBool(_kWifiOnly) ?? false;
      _downloadRetries = (prefs.getInt(_kDownloadRetries) ?? 1).clamp(0, 3);
      _gestureTipSeen = prefs.getBool(_kGestureTipSeen) ?? false;
    } catch (_) {
      // 读不到就用默认值，不影响启动
    }
    // 设置层把上限同步给代理，避免代理首次启动时仍用默认 256MB
    StreamingProxy.instance.maxCacheBytes = _playerCacheLimitMb * 1024 * 1024;
    _ready = true;
    notifyListeners();
  }

  Future<void> _save(String key, bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, value);
    } catch (_) {}
  }

  Future<void> _saveInt(String key, int value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(key, value);
    } catch (_) {}
  }

  /// 切换主题：深色 / 浅色 / 赛博朋克，选中即生效并持久化
  Future<void> setThemeMode(AppThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kThemeMode, mode.storageValue);
      // 同步旧键，避免降级安装后主题错乱
      await prefs.setBool(_kLightTheme, mode == AppThemeMode.light);
    } catch (_) {}
  }

  Future<void> setLightTheme(bool value) =>
      setThemeMode(value ? AppThemeMode.light : AppThemeMode.dark);

  Future<void> setAutoTakeover(bool value) async {
    if (_autoTakeover == value) return;
    _autoTakeover = value;
    notifyListeners();
    await _save(_kAutoTakeover, value);
  }

  /// 关闭时不显示转换按钮，也不执行任何转换
  Future<void> setMp4Conversion(bool value) async {
    if (_mp4Conversion == value) return;
    _mp4Conversion = value;
    notifyListeners();
    await _save(_kMp4Conversion, value);
  }

  /// 切换搜索引擎，仅影响之后在地址栏发起的搜索
  Future<void> setSearchEngine(SearchEngine value) async {
    if (_searchEngine == value) return;
    _searchEngine = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kSearchEngine, value.storageValue);
    } catch (_) {}
  }

  /// 选择 / 清除下载位置；传 null 恢复应用默认目录
  Future<void> setDownloadDir(String? uri, String? name) async {
    _downloadDirUri = (uri == null || uri.isEmpty) ? null : uri;
    _downloadDirName = _downloadDirUri == null ? null : name;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_downloadDirUri == null) {
        await prefs.remove(kDownloadDirUri);
        await prefs.remove(kDownloadDirName);
      } else {
        await prefs.setString(kDownloadDirUri, _downloadDirUri!);
        await prefs.setString(kDownloadDirName, _downloadDirName ?? '已选目录');
      }
    } catch (_) {}
  }

  Future<void> setPlayerMediaControls(bool value) async {
    if (_playerMediaControls == value) return;
    _playerMediaControls = value;
    notifyListeners();
    await _save(_kPlayerMediaControls, value);
  }

  Future<void> setPlayerAutoResume(bool value) async {
    if (_playerAutoResume == value) return;
    _playerAutoResume = value;
    notifyListeners();
    await _save(_kPlayerAutoResume, value);
  }

  Future<void> setPlayerGestures(bool value) async {
    if (_playerGestures == value) return;
    _playerGestures = value;
    notifyListeners();
    await _save(_kPlayerGestures, value);
  }

  Future<void> setPlayerStreamingCache(bool value) async {
    if (_playerStreamingCache == value) return;
    _playerStreamingCache = value;
    notifyListeners();
    await _save(_kPlayerStreamingCache, value);
  }

  /// 调整播放缓存上限；调小后立即按新上限裁剪，不必等下次播放。
  Future<void> setPlayerCacheLimitMb(int value) async {
    if (!kCacheLimitOptionsMb.contains(value)) return;
    if (_playerCacheLimitMb == value) return;
    _playerCacheLimitMb = value;
    StreamingProxy.instance.maxCacheBytes = value * 1024 * 1024;
    notifyListeners();
    await _saveInt(_kPlayerCacheLimitMb, value);
    await StreamingProxy.instance.trimCache();
  }

  Future<void> setKeepScreenOn(bool value) async {
    if (_keepScreenOn == value) return;
    _keepScreenOn = value;
    notifyListeners();
    await _save(_kKeepScreenOn, value);
  }

  Future<void> setDownloadConcurrency(int value) async {
    final v = value.clamp(1, 3);
    if (_downloadConcurrency == v) return;
    _downloadConcurrency = v;
    notifyListeners();
    await _saveInt(_kDownloadConcurrency, v);
  }

  Future<void> setWifiOnly(bool value) async {
    if (_wifiOnly == value) return;
    _wifiOnly = value;
    notifyListeners();
    await _save(_kWifiOnly, value);
  }

  Future<void> setDownloadRetries(int value) async {
    final v = value.clamp(0, 3);
    if (_downloadRetries == v) return;
    _downloadRetries = v;
    notifyListeners();
    await _saveInt(_kDownloadRetries, v);
  }

  /// 标记手势引导已展示：后续不再重复提示。
  Future<void> markGestureTipSeen() async {
    if (_gestureTipSeen) return;
    _gestureTipSeen = true;
    await _save(_kGestureTipSeen, true);
  }

  Future<void> setPlayerSpeed(double value) async {
    final v = value.clamp(0.5, 3.0);
    if (_playerSpeed == v) return;
    _playerSpeed = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kPlayerSpeed, v);
    } catch (_) {}
  }
}
