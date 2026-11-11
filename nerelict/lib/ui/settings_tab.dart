import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/theme_mode.dart';
import '../services/apk_installer.dart';
import '../services/app_log.dart';
import '../services/player_core.dart' show kPlaybackSpeeds;
import '../services/storage_service.dart';
import '../state/app_state.dart';
import '../state/settings_state.dart';
import 'app_theme.dart';
import 'widgets/app_menu.dart';

/// 设置主页：分类入口 + 搜索框，点进去是二级页面。
///
/// 设置项变多后单页太长，这里按「常规 / 播放 / 下载 / 其他」分组，
/// 每个入口右侧显示当前生效值；顶部搜索框按标题/关键词直达对应二级页并高亮。
class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key});

  static const String appVersion = '0.4.0';

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _open(
    BuildContext context,
    String title,
    List<Widget> Function(BuildContext, AppPalette, SettingsState) builder, {
    String? focus,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _SettingsPage(
          title: title,
          focusTitle: focus,
          builder: builder,
        ),
      ),
    );
  }

  /// 可搜索的设置项索引：标题、所属二级页、图标、关键词与当前值。
  ///
  /// 新增设置项时只要在这里补一条，搜索即可命中，不需要改搜索逻辑。
  static List<_SettingsEntry> _entries(SettingsState s) => <_SettingsEntry>[
        _SettingsEntry(
          title: '搜索引擎',
          category: '搜索',
          icon: Icons.manage_search,
          keywords: const <String>['搜索', 'google', 'bing', '地址栏'],
          value: s.searchEngine.label,
          page: _searchPage,
        ),
        _SettingsEntry(
          title: '外观主题',
          category: '外观主题',
          icon: Icons.palette_outlined,
          keywords: const <String>['主题', '深色', '浅色', '赛博', '暗色', '亮色'],
          value: s.themeMode.label,
          page: _themePage,
        ),
        _SettingsEntry(
          title: '屏幕常亮',
          category: '运行',
          icon: Icons.lightbulb_outline,
          keywords: const <String>['常亮', '息屏', '休眠', '亮屏', '保持'],
          value: s.keepScreenOn ? '已开启' : '已关闭',
          page: _runtimePage,
        ),
        _SettingsEntry(
          title: '自动接管网页视频',
          category: '视频播放',
          icon: Icons.smart_display_outlined,
          keywords: const <String>['接管', '自动播放', '网页视频', '浮层'],
          value: s.autoTakeover ? '已开启' : '已关闭',
          page: _playbackPage,
        ),
        _SettingsEntry(
          title: '通知栏 / 锁屏媒体控制',
          category: 'MA8N',
          icon: Icons.notifications_active_outlined,
          keywords: const <String>['媒体', '通知', '锁屏', '播放控制'],
          value: s.playerMediaControls ? '已开启' : '已关闭',
          page: _playerPage,
        ),
        _SettingsEntry(
          title: '自动续播',
          category: 'MA8N',
          icon: Icons.replay_circle_filled_outlined,
          keywords: const <String>['续播', '记忆', '进度', '继续'],
          value: s.playerAutoResume ? '已开启' : '已关闭',
          page: _playerPage,
        ),
        _SettingsEntry(
          title: '画面手势',
          category: 'MA8N',
          icon: Icons.touch_app_outlined,
          keywords: const <String>['手势', '双击', '快进', '音量', '亮度', '倍速'],
          value: s.playerGestures ? '已开启' : '已关闭',
          page: _playerPage,
        ),
        _SettingsEntry(
          title: '边下边播缓存',
          category: 'MA8N',
          icon: Icons.cached_outlined,
          keywords: const <String>['缓存', '边下边播', '代理'],
          value: s.playerStreamingCache ? '已开启' : '已关闭',
          page: _playerPage,
        ),
        _SettingsEntry(
          title: '默认倍速',
          category: 'MA8N',
          icon: Icons.speed,
          keywords: const <String>['倍速', '速度', '播放速度'],
          value: s.playerSpeedLabel,
          page: _playerPage,
        ),
        _SettingsEntry(
          title: '自动转 MP4',
          category: '下载与转换',
          icon: Icons.movie_creation_outlined,
          keywords: const <String>['mp4', '转换', '转封装', 'ts', 'm3u8'],
          value: s.mp4Conversion ? '已开启' : '已关闭',
          page: _downloadPage,
        ),
        _SettingsEntry(
          title: '同时下载任务数',
          category: '下载与转换',
          icon: Icons.hub_outlined,
          keywords: const <String>['并发', '任务数', '同时下载', '队列'],
          value: '${s.downloadConcurrency} 个',
          page: _downloadPage,
        ),
        _SettingsEntry(
          title: '仅 Wi-Fi 下载',
          category: '下载与转换',
          icon: Icons.wifi,
          keywords: const <String>['wifi', '无线', '流量', '移动网络'],
          value: s.wifiOnly ? '已开启' : '已关闭',
          page: _downloadPage,
        ),
        _SettingsEntry(
          title: '失败自动重试',
          category: '下载与转换',
          icon: Icons.replay,
          keywords: const <String>['重试', '失败', '重连'],
          value: s.downloadRetries == 0 ? '不重试' : '${s.downloadRetries} 次',
          page: _downloadPage,
        ),
        _SettingsEntry(
          title: '下载位置',
          category: '下载与转换',
          icon: Icons.folder_open_outlined,
          keywords: const <String>['目录', '路径', '存储', '文件夹'],
          value: s.downloadDirName ?? '应用默认目录',
          page: _downloadPage,
        ),
        _SettingsEntry(
          title: '安装应用更新',
          category: '关于',
          icon: Icons.system_update_outlined,
          keywords: const <String>['更新', '升级', '安装', 'apk'],
          value: 'v${SettingsTab.appVersion}',
          page: _aboutPage,
        ),
        _SettingsEntry(
          title: '诊断日志',
          category: '关于',
          icon: Icons.bug_report_outlined,
          keywords: const <String>['日志', '导出', '排错', 'bug'],
          value: '${AppLog.instance.count} 条',
          page: _aboutPage,
        ),
      ];

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final settings = context.watch<SettingsState>();
    final entries = _entries(settings);
    final query = _query.trim().toLowerCase();
    final results = query.isEmpty
        ? const <_SettingsEntry>[]
        : entries.where((e) => e.matches(query)).toList();

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('设置', style: TextStyle(fontSize: 17))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 32),
        children: <Widget>[
          _SearchField(
            controller: _searchCtrl,
            palette: p,
            onChanged: (v) => setState(() => _query = v),
            onClear: () {
              _searchCtrl.clear();
              setState(() => _query = '');
            },
          ),
          const SizedBox(height: 14),
          if (query.isNotEmpty)
            _SearchResults(
              results: results,
              query: _query.trim(),
              palette: p,
              onOpen: (entry) => _open(
                context,
                entry.category,
                entry.page,
                focus: entry.title,
              ),
            )
          else ...<Widget>[
            _SectionTitle('常规', color: p.textFaint),
            _SettingCard(
              titles: const <String>['搜索引擎', '外观主题', '屏幕常亮'],
              children: <Widget>[
                _CategoryTile(
                  icon: Icons.manage_search,
                  title: '搜索',
                  value: settings.searchEngine.label,
                  p: p,
                  onTap: () => _open(context, '搜索', _searchPage),
                ),
                Divider(height: 1, color: p.border),
                _CategoryTile(
                  icon: Icons.palette_outlined,
                  title: '外观主题',
                  value: settings.themeMode.label,
                  p: p,
                  onTap: () => _open(context, '外观主题', _themePage),
                ),
                Divider(height: 1, color: p.border),
                _CategoryTile(
                  icon: Icons.lightbulb_outline,
                  title: '运行',
                  value: settings.keepScreenOn ? '屏幕常亮 开' : '屏幕常亮 关',
                  p: p,
                  onTap: () => _open(context, '运行', _runtimePage),
                ),
              ],
            ),
            const SizedBox(height: 18),
            _SectionTitle('播放', color: p.textFaint),
            _SettingCard(
              titles: const <String>[
                '自动接管网页视频',
                '通知栏 / 锁屏媒体控制',
                '自动续播',
                '画面手势',
                '边下边播缓存',
                '默认倍速',
              ],
              children: <Widget>[
                _CategoryTile(
                  icon: Icons.smart_display_outlined,
                  title: '视频播放',
                  value: settings.autoTakeover ? '自动接管 开' : '自动接管 关',
                  p: p,
                  onTap: () => _open(context, '视频播放', _playbackPage),
                ),
                Divider(height: 1, color: p.border),
                _CategoryTile(
                  icon: Icons.play_circle_outline,
                  title: 'MA8N',
                  value: settings.playerMediaControls ? '媒体控制 开' : '媒体控制 关',
                  p: p,
                  onTap: () => _open(context, 'MA8N', _playerPage),
                ),
              ],
            ),
            const SizedBox(height: 18),
            _SectionTitle('下载与存储', color: p.textFaint),
            _SettingCard(
              titles: const <String>[
                '自动转 MP4',
                '同时下载任务数',
                '仅 Wi-Fi 下载',
                '失败自动重试',
                '下载位置',
              ],
              children: <Widget>[
                _CategoryTile(
                  icon: Icons.download_outlined,
                  title: '下载与转换',
                  value: settings.mp4Conversion ? '自动转 MP4 开' : '自动转 MP4 关',
                  p: p,
                  onTap: () => _open(context, '下载与转换', _downloadPage),
                ),
              ],
            ),
            const SizedBox(height: 18),
            _SectionTitle('其他', color: p.textFaint),
            _SettingCard(
              titles: const <String>['安装应用更新', '诊断日志'],
              children: <Widget>[
                _CategoryTile(
                  icon: Icons.info_outline,
                  title: '关于',
                  value: 'v${SettingsTab.appVersion}',
                  p: p,
                  onTap: () => _open(context, '关于', _aboutPage),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 可搜索的设置项。
class _SettingsEntry {
  const _SettingsEntry({
    required this.title,
    required this.category,
    required this.icon,
    required this.keywords,
    required this.value,
    required this.page,
  });

  final String title;
  final String category;
  final IconData icon;
  final List<String> keywords;
  final String value;
  final List<Widget> Function(BuildContext, AppPalette, SettingsState) page;

  bool matches(String query) {
    if (title.toLowerCase().contains(query)) return true;
    if (category.toLowerCase().contains(query)) return true;
    return keywords.any((k) => k.toLowerCase().contains(query));
  }
}

/// 设置页顶部搜索框：样式与地址栏一致（圆角胶囊 + 前置图标 + 清除按钮）。
class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.palette,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final AppPalette palette;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(p.isCyber ? 4 : 21),
        border: Border.all(color: p.border),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.search, size: 17, color: p.textFaint),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              textInputAction: TextInputAction.search,
              style: TextStyle(fontSize: 13, color: p.text),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: '搜索设置项（如 重试、主题、常亮）',
                hintStyle: TextStyle(fontSize: 12.5, color: p.textDisabled),
              ),
            ),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) {
              if (value.text.isEmpty) return const SizedBox.shrink();
              return InkWell(
                onTap: onClear,
                customBorder: const CircleBorder(),
                child: Padding(
                  padding: const EdgeInsets.all(5),
                  child: Icon(Icons.cancel, size: 15, color: p.textDisabled),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// 搜索结果：直接列出命中的设置项，点击进入对应二级页并高亮该卡片。
class _SearchResults extends StatelessWidget {
  const _SearchResults({
    required this.results,
    required this.query,
    required this.palette,
    required this.onOpen,
  });

  final List<_SettingsEntry> results;
  final String query;
  final AppPalette palette;
  final ValueChanged<_SettingsEntry> onOpen;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    if (results.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 48),
        child: Column(
          children: <Widget>[
            Icon(Icons.search_off, size: 38, color: p.textDisabled),
            const SizedBox(height: 10),
            Text(
              '没有找到「$query」相关的设置',
              style: TextStyle(fontSize: 12.5, color: p.textFaint),
            ),
            const SizedBox(height: 4),
            Text(
              '试试「下载」「主题」「手势」等关键词',
              style: TextStyle(fontSize: 11, color: p.textDisabled),
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _SectionTitle('搜索结果 · ${results.length}', color: p.textFaint),
        _SettingCard(
          children: <Widget>[
            for (var i = 0; i < results.length; i++) ...<Widget>[
              if (i > 0) Divider(height: 1, color: p.border),
              ListTile(
                dense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                leading: Icon(results[i].icon, size: 19, color: p.accent),
                title: Text(
                  results[i].title,
                  style: TextStyle(fontSize: 13, color: p.text),
                ),
                subtitle: Text(
                  '${results[i].category} · ${results[i].value}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10.8, color: p.textFaint),
                ),
                trailing:
                    Icon(Icons.chevron_right, size: 18, color: p.textDisabled),
                onTap: () => onOpen(results[i]),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

// ---- 二级页面内容 ----

List<Widget> _searchPage(
  BuildContext context,
  AppPalette p,
  SettingsState settings,
) {
  return <Widget>[
    _SettingCard(
      titles: ['搜索引擎'],
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
          child: Text(
            '地址栏搜索使用（默认 Google）',
            style: TextStyle(fontSize: 11.5, color: p.textFaint),
          ),
        ),
        ListTile(
          dense: true,
          leading: Icon(Icons.g_mobiledata, size: 21, color: p.accent),
          title: const Text('Google'),
          subtitle: const Text('默认选中'),
          trailing: settings.searchEngine == SearchEngine.google
              ? Icon(Icons.check_circle, size: 19, color: p.accent)
              : null,
          onTap: () => settings.setSearchEngine(SearchEngine.google),
        ),
        Divider(height: 1, color: p.border),
        ListTile(
          dense: true,
          leading:
              Icon(Icons.travel_explore_outlined, size: 19, color: p.accent),
          title: const Text('Bing'),
          trailing: settings.searchEngine == SearchEngine.bing
              ? Icon(Icons.check_circle, size: 19, color: p.accent)
              : null,
          onTap: () => settings.setSearchEngine(SearchEngine.bing),
        ),
      ],
    ),
  ];
}

List<Widget> _themePage(
  BuildContext context,
  AppPalette p,
  SettingsState settings,
) {
  return <Widget>[
    _SettingCard(
      titles: ['外观主题'],
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
          child: Text(
            '选中立即生效并记住；赛博朋克主题带霓虹描边、透视网格与扫描线',
            style: TextStyle(fontSize: 11.5, color: p.textFaint),
          ),
        ),
        for (var i = 0; i < AppThemeMode.values.length; i++) ...<Widget>[
          if (i > 0) Divider(height: 1, color: p.border),
          _ThemeOption(
            mode: AppThemeMode.values[i],
            selected: settings.themeMode == AppThemeMode.values[i],
            p: p,
            onTap: () => settings.setThemeMode(AppThemeMode.values[i]),
          ),
        ],
      ],
    ),
  ];
}

List<Widget> _runtimePage(
  BuildContext context,
  AppPalette p,
  SettingsState settings,
) {
  return <Widget>[
    _SettingCard(
      titles: ['屏幕常亮'],
      children: <Widget>[
        SwitchListTile(
          value: settings.keepScreenOn,
          onChanged: settings.setKeepScreenOn,
          title: const Text('屏幕常亮'),
          subtitle: Text(
            settings.keepScreenOn
                ? '已开启 · 应用在前台时保持亮屏，下载 / 转换 / 播放不会因自动息屏中断'
                : '已关闭 · 交给系统息屏策略，长时间任务可能被休眠打断',
          ),
          secondary: Icon(Icons.lightbulb_outline, color: p.accent),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
        ),
      ],
    ),
  ];
}

List<Widget> _playbackPage(
  BuildContext context,
  AppPalette p,
  SettingsState settings,
) {
  return <Widget>[
    _SettingCard(
      titles: ['自动接管网页视频'],
      children: <Widget>[
        SwitchListTile(
          value: settings.autoTakeover,
          onChanged: settings.setAutoTakeover,
          title: const Text('自动接管网页视频'),
          subtitle: Text(
            settings.autoTakeover
                ? '已启用 · 检测到视频时在当前页打开 MA8N'
                : '已关闭 · 视频继续在网页内播放，仅保留嗅探',
          ),
          secondary: Icon(Icons.smart_display_outlined, color: p.accent),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
        ),
      ],
    ),
  ];
}

List<Widget> _playerPage(
  BuildContext context,
  AppPalette p,
  SettingsState settings,
) {
  return <Widget>[
    _SettingCard(
      titles: ['通知栏 / 锁屏媒体控制', '自动续播', '画面手势', '边下边播缓存', '默认倍速'],
      children: <Widget>[
        SwitchListTile(
          value: settings.playerMediaControls,
          onChanged: settings.setPlayerMediaControls,
          title: const Text('通知栏 / 锁屏媒体控制'),
          subtitle: const Text('媒体按键、通知栏播放控制与音频焦点；关闭后完全沿用原有播放方式'),
          secondary: Icon(Icons.notifications_active_outlined, color: p.accent),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
        ),
        Divider(height: 1, color: p.border),
        SwitchListTile(
          value: settings.playerAutoResume,
          onChanged: settings.setPlayerAutoResume,
          title: const Text('自动续播'),
          subtitle: const Text('再次打开同一视频时从上次位置继续，看完自动清除进度'),
          secondary: Icon(Icons.replay_circle_filled_outlined, color: p.accent),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
        ),
        Divider(height: 1, color: p.border),
        SwitchListTile(
          value: settings.playerGestures,
          onChanged: settings.setPlayerGestures,
          title: const Text('画面手势'),
          subtitle: const Text('左右快进、左侧亮度、右侧音量、双击暂停、长按 2x、锁定控件'),
          secondary: Icon(Icons.touch_app_outlined, color: p.accent),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
        ),
        Divider(height: 1, color: p.border),
        SwitchListTile(
          value: settings.playerStreamingCache,
          onChanged: settings.setPlayerStreamingCache,
          title: const Text('边下边播缓存'),
          subtitle: const Text('HLS 分片经本地代理缓存复用，上限 256MB；关闭时直连播放'),
          secondary: Icon(Icons.cached_outlined, color: p.accent),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
        ),
        Divider(height: 1, color: p.border),
        _PickerRow<double>(
          icon: Icons.speed,
          title: '默认倍速',
          value: settings.playerSpeedLabel,
          menuTitle: '默认倍速',
          selected: settings.playerSpeed,
          items: <AppMenuItem<double>>[
            for (final s in kPlaybackSpeeds)
              AppMenuItem<double>(
                value: s,
                label: s == s.roundToDouble() ? '${s.toInt()}x' : '${s}x',
                icon: Icons.speed,
              ),
          ],
          onSelected: settings.setPlayerSpeed,
        ),
      ],
    ),
    const SizedBox(height: 12),
    _NoteCard(
      p: p,
      text: '播放器支持倍速、清晰度/音轨切换、外挂字幕、全屏与迷你小窗、系统画中画。'
          '投屏仅提供系统设置入口；DRM / blob: 地址、后台长时间播放与网络流截图不在支持范围。',
    ),
  ];
}

List<Widget> _downloadPage(
  BuildContext context,
  AppPalette p,
  SettingsState settings,
) {
  return <Widget>[
    _SettingCard(
      titles: ['自动转 MP4', '同时下载任务数', '仅 Wi-Fi 下载', '失败自动重试', '下载位置'],
      children: <Widget>[
        SwitchListTile(
          value: settings.mp4Conversion,
          onChanged: settings.setMp4Conversion,
          title: const Text('自动转 MP4'),
          subtitle: Text(
            settings.mp4Conversion
                ? '已启用 · 下载完成即转封装为 MP4，并删除原 TS（M3U8）文件'
                : '已关闭 · 保留 TS 文件，可在「下载」页的 MP4 转换入口手动处理',
          ),
          secondary: Icon(Icons.movie_creation_outlined, color: p.accent),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
        ),
        Divider(height: 1, color: p.border),
        _PickerRow<int>(
          icon: Icons.hub_outlined,
          title: '同时下载任务数',
          value: '${settings.downloadConcurrency} 个',
          menuTitle: '同时下载任务数',
          selected: settings.downloadConcurrency,
          items: <AppMenuItem<int>>[
            for (final n in <int>[1, 2, 3])
              AppMenuItem<int>(value: n, label: '$n 个并发'),
          ],
          onSelected: settings.setDownloadConcurrency,
        ),
        Divider(height: 1, color: p.border),
        SwitchListTile(
          value: settings.wifiOnly,
          onChanged: settings.setWifiOnly,
          title: const Text('仅 Wi-Fi 下载'),
          subtitle: Text(
            settings.wifiOnly
                ? '已开启 · 移动网络下任务保持排队，连上 Wi-Fi 自动继续'
                : '已关闭 · 移动网络也会继续下载',
          ),
          secondary: Icon(Icons.wifi, color: p.accent),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
        ),
        Divider(height: 1, color: p.border),
        _PickerRow<int>(
          icon: Icons.replay,
          title: '失败自动重试',
          value: settings.downloadRetries == 0
              ? '不重试'
              : '${settings.downloadRetries} 次',
          menuTitle: '失败自动重试',
          selected: settings.downloadRetries,
          items: <AppMenuItem<int>>[
            for (final n in <int>[0, 1, 2, 3])
              AppMenuItem<int>(value: n, label: n == 0 ? '不重试' : '重试 $n 次'),
          ],
          onSelected: settings.setDownloadRetries,
        ),
        Divider(height: 1, color: p.border),
        _DownloadLocationTile(p: p),
      ],
    ),
    const SizedBox(height: 12),
    _NoteCard(
      p: p,
      text: 'MP4 转换使用系统原生解码能力做无重编码转封装，'
          '仅支持 H.264 / HEVC + AAC 编码的 TS 流；'
          '开启自动转换后只保留 MP4，原 TS 会被清理。'
          '「下载」页另有独立的 MP4 转换入口，可多选批量处理。',
    ),
  ];
}

List<Widget> _aboutPage(
  BuildContext context,
  AppPalette p,
  SettingsState settings,
) {
  return <Widget>[
    _SettingCard(
      titles: ['安装应用更新', '诊断日志'],
      children: <Widget>[
        _InfoRow('应用名称', 'Nerelict', p),
        _InfoRow('版本', SettingsTab.appVersion, p),
        Divider(height: 1, color: p.border),
        ListTile(
          dense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          leading:
              Icon(Icons.system_update_outlined, size: 19, color: p.accent),
          title: Text(
            '安装应用更新',
            style: TextStyle(fontSize: 13, color: p.text),
          ),
          trailing: Icon(Icons.chevron_right, size: 18, color: p.textDisabled),
          onTap: () => _installUpdate(context),
        ),
        Divider(height: 1, color: p.border),
        ListTile(
          dense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          leading: Icon(Icons.bug_report_outlined, size: 19, color: p.accent),
          title: Text(
            '导出诊断日志',
            style: TextStyle(fontSize: 13, color: p.text),
          ),
          trailing: Text(
            '${AppLog.instance.count} 条',
            style: TextStyle(fontSize: 11, color: p.textFaint),
          ),
          onTap: () => _exportLog(context),
        ),
        Divider(height: 1, color: p.border),
        ListTile(
          dense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          leading: Icon(Icons.delete_outline, size: 19, color: p.textFaint),
          title: Text(
            '清空诊断日志',
            style: TextStyle(fontSize: 13, color: p.text),
          ),
          onTap: () {
            AppLog.instance.clear();
            context.read<AppState>().showToast('诊断日志已清空');
          },
        ),
      ],
    ),
  ];
}

Future<void> _exportLog(BuildContext context) async {
  final app = context.read<AppState>();
  app.showToast('正在导出诊断日志…', duration: const Duration(seconds: 1));
  final path = await AppLog.instance.export();
  if (path == null) {
    app.showToast('导出失败，请稍后重试');
    return;
  }
  app.showToast('已导出：${path.split('/').last}');
}

Future<void> _installUpdate(BuildContext context) async {
  final app = context.read<AppState>();
  final result = await ApkInstaller.pickAndInstall();
  app.showToast(
      result.ok ? '${result.modeLabel}：${result.message}' : result.message);
}

/// 二级设置页：标题 + 内容，内容随设置变化自动重建。
///
/// [focusTitle] 来自搜索：命中时顶部显示一条「已定位」提示，并让包含该设置的
/// 卡片短暂高亮，用户不用在长列表里自己找。
class _SettingsPage extends StatelessWidget {
  const _SettingsPage({
    required this.title,
    required this.builder,
    this.focusTitle,
  });

  final String title;
  final String? focusTitle;
  final List<Widget> Function(BuildContext, AppPalette, SettingsState) builder;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final settings = context.watch<SettingsState>();
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        title: Text(title, style: const TextStyle(fontSize: 17)),
      ),
      body: _SettingsFocus(
        title: focusTitle,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 32),
          children: <Widget>[
            if (focusTitle != null) ...<Widget>[
              _FocusBanner(title: focusTitle!, p: p),
              const SizedBox(height: 10),
            ],
            ...builder(context, p, settings),
          ],
        ),
      ),
    );
  }
}

/// 把搜索定位的标题传下去：卡片自行判断是否需要高亮。
class _SettingsFocus extends InheritedWidget {
  const _SettingsFocus({required this.title, required super.child});

  final String? title;

  static String? titleOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SettingsFocus>()?.title;

  @override
  bool updateShouldNotify(_SettingsFocus oldWidget) => oldWidget.title != title;
}

/// 顶部「已定位」提示条，告诉用户搜索跳到了哪一项。
class _FocusBanner extends StatelessWidget {
  const _FocusBanner({required this.title, required this.p});

  final String title;
  final AppPalette p;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: p.accent.withValues(alpha: p.isCyber ? 0.14 : 0.09),
        borderRadius: BorderRadius.circular(p.isCyber ? 3 : 9),
        border: Border.all(color: p.accent.withValues(alpha: 0.38)),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.my_location, size: 15, color: p.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '已定位 · $title',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: p.accent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 分类入口行：图标 + 名称 + 当前值
class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.p,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String value;
  final AppPalette p;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.fromLTRB(14, 2, 10, 2),
      leading: Icon(icon, size: 20, color: p.accent),
      title: Text(title, style: TextStyle(fontSize: 13.5, color: p.text)),
      subtitle: Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 10.8, color: p.textFaint),
      ),
      trailing: Icon(Icons.chevron_right, size: 18, color: p.textDisabled),
      onTap: onTap,
    );
  }
}

