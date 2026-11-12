import 'dart:io';

import 'package:nerelict/models/installer_status.dart';
import 'package:nerelict/services/app_paths.dart';

int passed = 0;
final List<String> failures = <String>[];

void check(bool ok, String label) {
  if (ok) {
    passed++;
    stdout.writeln('  ✓ $label');
  } else {
    failures.add(label);
    stdout.writeln('  ✗ $label');
  }
}

/// 项目根以脚本自身位置为准，不依赖运行时的工作目录。
/// 从任意目录执行 `dart /path/to/nerelict/tool/verify_v35.dart` 都能定位源码；
/// 特殊部署形态可显式设置 NERELICT_PROJECT_ROOT 覆盖。
final String projectRoot = () {
  final configured = readEnvPath(kProjectRootEnv);
  if (configured != null) return configured;
  final script = Platform.script;
  if (script.scheme == 'file' || script.scheme.isEmpty) {
    return File.fromUri(script).parent.parent.path;
  }
  throw StateError('无法定位项目根，请设置 $kProjectRootEnv');
}();

File projectFile(String relative) => File(joinPath(projectRoot, relative));

String read(String path) {
  try {
    final f = projectFile(path);
    return f.existsSync() ? f.readAsStringSync() : '';
  } catch (_) {
    return '';
  }
}

String settingsTabText() => read('lib/ui/settings_tab.dart');