/// 下载位置：调用系统目录选择器，成品会自动同步一份到所选目录。
class _DownloadLocationTile extends StatelessWidget {
  const _DownloadLocationTile({required this.p});

  final AppPalette p;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsState>();
    final name = settings.downloadDirName;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.folder_open_outlined, size: 18, color: p.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '下载位置',
                  style: TextStyle(fontSize: 14, color: p.text),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 28),
            child: Text(
              name ?? '应用默认目录',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: p.textFaint),
            ),
          ),
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.only(left: 18),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: () async {
                    final picked = await StorageService.pickDirectory();
                    if (picked == null) return;
                    await settings.setDownloadDir(picked.uri, picked.name);
                  },
                  icon:
                      const Icon(Icons.drive_folder_upload_outlined, size: 16),
                  label: const Text('选择目录', style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact),
                ),
                if (settings.downloadDirUri != null)
                  TextButton(
                    onPressed: () => settings.setDownloadDir(null, null),
                    style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact),
                    child: Text('恢复默认',
                        style: TextStyle(fontSize: 12, color: p.textFaint)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text, {required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 0, 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _SettingCard extends StatelessWidget {
  const _SettingCard({required this.children, this.titles = const <String>[]});

  final List<Widget> children;

  /// 卡片包含的设置项标题：搜索结果定位到这里时用于高亮。
  final List<String> titles;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final focus = _SettingsFocus.titleOf(context);
    final hot = focus != null && titles.contains(focus);

    final card = Container(
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: hot ? p.accent.withValues(alpha: 0.55) : p.border,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );

    if (!hot) return card;
    // 2 秒的强调色呼吸，既不打断操作，也足够显眼
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.22, end: 0),
      duration: const Duration(seconds: 2),
      curve: Curves.easeOut,
      builder: (context, value, child) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: p.accent.withValues(alpha: value),
              blurRadius: 16,
              spreadRadius: 1,
            ),
          ],
        ),
        child: child,
      ),
      child: card,
    );
  }
}

/// 底部说明卡：统一的小字提示样式
class _NoteCard extends StatelessWidget {
  const _NoteCard({required this.p, required this.text});

  final AppPalette p;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 15, color: p.textFaint),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 11, color: p.textFaint, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// 主题选项：左侧色卡预览（底色 / 面板 / 强调色），右侧名称与勾选
class _ThemeOption extends StatelessWidget {
  const _ThemeOption({
    required this.mode,
    required this.selected,
    required this.p,
    required this.onTap,
  });

  final AppThemeMode mode;
  final bool selected;
  final AppPalette p;
  final VoidCallback onTap;

  String get _subtitle => switch (mode) {
        AppThemeMode.dark => '原有深色界面',
        AppThemeMode.light => '浅色界面 · 白天更清晰',
        AppThemeMode.cyber => '赛博朋克 2077 × 狂野美漫 · 霓虹描边 + 扫描线',
      };

  @override
  Widget build(BuildContext context) {
    final preview = AppPalette.of(mode);
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.fromLTRB(14, 2, 10, 2),
      leading: Container(
        width: 44,
        height: 30,
        decoration: BoxDecoration(
          color: preview.bg,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: preview.border),
        ),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Row(
            children: <Widget>[
              Expanded(
                flex: 3,
                child: Container(
                  decoration: BoxDecoration(
                    color: preview.surface,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
              const SizedBox(width: 3),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[preview.accent, preview.accentAlt],
                    ),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      title: Text(
        mode.label,
        style: TextStyle(
          fontSize: 13,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          color: selected ? p.accent : p.text,
        ),
      ),
      subtitle: Text(
        _subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 10.5, color: p.textFaint),
      ),
      trailing: selected
          ? Icon(Icons.check_circle, size: 19, color: p.accent)
          : Icon(Icons.circle_outlined, size: 18, color: p.textDisabled),
      onTap: onTap,
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value, this.p);

  final String label;
  final String value;
  final AppPalette p;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Text(label, style: TextStyle(fontSize: 13, color: p.textSub)),
          const Spacer(),
          Text(value, style: TextStyle(fontSize: 12, color: p.textFaint)),
        ],
      ),
    );
  }
}