void main() {
  stdout.writeln('=== 1. 安装能力解析 ===');
  final privileged = InstallerCapability.fromMap(<dynamic, dynamic>{
    'privileged': true,
    'root': false,
    'canSilent': true,
    'detail': '已获得系统安装权限，可静默安装',
  });
  check(privileged.canSilent, '系统权限 -> 可静默');
  check(privileged.modeLabel.contains('系统权限'), '能力文案区分系统权限');
  check(privileged.detail.contains('静默'), '说明文字透传');

  final rooted = InstallerCapability.fromMap(<dynamic, dynamic>{
    'privileged': false,
    'root': true,
    'canSilent': true,
    'detail': '检测到 root',
  });
  check(rooted.canSilent && rooted.modeLabel.contains('root'), 'root -> 可静默');

  final plain = InstallerCapability.fromMap(<dynamic, dynamic>{
    'privileged': false,
    'root': false,
    'canSilent': false,
    'detail': '普通应用无法静默安装',
  });
  check(!plain.canSilent, '普通应用 -> 不可静默');
  check(plain.modeLabel.contains('需确认'), '普通应用提示需要确认');

  check(InstallerCapability.unknown.detail.isNotEmpty, '未探测时有兜底文案');

  stdout.writeln('=== 2. 安装结果解析 ===');
  final silent = InstallResult.fromMap(<dynamic, dynamic>{
    'ok': true,
    'mode': 'root',
    'message': '已通过 root 静默安装',
  });
  check(silent.ok && silent.silent, 'root 安装被识别为静默成功');
  check(silent.modeLabel.contains('root'), '结果文案带安装方式');

  final fallback = InstallResult.fromMap(<dynamic, dynamic>{
    'ok': true,
    'mode': 'system',
    'message': '已打开系统安装器',
  });
  check(fallback.ok && !fallback.silent, '系统安装器不算静默');
  check(fallback.modeLabel.contains('系统安装器'), '回退路径可识别');

  final failed = InstallResult.fromMap(<dynamic, dynamic>{
    'ok': false,
    'mode': 'none',
    'message': '安装包不存在或为空',
  });
  check(!failed.ok && failed.message.isNotEmpty, '失败结果带原因');
  check(InstallResult.canceled.message == '已取消', '取消结果有固定文案');

  stdout.writeln('=== 3. 原生配置完整性 ===');
  final manifest = read('android/app/src/main/AndroidManifest.xml');
  check(manifest.contains('android.permission.REQUEST_INSTALL_PACKAGES'),
      'Manifest 声明 REQUEST_INSTALL_PACKAGES');
  check(manifest.contains('android.permission.INSTALL_PACKAGES'),
      'Manifest 声明 INSTALL_PACKAGES（系统权限）');
  check(manifest.contains('androidx.core.content.FileProvider'),
      'Manifest 注册 FileProvider');
  check(manifest.contains('@xml/file_paths'), 'FileProvider 指向 file_paths');

  final filePaths = read('android/app/src/main/res/xml/file_paths.xml');
  check(filePaths.contains('cache-path') && filePaths.contains('shared/'),
      'file_paths 只暴露 cache/shared 目录');

  final activity =
      read('android/app/src/main/kotlin/com/nerelict/nerelict/MainActivity.kt');
  check(activity.contains('com.nerelict/screen'), '常亮通道已注册');
  check(activity.contains('com.nerelict/install'), '安装通道已注册');
  check(activity.contains('setKeepAwake'), '常亮方法名一致');
  check(activity.contains('REQ_PICK_APK'), '有 APK 选择请求码');
  check(activity.contains('FLAG_KEEP_SCREEN_ON'), '使用窗口常亮 flag');

  final installer =
      read('android/app/src/main/kotlin/com/nerelict/nerelict/ApkInstaller.kt');
  check(installer.contains('INSTALL_PACKAGES'), '原生侧校验系统安装权限');
  check(installer.contains('su') && installer.contains('pm install'),
      '原生侧实现 root 静默安装');
  check(installer.contains('PackageInstaller'), '原生侧实现系统权限静默安装');
  check(installer.contains('canRequestPackageInstalls'), '回退前检查未知来源授权');

  stdout.writeln('=== 4. 安装能力留在应用内、点击确认交给 Skill ===');
  check(!manifest.contains('BIND_ACCESSIBILITY_SERVICE'), '应用不再声明无障碍服务');
  check(!manifest.contains('InstallConfirmService'), '已移除安装确认服务');
  check(
      !projectFile('android/app/src/main/res/xml/accessibility_service_config.xml')
          .existsSync(),
      '已移除无障碍配置文件');
  check(!activity.contains('accessibilityEnabled'), '安装通道不再暴露无障碍开关');
  check(!settingsTabText().contains('installAutoConfirm'), '设置不再保存自动确认偏好');
  check(activity.contains('getPackageArchiveInfo'), '安装前校验更新包包名');

  stdout.writeln('=== 5. 安装确认脚本（可选，独立于应用） ===');
  final skillDir = resolveConfiguredPath(readEnvPath(kInstallSkillDirEnv),
      relativeBase: projectRoot);
  if (skillDir == null) {
    stdout.writeln('  - 跳过：未设置 $kInstallSkillDirEnv，脚本不在本仓库内');
  } else {
    final skillMd = File(joinPath(skillDir, 'SKILL.md'));
    final skillScript = File(
        joinPath(skillDir, joinPath('scripts', 'adb_install_autoconfirm.py')));
    check(skillMd.existsSync(), 'Skill 文档存在');
    check(skillScript.existsSync(), 'Skill 脚本存在');
    final skillText = skillMd.existsSync() ? skillMd.readAsStringSync() : '';
    check(skillText.contains('触发方式'), 'Skill 声明触发方式');
    check(skillText.contains('输入'), 'Skill 声明输入');
    check(skillText.contains('输出'), 'Skill 声明输出');
    check(skillText.contains('执行步骤'), 'Skill 声明执行步骤');
    check(skillText.contains('可复用边界'), 'Skill 声明可复用边界');
    final scriptText =
        skillScript.existsSync() ? skillScript.readAsStringSync() : '';
    check(scriptText.contains('uiautomator'), '脚本用 uiautomator 读取界面');
    check(scriptText.contains('input') && scriptText.contains('tap'),
        '脚本通过 adb input tap 点击');
    check(scriptText.contains('is_installer_window'), '脚本只在安装器窗口操作');
    check(!scriptText.contains('accessibility'), '脚本不依赖无障碍服务');
  }

  stdout.writeln('=== 6. MP4 音频修复（ADTS -> 裸 AAC 帧） ===');
  final converter =
      read('android/app/src/main/kotlin/com/nerelict/nerelict/Mp4Converter.kt');
  check(converter.contains('adtsFrames'), '解析 ADTS 帧边界');
  check(converter.contains('headerLen'), '按保护位决定 7/9 字节头');
  check(converter.contains('isSupportedAudio'), '音频编码选择独立判断');
  check(converter.contains('framePts += frameDurUs'), '逐帧累加音频时间戳');
  check(converter.contains('hasAudio') == false, '音轨信息由 MainActivity 输出');

  stdout.writeln('=== 7. 安装入口归位（仅自我更新） ===');
  final settingsTab = read('lib/ui/settings_tab.dart');
  check(!settingsTab.contains("_SectionTitle('应用安装'"), '设置页不再有安装开关区块');
  check(settingsTab.contains('安装应用更新'), '关于区提供更新入口');
  check(!projectFile('lib/ui/app_update_sheet.dart').existsSync(), '已移除中间的更新面板');
  check(settingsTab.contains('ApkInstaller.pickAndInstall'), '关于页直接调起安装，无中间内容');

  stdout.writeln('=== 8. 迷你小窗与提示框 ===');
  final appState = read('lib/state/app_state.dart');
  check(appState.contains('keepPlayer'), '页面重置支持保留播放会话');
  check(appState.contains('_playerMode == PlayerMode.mini'), '迷你小窗在切页时不被关闭');
  check(appState.contains('resetPageResources(keepPlayer: true)'),
      '底部切页保留全部播放形态（不仅小窗）');
  final browser = read('lib/ui/browser_tab.dart');
  check(browser.contains('context.read<AppState>().showToast'), '收藏等反馈统一走轻提示');
  check(browser.contains('actionLabel:'), '收藏提示带快捷动作');
  check(!browser.contains('SnackBar'), '浏览器页不再散落 SnackBar');

  stdout.writeln('=== 9. 版本号与二级设置 ===');
  final pubspec = read('pubspec.yaml');
  check(pubspec.contains('version: 0.4.1+21'), 'pubspec 基础版本为 0.4.1 / code 21');
  final gradle = read('android/app/build.gradle.kts');
  check(gradle.contains('versionName = flutter.versionName'),
      '展示版本统一取 pubspec 三段版本');
  check(!gradle.contains('versionName = "0.3.9.0"'), '不再覆盖第四段展示版本');
  final settingsFile = read('lib/ui/settings_tab.dart');
  check(settingsFile.contains("appVersion = '0.4.1'"), '设置页版本为 0.4.1');
  check(read('README.md').contains('v0.4.1'), 'README 版本号已同步');
  check(settingsFile.contains('_CategoryTile'), '设置改为分类入口');
  check(settingsFile.contains('_SettingsPage'), '存在二级设置页');
  check(settingsFile.contains("'常规'") && settingsFile.contains("'播放'"),
      '设置按类别分组');
  check(!settingsFile.contains("_InfoRow('包名'"), '关于页不再显示包名');
  check(settingsFile.contains("'安装应用更新'"), '保留安装应用更新选项');

  stdout.writeln('=== 10. 更名 nerelict ===');
  check(pubspec.contains('name: nerelict'), 'pubspec 包名已改为 nerelict');
  check(gradle.contains('namespace = "com.nerelict.nerelict"'),
      'namespace 已改为 nerelict');
  check(gradle.contains('applicationId = "com.nerelict.nerelict"'),
      'applicationId 与项目标识一致（独立安装，旧包数据不复用）');
  check(read('tool/verify_download.dart').contains('package:nerelict/'),
      '主机端验证脚本使用当前包名');
  check(
      projectFile('android/app/src/main/kotlin/com/nerelict/nerelict/MainActivity.kt')
          .existsSync(),
      'Kotlin 包目录已迁移');
  check(manifest.contains('com.nerelict.nerelict.MainActivity'),
      'Manifest 使用新的全限定类名');

  stdout.writeln('=== 11. 迷你窗进度与贴边 ===');
  final player = read('lib/ui/player_page.dart');
  check(player.contains('_MiniProgress'), '小窗新增进度条组件');
  check(player.contains('onTapDown'), '进度条支持点击定位');
  final mainFile = read('lib/main.dart');
  check(mainFile.contains('snapRight') || mainFile.contains('_miniWidth / 2'),
      '松手按左右侧吸附');
  check(mainFile.contains('AnimatedPositioned'), '吸附带过渡动画');
  check(mainFile.contains('_dragDelta += details.delta'), '拖动位移逐帧累加');
  check(mainFile.contains('_dragStart'), '拖动以起始位置为基准');
  check(player.contains('playerMode == PlayerMode.mini'), '系统 stop 不销毁小窗');

  stdout.writeln('=== 12. 下载调度（并发/Wi-Fi/重试） ===');
  check(appState.contains('_pump()'), '存在下载调度泵');
  check(appState.contains('_concurrency'), '按并发上限调度');
  check(appState.contains('_armWifiTimer'), '仅 Wi-Fi 时会等待并自动恢复');
  check(appState.contains('_scheduleRetryIfNeeded'), '失败按次数自动重试');
  check(
      read('lib/services/network_status.dart').contains('isWifi'), '提供网络类型探测');
  check(activity.contains('com.nerelict/network'), '原生侧提供网络通道');
  final settingsState = read('lib/state/settings_state.dart');
  check(settingsState.contains("_kDownloadConcurrency"), '并发数持久化');
  check(settingsState.contains("_kWifiOnly"), '仅 Wi-Fi 持久化');
  check(settingsState.contains("_kDownloadRetries"), '重试次数持久化');

  stdout.writeln('=== 13. 统一提示与诊断日志 ===');
  check(appState.contains('void showToast('), '统一轻提示入口');
  check(appState.contains('hintAction'), '提示支持动作按钮');
  check(mainFile.contains('_dismiss'), '提示可主动关闭');
  check(projectFile('lib/services/app_log.dart').existsSync(), '新增诊断日志模块');
  final logFile = read('lib/services/app_log.dart');
  check(logFile.contains('maxLines'), '日志有容量上限');
  check(logFile.contains('Future<String?> export'), '日志可导出');
  check(mainFile.contains('installGlobalErrorLogging'), '全局异常接入日志');
  check(settingsFile.contains('导出诊断日志'), '关于页提供导出入口');
  check(settingsFile.contains('清空诊断日志'), '关于页提供清空入口');

  stdout.writeln('=== 14. 主题化下拉菜单 ===');
  final menuFile = projectFile('lib/ui/widgets/app_menu.dart');
  check(menuFile.existsSync(), '新增统一的菜单组件');
  final menuText = menuFile.readAsStringSync();
  check(menuText.contains('Future<T?> showAppMenu'), '提供 showAppMenu 入口');
  check(menuText.contains('AppMenuItem'), '菜单条目数据化');
  check(menuText.contains('p.isCyber'), '菜单样式跟随主题（含赛博）');
  check(menuText.contains('safe.top') && menuText.contains('maxBottom'),
      '菜单自动避让安全区并向上翻转');
  check(menuText.contains('selected == item.value'), '选中项有统一标记');
  final allUi = Directory(joinPath(projectRoot, 'lib'))
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .map((f) => f.readAsStringSync())
      .join('\n');
  check(!allUi.contains('PopupMenuButton('), '不再使用系统 PopupMenuButton');
  check(!allUi.contains('showMenu<'), '不再使用无主题的 showMenu');
  check(
      settingsFile.contains('_PickerRow<int>') &&
          settingsFile.contains('_PickerRow<double>'),
      '设置页下拉统一走 AppMenu');

  stdout.writeln('=== 15. 播放器置顶与拖动 ===');
  check(mainFile.contains('final minTop = media.padding.top + _topInset'),
      '播放面板默认贴住页面顶部');
  check(mainFile.contains('top: top'), '面板按纵向位置定位');
  check(mainFile.contains('_clampPanel'), '面板拖动有安全区约束');
  check(mainFile.contains('_panelOffset'), '面板位置按播放会话管理');
  check(mainFile.contains('onPanStart'), '拖动入口已接通');
  check(mainFile.contains('_dragDelta += details.delta'), '拖动位移逐帧累加');
  check(player.contains('onPanStart: widget.onDragStart'), '标题栏可拖动');
  check(player.contains('Icons.drag_indicator'), '标题栏有拖动把手');
  check(mainFile.contains('left: 0,') && mainFile.contains('right: 0,'),
      '播放面板铺满两侧');
  check(!mainFile.contains('_sideMargin * 2'), '面板不保留左右浮动边距');
  check(mainFile.contains('_clampMini'), '小窗拖动避让安全区');
  check(player.contains('panelRadius'), '面板使用上方圆角');

  stdout.writeln('=== 16. 交互细节 ===');
  check(player.contains('_handleDoubleTap'), '双击按区域处理');
  check(player.contains('_seekBy'), '双击左右快退/快进 10 秒');
  check(player.contains('gestureTipSeen'), '首次使用提示手势');
  check(player.contains('_MiniBuffering'), '小窗显示缓冲状态');
  check(player.contains('setPlayerMode(PlayerMode.panel)'), '小窗双击还原浮层');
  final filesTab = read('lib/ui/files_tab.dart');
  final downloadPage = read('lib/ui/download_tasks_page.dart');
  check(downloadPage.contains('Dismissible'), '下载卡片支持滑动操作');
  check(downloadPage.contains('_SwipeHint'), '滑动有方向提示');
  check(filesTab.contains('去浏览器嗅探'), '文件空状态有引导按钮');
  check(filesTab.contains('_handleSystemBack'), '文件页返回先收筛选');
  check(browser.contains('_SniffGroup'), '嗅探面板按类型分组');
  check(browser.contains('全部下载'), '嗅探面板支持批量下载');
  check(browser.contains('搜索资源名或地址'), '嗅探面板支持搜索');
  check(appState.contains('addBackInterceptor'), '返回键由状态层分发');
  check(mainFile.contains('再按一次退出'), '首页双击返回退出');
  check(
      read('lib/ui/web_favorites_page.dart').contains('粘贴网址收藏'), '收藏空状态支持粘贴网址');
  check(appState.contains('void showError(') && appState.contains('Clipboard'),
      '错误提示可复制详情');
  check(settingsFile.contains('_SearchField'), '设置页支持搜索');
  check(settingsFile.contains('_SettingsEntry'), '设置项有可搜索索引');
  check(settingsFile.contains('_FocusBanner'), '搜索命中会定位提示');
  check(settingsFile.contains('focusTitle'), '二级页支持高亮定位');

  stdout.writeln('=== 17. 文件页与下载分支 ===');
  check(
      projectFile('lib/ui/files_tab.dart').existsSync() &&
          !projectFile('lib/ui/downloads_tab.dart').existsSync(),
      '下载页拆分为文件页 + 下载分支');
  check(filesTab.contains('final files = state.localFiles'), '文件页直接使用扫描到的文件');
  check(!filesTab.contains('knownPaths'), '不再排除已完成任务引用的文件（修复文件不显示）');
  check(filesTab.contains('DownloadTasksPage'), '顶部菜单可进入下载分支');
  check(!filesTab.contains('cleaning_services_outlined'), '文件页顶部不再放清理扫把');
  check(downloadPage.contains('cleaning_services_outlined'), '扫把移入下载页并保留');
  check(downloadPage.contains('清除已完成'), '下载页保留清理功能');
  check(downloadPage.contains('进行中') && downloadPage.contains('已结束'),
      '下载页区分进行中/已结束');
  check(filesTab.contains('_ActiveDownloadsBanner'), '文件页提示进行中的下载');
  check(mainFile.contains("label: '文件'"), '底部入口改名为文件');
  check(mainFile.contains('Icons.folder_outlined'), '文件入口使用文件夹图标');
  check(!mainFile.contains("label: '下载'"), '底部不再保留“下载”入口');
  check(appState.contains('unawaited(refreshLocalFiles())'), '清除任务后重扫文件列表');

  stdout.writeln('=== 18. 设置项默认值 ===');
  final settings = read('lib/state/settings_state.dart');
  check(settings.contains("_kKeepScreenOn = 'keep_screen_on'"), '常亮设置键已持久化');
  check(settings.contains('_keepScreenOn = true'), '常亮默认开启');
  check(settings.contains('bool get keepScreenOn'), '暴露常亮 getter');

  stdout.writeln('=== 19. 稳定性修复 ===');
  final store = read('lib/services/download_store.dart');
  final downloaderDart = read('lib/services/hls_downloader.dart');
  final converterKt = read(
      'android/app/src/main/kotlin/com/nerelict/nerelict/Mp4Converter.kt');
  check(store.contains('_lastSave'), '任务持久化写入串行化');
  check(store.contains('List<DownloadTask>.of(tasks)'), '持久化取任务快照');
  check(store.contains('_tmpSeq'), '临时文件不共用固定名');
  check(appState.contains('_scanSeq'), '文件列表只接受最新一次扫描结果');
  check(appState.contains('_disposed = true'), '销毁后不再刷新列表');
  check(downloaderDart.contains('!key.isAes128') &&
      downloaderDart.contains('暂不支持') &&
      downloaderDart.contains('加密的视频'), '未知加密方式显式报错');
  check(converterKt.contains('length > scratch.capacity()'),
      '大样本按需扩容，避免静默丢帧');
  check(downloaderDart.contains('下载不完整（已收'),
      '直链下载校验实际字节数');

  stdout.writeln('=== 20. P0 下载正确性 ===');
  final taskModel = read('lib/models/download_task.dart');
  final tasksPage = read('lib/ui/download_tasks_page.dart');
  check(downloaderDart.contains('Uri.parse(url).resolveUri(res.realUri)'),
      '重定向后的相对 Location 解析为绝对 URI');
  check(downloaderDart.contains('var base = first.uri'),
      '播放列表基于重定向后地址解析');
  check(downloaderDart.contains('String _partName(HlsSegment seg)'),
      '分片按 URL 身份命名');
  check(downloaderDart.contains('SHA256Digest()'), '分片身份使用稳定摘要');
  check(downloaderDart.contains('_writeAtomic(part, data)'),
      '分片原子落盘');
  check(downloaderDart.contains("'If-Range': validator"),
      '直链续传校验源文件版本');
  check(downloaderDart.contains('task.isLive = media.isLive'),
      '直播流标记到任务');
  check(taskModel.contains("'isLive': isLive") &&
      taskModel.contains("task.isLive = raw['isLive'] == true"),
      '直播标记可持久化');
  check(taskModel.contains('bool resumeRequested'), '续传防重入标志');
  check(appState.contains('task.status = TaskStatus.paused;') &&
      appState.contains('立刻收敛状态'), '暂停即时反馈状态');
  check(appState.contains('if (task.resumeRequested) return;'),
      '继续操作防重入');
  check(appState.contains('直播流只保存了当前片段'), '直播完成给出明确提示');
  check(tasksPage.contains('直播片段 · 可能不完整'), '任务卡标注直播片段');
  check(tasksPage.contains('if (task.pauseRequested ||') &&
      tasksPage.contains('state.resumeTask(task)'), '右滑方向感知暂停请求');
  check(projectFile('tool/verify_p0.dart').existsSync(),
      '提供可运行的 P0 行为测试');

  stdout.writeln('=== 21. 播放代理与切页播放 ===');
  final proxy = read('lib/services/streaming_proxy.dart');
  final rewriter = read('lib/services/playlist_rewriter.dart');
  check(proxy.contains('finalUriAfterRedirects(requested, response.redirects)'),
      '播放列表按重定向后的最终 URI 解析');
  check(proxy.contains('rewritePlaylistUris('), '代理复用统一的改写逻辑');
  check(proxy.contains('req.followRedirects = true'), '代理显式跟随重定向');
  check(proxy.contains('range == null'), 'Range 请求不命中整文件缓存');
  check(proxy.contains('cachedContentType(target)'), '缓存命中按扩展名给 MIME');
  check(proxy.contains('stableCacheKey(target)'), '缓存键使用稳定摘要');
  check(proxy.contains("scheme != 'http'"), '代理拒绝非 http(s) 回源');
  check(proxy.contains('proxyPathSuffix(path, target)'),
      '代理地址带可推断扩展名，HLS 不被误判为渐进式流');
  check(proxy.contains("route.startsWith('/hls')"),
      '代理路由兼容带文件名的路径');
  check(rewriter.contains('Utf8Decoder(allowMalformed: true)'),
      '容忍 BOM 与非 UTF-8 playlist');
  check(rewriter.contains('#EXT-X-MEDIA:'), '独立音轨标签被改写');
  check(rewriter.contains('SHA256Digest()'), '缓存摘要与下载分片同源');
  check(appState.contains('resetPageResources(keepPlayer: true)'),
      '切 tab 保留播放会话');
  check(projectFile('tool/verify_playback.dart').existsSync(),
      '提供可运行的播放链路行为测试');

  stdout.writeln('=== 22. P1 稳定性与 0.4.0 版本规则 ===');
  final scanner = read('lib/services/local_media_scanner.dart');
  check(appState.contains('scanLocalFilesDetailed()'),
      '目录扫描改用带完整性标记的结果');
  check(scanner.contains('class LocalFileScanResult') &&
      scanner.contains('final bool complete'), '扫描结果区分完整与部分');
  check(scanner.contains('errors++'), '单个条目读取失败会被记录');
  check(appState.contains('if (!scan.complete)'),
      '扫描不完整时不覆盖已有列表');
  check(appState.contains('bool get lastScanIncomplete'),
      '扫描状态可被界面读取');
  check(filesTab.contains('state.lastScanIncomplete'), '文件页提示扫描不完整');
  check(downloaderDart.contains('await sink.addStream('),
      '直链写入带背压');
  check(!downloaderDart.contains('sink.add(chunk)'), '不再无背压堆积分片');
  check(downloaderDart.contains('.takeWhile((_) => !canceled())'),
      '流式写入保留取消语义');
  check(downloaderDart.contains('cleanupStaleParts(') &&
      downloaderDart.contains("name.startsWith('ss_')"),
      '下载器提供孤儿分片目录清理');
  check(downloaderDart.contains('activeTaskIds.contains(name.substring(3))'),
      '清理时保留活跃任务分片');
  check(appState.contains('Future<({int dirs, int bytes})> cleanupStaleParts()'),
      '状态层暴露清理入口');
  check(appState.contains('unawaited(cleanupStaleParts());') &&
      tasksPage.contains("'清理残留临时分片'"),
      '启动自动清理 + 下载页手动清理入口');
  check(tasksPage.contains('Icons.cleaning_services_outlined'),
      '清除已完成的扫把图标保留');
  check(appState.contains(
          'for (final task in _tasks.where((t) => t.status.isFinished))'),
      '清除已完成任务时逐个标记为脱离');
  check(appState.contains('if (task.detached || !canStartConversion'),
      '转换入口拒绝已脱离任务');
  check('if (task.detached) return;'.allMatches(appState).length >= 8,
      '转换 / 导出 / 完成链路各 await 点都有脱离守卫');
  check(projectFile('tool/verify_p1.dart').existsSync(),
      '提供可运行的 P1 行为测试');

  stdout.writeln('=== 23. 发版护栏、品牌命名与 0.4.1 资源 ===');
  // 已正式发布的最高 versionCode；每次 Release 后上调，防止忘记 +1 或复用旧码
  const int publishedVersionCode = 20;
  final pubspecText = read('pubspec.yaml');
  final settingsText = read('lib/ui/settings_tab.dart');
  final gradleText = read('android/app/build.gradle.kts');
  final readmeText = read('README.md');
  final versionLine = RegExp(
          r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*$',
          multiLine: true)
      .firstMatch(pubspecText);
  final semver = versionLine?.group(1) ?? '';
  final currentCode = int.tryParse(versionLine?.group(2) ?? '') ?? 0;
  check(semver == '0.4.1', '当前展示版本为 0.4.1');
  check(currentCode > publishedVersionCode,
      'versionCode $currentCode 严格大于已发布最高值 $publishedVersionCode');
  check(settingsText.contains("appVersion = '$semver'"),
      '设置页版本与 pubspec 三段版本一致');
  check(readmeText.contains('v$semver'), 'README 版本历史含 v$semver');
  check(gradleText.contains('versionCode = flutter.versionCode') &&
          gradleText.contains('versionName = flutter.versionName'),
      'Gradle 版本号统一由 pubspec 派生');
  check(!RegExp(r'versionName\s*=\s*"').hasMatch(gradleText),
      'Gradle 未硬编码展示版本');

  // MA8N 代号只允许以「迁移旧键」的形式残留，其余一律视为回归
  const legacyBrandKeys = <String>{
    'ma8_player_favorites',
    'ma8_playback_memory',
    'ma8_play_cache',
    'ma8_player_media',
  };
  final brandSources = <File>[
    ...Directory(joinPath(projectRoot, 'lib')).listSync(recursive: true).whereType<File>(),
    ...Directory(joinPath(projectRoot, 'tool')).listSync(recursive: true).whereType<File>(),
    ...Directory(joinPath(projectRoot, 'android/app/src/main'))
        .listSync(recursive: true)
        .whereType<File>(),
    projectFile('README.md'),
    projectFile('../README.md'),
    projectFile('../AGENTS.md'),
  ];
  final brandResidue = <String>[];
  for (final f in brandSources) {
    if (!f.existsSync()) continue;
    // 检查器自身持有旧代号字面量，跳过以免自我命中
    if (f.path.endsWith('verify_v35.dart')) continue;
    if (!RegExp(r'\.(dart|kt|md|xml)$').hasMatch(f.path)) continue;
    final text = f.readAsStringSync();
    // 只查大写代号，避免把小写迁移键（`ma8_...`）误判成回归
    if (RegExp(r'MA8N|MA8播放器|MA8Player|"MA8"|MA8_').hasMatch(text) ||
        text.toLowerCase().contains('ma8n')) {
      brandResidue.add(f.path);
    }
    for (final m
        in RegExp(r'ma8_[a-z_]+', caseSensitive: false).allMatches(text)) {
      final key = m.group(0)!.toLowerCase();
      if (!legacyBrandKeys.contains(key)) brandResidue.add('${f.path}: $key');
    }
  }
  check(brandResidue.isEmpty,
      '源码与文档已统一为 Nerelict（残留 ${brandResidue.take(3).join(' / ')}）');
  final favoritesText = read('lib/services/favorites.dart');
  final memoryText = read('lib/services/playback_memory.dart');
  check(favoritesText.contains('kLegacyStorageKey') &&
          favoritesText.contains('_migrate(prefs)'),
      '收藏键换名带一次性迁移，不丢历史收藏');
  check(memoryText.contains('kLegacyStorageKey') &&
          memoryText.contains('_migrate(prefs)'),
      '续播记忆键换名带一次性迁移');
  check(read('android/app/src/main/kotlin/com/nerelict/nerelict/PlayerPlatform.kt')
          .contains('deleteNotificationChannel(LEGACY_CHANNEL_ID)'),
      '旧通知渠道会被主动删除，不残留孤儿渠道');

  const res = 'android/app/src/main/res/';
  check(projectFile('${res}mipmap-anydpi-v26/ic_launcher.xml').existsSync() &&
          projectFile('${res}mipmap-anydpi-v26/ic_launcher_round.xml').existsSync(),
      '提供 Android 12+ 自适应图标');
  check(projectFile('${res}drawable/ic_launcher_foreground.xml').existsSync(),
      '自适应图标前景为矢量资源');
  check(read('android/app/src/main/AndroidManifest.xml')
      .contains('android:roundIcon'), '清单声明圆形图标');
  var iconsOk = true;
  for (final dpi in const <String>[
    'mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi'
  ]) {
    final f = projectFile('${res}mipmap-$dpi/ic_launcher.png');
    if (!f.existsSync() || f.lengthSync() < 1500) iconsOk = false;
  }
  check(iconsOk, '五档密度图标均已替换默认 Flutter 图标');

  final proxyText = read('lib/services/streaming_proxy.dart');
  check(proxyText.contains('Future<int> cacheSizeBytes()') &&
          proxyText.contains('Future<int> clearCache()'),
      '播放代理提供占用统计与清理');
  check(proxyText.contains('set maxCacheBytes') &&
          proxyText.contains('total > _maxCacheBytes'),
      '缓存上限可配置且裁剪按生效值执行');
  check(proxyText.contains("kLegacyCacheDirName = 'ma8_play_cache'"),
      '旧缓存目录换名后有清理入口');
  final settingsStateText = read('lib/state/settings_state.dart');
  check(settingsStateText.contains('kCacheLimitOptionsMb') &&
          settingsStateText.contains('setPlayerCacheLimitMb'),
      '设置层持久化缓存上限档位');
  check(settingsText.contains('_PlaybackCacheTile'), '设置页展示缓存占用与清理');
  check(projectFile('tool/smoke_device.dart').existsSync(),
      '提供可独立运行的真机冒烟脚本');

  stdout.writeln();
  if (failures.isEmpty) {
    stdout.writeln('全部通过：$passed 项断言');
  } else {
    stdout.writeln('失败 ${failures.length} 项：');
    for (final f in failures) {
      stdout.writeln(' - $f');
    }
    exitCode = 1;
  }
}