/// 「标题 + 当前值 + 点击选择」的一行，下拉菜单统一走 [showAppMenu]。
///
/// 菜单锚定在右侧取值处、右对齐展开；值较长时按可用宽度截断，
/// 避免菜单跑到屏幕边缘外或盖住整行。
class _PickerRow<T> extends StatefulWidget {
  const _PickerRow({
    required this.icon,
    required this.title,
    required this.value,
    required this.items,
    required this.selected,
    required this.onSelected,
    this.menuTitle,
  });

  final IconData icon;
  final String title;
  final String value;
  final List<AppMenuItem<T>> items;
  final T selected;
  final ValueChanged<T> onSelected;
  final String? menuTitle;

  @override
  State<_PickerRow<T>> createState() => _PickerRowState<T>();
}

class _PickerRowState<T> extends State<_PickerRow<T>> {
  final GlobalKey _anchorKey = GlobalKey();

  Future<void> _open() async {
    final value = await showAppMenu<T>(
      context: context,
      anchorKey: _anchorKey,
      items: widget.items,
      selected: widget.selected,
      title: widget.menuTitle ?? widget.title,
    );
    if (value != null && value != widget.selected) widget.onSelected(value);
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14),
      leading: Icon(widget.icon, size: 19, color: p.accent),
      title:
          Text(widget.title, style: TextStyle(fontSize: 13.5, color: p.text)),
      trailing: Row(
        key: _anchorKey,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 150),
            child: Text(
              widget.value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 11.5, color: p.textFaint),
            ),
          ),
          Icon(Icons.arrow_drop_down, size: 18, color: p.textFaint),
        ],
      ),
      onTap: _open,
    );
  }
}
