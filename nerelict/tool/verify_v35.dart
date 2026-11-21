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
  check(converter.contains('framePts += audioFrameDurUs'), '逐帧累加音频时间戳');
  check(converter.contains('hasAudio') == false, '音轨信息由 MainActivity 输出');

  stdout.writeln('=== 6b. MP4 时间轴（带 B 帧不再被压平） ===');
  check(converter.contains('analyzeTrack'), '转换前试读样本判断时间戳特征');
  check(converter.contains('reordered'), '识别解码顺序里的 PTS 回退（B 帧）');
  check(converter.contains('Mode.GRID'), '带 B 帧的视频按解码序号重建等间隔网格');
  check(!converter.contains('PASSTHROUGH'),
      '不再直通原始 PTS（MediaMuxer 实测会把回退压平）');
  check(converter.contains('class TrackClock'), '每条轨道独立的时间轴钟');
  check(converter.contains('count * frameDurUs'), '兜底时按解码序号乘帧间隔重建网格');
  check(converter.contains('deltas[deltas.size / 2]'), '帧间隔取排序后间隔的中位数');
  check(converter.contains('probeTimeline'), '产物抽查时间轴单调性与帧间隔');
  check(converter.contains('gap += jump - frameDurUs'), '缺段缺口计入网格，避免音画错位');
  check(converter.contains('droppedVideo > writtenVideo / 10'),
      '直通失败（丢帧过多）时自动改走网格');

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
  check(pubspec.contains('version: 0.4.12+32'), 'pubspec 基础版本为 0.4.12 / code 32');
  final gradle = read('android/app/build.gradle.kts');
  check(gradle.contains('versionName = flutter.versionName'),
      '展示版本统一取 pubspec 三段版本');
  check(!gradle.contains('versionName = "0.3.9.0"'), '不再覆盖第四段展示版本');
  final settingsFile = read('lib/ui/settings_tab.dart');
  check(settingsFile.contains("appVersion = '0.4.12'"), '设置页版本为 0.4.12');
  check(read('README.md').contains('v0.4.4'), 'README 版本号已同步');
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
  check(filesTab.contains('_dir == null ? state.localFiles : _entries'),
      '文件页按当前目录取数据源（下载目录 / 外部目录）');
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
  check(downloaderDart.contains("directHeaders['If-Range'] = validator"),
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
  const int publishedVersionCode = 25;
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
  check(semver == '0.4.12', '当前展示版本为 0.4.12');
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

  stdout.writeln('=== 24. 0.4.2 选流、Cookie 鉴权与分片时序 ===');
  final parserText = read('lib/services/hls_parser.dart');
  check(parserText.contains('#EXT-X-MEDIA:'), '解析 #EXT-X-MEDIA 音轨 / 字幕组');
  check(parserText.contains('#EXT-X-BYTERANGE:'), '解析 #EXT-X-BYTERANGE 字节区间');
  check(parserText.contains("line == '#EXT-X-DISCONTINUITY'"),
      'DISCONTINUITY 精确匹配，不误算 DISCONTINUITY-SEQUENCE');
  check(parserText.contains('class HlsMasterPlaylist'),
      '主播放列表给出「码率 + 音轨 + 字幕」的完整结果');
  check(parserText.contains('separateAudioFor'), '能识别音轨被拆成独立流的档位');
  check(parserText.contains('discontinuities'), '断点数进入播放列表结果');

  final downloaderText = read('lib/services/hls_downloader.dart');
  check(downloaderText.contains('var chosen = master.pick(task.variantKey)'),
      '下载按用户选择的档位执行，不再硬取最高码率');
  check(downloaderText.contains('task.variantNote = note'),
      '档位被自动调整时留下可见说明');
  check(downloaderText.contains('range: seg.hasRange'),
      '字节区间分片按 Range 请求');
  check(downloaderText.contains('字节区间不符'),
      '服务端忽略 Range 时报错，而不是把全量写进分片');
  check(downloaderText.contains('task.discontinuities = media.discontinuities'),
      '断点数记录到任务上');
  check(downloaderText.contains('resolveCookie'), '下载器支持注入 Cookie 解析');
  check(downloaderText.contains("headers['Cookie']"), '出站请求注入 Cookie 头');

  final cookieStoreText = read('lib/services/cookie_store.dart');
  check(cookieStoreText.contains("MethodChannel('com.nerelict/cookie')"),
      'Cookie 走独立平台通道');
  check(cookieStoreText.contains('Duration(seconds: 90)'),
      'Cookie 缓存有短有效期，跟得上签名刷新');
  check(!cookieStoreText.contains('logD') &&
          !cookieStoreText.contains('print('),
      'Cookie 不写入日志');

  final activityText = read(
      'android/app/src/main/kotlin/com/nerelict/nerelict/MainActivity.kt');
  check(activityText.contains('COOKIE_CHANNEL') &&
          activityText.contains('CookieManager.getInstance()'),
      '原生侧从 WebView 的 CookieManager 读取登录态');

  final taskModelText = read('lib/models/download_task.dart');
  check(taskModelText.contains("'variantKey': variantKey") &&
          taskModelText.contains("'variantNote': variantNote") &&
          taskModelText.contains("'discontinuities': discontinuities"),
      '选流结果与断点信息随任务持久化');
  // 0.4.4 起任务模型会持久化 Authorization / X-*；Cookie 仍由 CookieStore
  // 按站点实时取，磁盘上不留副本，这里断言的是「没有 Cookie 字段」而不是
  // 「源码里不能出现 cookie 这个词」（注释里需要解释为什么排除它）。
  check(!taskModelText.contains("'Cookie'") &&
          !taskModelText.contains("'cookie'"),
      'Cookie 不作为字段写入任务模型（不落盘）');

  check(projectFile('lib/ui/variant_picker.dart').existsSync(),
      '提供下载前选流面板');
  check(read('lib/ui/variant_picker.dart').contains('音轨独立'),
      '选流面板把音轨独立的档位标注为不可选');
  check(projectFile('tool/verify_v042.dart').existsSync(),
      '提供 0.4.2 行为测试');

  stdout.writeln('=== 25. 点击捕获（浮层播放）===');
  final clickJsText = read('lib/services/click_sniff_js.dart');
  final clickModelText = read('lib/models/sniffed_media.dart');
  final aggregatorText = read('lib/services/resource_aggregator.dart');
  final browserText = read('lib/ui/browser_tab.dart');
  check(clickJsText.contains("addEventListener('pointerdown'") &&
          clickJsText.contains('capture: true, passive: true'),
      '点击在捕获阶段被动记录，不干扰页面交互');
  // 全脚本只允许两处阻止默认行为，且都属于「必须由我们接管」的场景：
  // 1. 刚识别出广告遮挡层的那一次点击（否则仍会触发广告层自己的跳转，
  //    click 目标在 pointerdown 时已锁定）；
  // 2. `target="_blank"` 的链接：WebView 侧没有 onCreateWindow，新窗口开不出来，
  //    只能改成同页跳转，否则点了完全没反应（登录入口最常见的形态）。
  // 除这两处之外，任何新增的 preventDefault 都视为回归。
  check(clickJsText.split('preventDefault(').length - 1 == 2 &&
          clickJsText.contains('blockClickUntil') &&
          clickJsText.contains("closest('a[target]')"),
      '只有遮挡层当次点击与 target=_blank 接管会阻止默认行为');
  check(clickJsText.contains('MutationObserver') &&
          clickJsText.contains('ATTR_MS = 8000'),
      '点击后新插入的播放器在 8 秒归因窗口内被抓到');
  check(clickJsText.contains('OVERLAY_MIN = 50') &&
          clickModelText.contains('kOverlayThreshold = 50'),
      '浮层阈值在脚本与模型两侧一致');
  check(clickModelText.contains('class ClickAttribution') &&
          clickModelText.contains('bool get overlayPlay'),
      '资源项带上点击归因与浮层判定');
  check(aggregatorText.contains('ClickAttribution? attribution') &&
          aggregatorText.contains('noteAttribution'),
      '聚合层支持把点击归因并到已有资源项');
  check(browserText.contains("'ClickChannel'") &&
          browserText.contains('kClickSniffJs'),
      '点击捕获通道与脚本已接入浏览器页');
  check(browserText.contains('浮层捕获') && browserText.contains('点击捕获说明'),
      '资源面板可按浮层筛选，菜单里有说明入口');
  check(read('lib/state/settings_state.dart')
          .contains("_kClickCapture = 'click_capture'"),
      '点击捕获开关可持久化');
  check(projectFile('tool/verify_click_sniff.dart').existsSync(),
      '提供点击捕获行为测试');

  stdout.writeln('=== 26. 广告识别、跳转兜底与播放器健壮性 ===');
  final adFilterText = read('lib/services/ad_filter.dart');
  check(adFilterText.contains("'doubleclick.net'") &&
          adFilterText.contains('highConfidence'),
      '已知广告网络给出高置信判定');
  check(adFilterText.contains("'preroll'") && adFilterText.contains('_adSegments'),
      '广告路径按整段匹配，而不是子串');
  check(!adFilterText.contains('contains(segment)'),
      '没有退化成子串包含判断（会误伤 download / shadow）');

  final aggregatorAd = read('lib/services/resource_aggregator.dart');
  check(aggregatorAd.contains('AdFilter.inspect(url)') &&
          aggregatorAd.contains('markSuspectAd'),
      '聚合时给广告项打标记');
  check(aggregatorAd.contains('orderForDisplay'), '提供真实项在前、广告沉底的展示排序');
  check(read('lib/state/app_state.dart').contains('orderForDisplay('),
      '嗅探列表使用统一排序');

  check(browserText.contains('AdFilter.inspect(url)') &&
          browserText.contains('已跳过疑似广告'),
      '自动接管跳过广告媒体并提示一次');
  check(browserText.contains('_handleAdNavigation') &&
          browserText.contains('goBack()'),
      '点击后跳到高置信广告页会自动回退');
  check(browserText.contains('_autoSkippedAd'),
      '同一次广告跳转只回退一次，避免死循环');
  check(browserText.contains("'疑似广告'") &&
          browserText.contains('_showAds'),
      '面板提供疑似广告筛选，默认折叠');
  check(browserText.contains('isHighConfidenceAd'),
      '只有高置信广告页才自动回退');

  final playerText = read('lib/ui/player_page.dart');
  check(playerText.contains('播放中断') && playerText.contains('core.error'),
      '运行期播放错误可见，不再是黑屏');
  check(playerText.contains('Future<void> _retry()') &&
          playerText.contains("'重试'"),
      '播放错误提供重试入口');
  check(playerText.contains('_tick?.cancel()'),
      '重试前收掉旧定时器，避免重复计费');
  check(projectFile('tool/verify_ad_filter.dart').existsSync(),
      '提供广告识别行为测试');
  check(projectFile('docs/ad-playback-adaptation.md').existsSync(),
      '提供广告适配的判断规则与边界说明');

  stdout.writeln('=== 27. 播放器触控与播放期弹窗守卫 ===');
  final playerTouchText = read('lib/ui/player_page.dart');
  check(playerTouchText.contains('const double kPlayerMinTap = 44'),
      '播放器控件热区下限 44dp');
  check(!playerTouchText.contains('visualDensity: VisualDensity.compact'),
      '不再使用 compact 密度（旧热区仅 28~34dp）');
  check(!playerTouchText.contains('scrollDirection: Axis.horizontal'),
      '控制条不再用横向滚动容器抢手势');
  check(playerTouchText.contains('bool get _inputShielded'),
      '播放器打开后 350ms 内屏蔽手势');

  final guardText = read('lib/services/playback_guard_js.dart');
  for (final fn in <String>['open', 'alert', 'confirm', 'prompt']) {
    check(guardText.contains('w.$fn = function'), '播放期接管 window.$fn');
    check(guardText.contains('w.$fn = o.$fn'), '关闭播放器还原 window.$fn');
  }
  check(browserText.contains('_syncPopupGuard') &&
          browserText.contains('kPlaybackGuardRestoreJs'),
      '播放结束立即还原网页弹窗出口');
  check(read('lib/state/settings_state.dart')
          .contains("'player_block_page_popups'"),
      '弹窗拦截有独立开关');
  check(projectFile('tool/verify_player_touch.dart').existsSync(),
      '提供播放器触控行为测试');

  stdout.writeln('=== 28. 遮挡层防护、错误文案与胶囊尺寸 ===');
  check(clickJsText.contains('looksLikeAdLayer') &&
          clickJsText.contains("alphaOf(st.backgroundColor) > 0.35"),
      '遮挡层判定保守：不透明遮罩不处理');
  check(clickJsText.contains("setProperty('pointer-events', 'none', 'important')"),
      '只关指针事件，不删节点');
  check(clickJsText.contains("Date.now() - shell.tapAt < 1500"),
      '点击后 1.5 秒内拒绝 window.open');
  check(clickJsText.contains('window.__ssClearLayers'),
      '提供手动清理遮挡层入口');
  check(read('lib/services/click_sniff.dart').contains('shield'),
      'shield 事件可解析');
  check(browserText.contains('清理页面遮挡层') &&
          browserText.contains('_clearAdLayers'),
      '菜单里能手动清理遮挡层');
  check(read('lib/services/playback_error.dart').contains('视频源打不开'),
      '原始播放错误翻译成人话');
  check(playerTouchText.contains('const double kChipWidth = 50') &&
          playerTouchText.contains('FontFeature.tabularFigures()'),
      '倍速等四个胶囊等宽、数字不跳动');
  check(projectFile('tool/verify_ad_shield.dart').existsSync(),
      '提供遮挡层 / 错误文案 / 胶囊尺寸测试');

  stdout.writeln('=== 29. 多段 init / 分片组播放 / 响应体抓地址 / DASH 边界 ===');
  final dl29 = read('lib/services/hls_downloader.dart');
  check(dl29.contains('final initPaths = <String, String>{}'),
      '按分片切换 init，支持多段 #EXT-X-MAP');
  check(dl29.contains('if (key.isNotEmpty && key != writtenInit)'),
      '合并时 init 变化就重写');
  check(dl29.contains('暂不支持下载 DASH'), '.mpd 下载被明确拒绝');
  final sp29 = read('lib/services/streaming_proxy.dart');
  check(sp29.contains('playbackUrlForSegments') &&
          sp29.contains("route.startsWith('/local')"),
      '分片组可合成播放列表边下边播');
  final sn29 = read('lib/services/sniffer_js.dart');
  check(sn29.contains('scanBody') && sn29.contains('res.clone()'),
      '从响应体里抓媒体地址（POST/JSON 站点）');
  check(projectFile('tool/verify_v043.dart').existsSync(),
      '提供 0.4.3 行为测试');
  check(projectFile('docs/unsniffable-and-fixes.md').existsSync(),
      '提供无法嗅探场景与适配方案文档');

  stdout.writeln('=== 30. 0.4.4 请求头透传 ===');
  final hp30 = read('lib/services/header_policy.dart');
  check(hp30.contains('class HeaderPolicy'), '存在请求头策略模块');
  check(hp30.contains('authorization|x-') && hp30.contains('cookie|set-cookie|host'),
      '放行鉴权头、排除链路自管头');
  check(hp30.contains('kMaxValueLength') && hp30.contains(r"contains('\n')"),
      '超长与换行头值被拒绝（防头注入）');
  check(hp30.contains('tokenFor'), '代理令牌由地址派生');
  final sp30 = read('lib/services/streaming_proxy.dart');
  check(sp30.contains('_registerHeaders') && sp30.contains('_headersByToken'),
      '代理用内存表登记鉴权头，URL 不带头值');
  check(sp30.contains(r"'&h=$h'"), '代理地址只携带令牌');
  check(sp30.contains('Headers: headerToken') ||
          sp30.contains('h: headerToken'),
      '分片沿用同一令牌');
  final sn30 = read('lib/services/sniffer_js.dart');
  check(sn30.contains('setRequestHeader') &&
          sn30.contains('XMLHttpRequest.prototype.send'),
      '嗅探脚本采集 XHR 请求头');
  check(sn30.contains('headersToList(init && init.headers'),
      'fetch 读取 init.headers');
  check(sn30.contains('seenHdr'), 'perf 先发现、网络后命中时可补报头');
  final dt30 = read('lib/models/download_task.dart');
  check(dt30.contains('requestHeaders') && dt30.contains("'headers'"),
      '下载任务可持久化鉴权头并随磁盘恢复');
  final pr30 = read('lib/models/player_request.dart');
  check(pr30.contains('Map<String, String> headers'),
      '播放请求携带鉴权头');
  check(projectFile('tool/verify_v044.dart').existsSync(),
      '提供 0.4.4 行为测试');

  stdout.writeln('=== 31. 嗅探提示不刷屏 ===');
  final browser31 = read('lib/ui/browser_tab.dart');
  check(!browser31.contains('播放器在跨域页面内'),
      '跨域播放器不再每点一次就弹提示');
  check(browser31.contains('case ClickEventType.iframe:') &&
          browser31.contains('widget.state.clickHints'),
      '跨域播放器仍记进候选，⚡ 面板仍可打开');
  check(browser31.contains('_mseNotified'), 'MSE 回扫提示每页只弹一次');
  check(browser31.contains('_shieldNotified'), '遮挡层提示仍然每页只弹一次');

  // 真机验证必须装正式签名包：一旦又回到「临时移走 key.properties 回退 debug 签名」，
  // 装机的包和对外发布的包就不是同一份产物，还会因为签名冲突被逼着卸载清数据。
  stdout.writeln('=== 32. 真机验证只装正式签名包 ===');
  final agents32 = read('../AGENTS.md');
  check(readmeText.contains('adb install -r') &&
          readmeText.contains('不要') &&
          readmeText.contains('debug 签名'),
      'README 说明真机装正式签名包、不再回退 debug 签名');
  check(agents32.contains('真机验证一律安装正式签名包'),
      'AGENTS.md 固化「真机验证装正式签名包」');
  check(agents32.contains('INSTALL_FAILED_UPDATE_INCOMPATIBLE') ||
          agents32.contains('不能互相覆盖'),
      'AGENTS.md 记录两套签名不能互相覆盖');

  // 登录入口的四个出口：遮挡层误判、window.open、target=_blank、自定义深链。
  // 这四条任何一条回退，都会表现成「点了登录没反应」，所以逐条锁住。
  stdout.writeln('=== 33. 登录按钮不被自己的防护弄死 ===');
  final click33 = read('lib/services/click_sniff_js.dart');
  check(click33.contains("querySelector('form,input,select,textarea,dialog,'"),
      '含表单控件的层不判广告遮挡层');
  check(click33.contains('[aria-modal="true"]'),
      '对话框语义（aria-modal）同样豁免');
  check(click33.contains('wasKilled') && click33.contains('killedLayers'),
      '命中的层记入列表，不再向父层扩散');
  check(click33.contains('anyPlaying') && click33.contains('tapInPlayer'),
      'window.open 只在播放中或点在视频容器时拦');
  check(!click33.contains('if (Date.now() - shell.tapAt < 1500) {\n          shell.popups++;'),
      '不再「点击后 1.5 秒内一律拒绝 window.open」');
  check(click33.contains('location.href = target'),
      'window.open 降级成同页跳转（WebView 开不出新窗口）');
  check(click33.contains("closest('a[target]')"),
      'target=_blank 的链接改成同页跳转');
  final browser33 = read('lib/ui/browser_tab.dart');
  check(browser33.contains('_openDeepLink') && browser33.contains('_loginSchemes'),
      '自定义 scheme 深链交给系统处理');
  check(browser33.contains('unawaited(_openDeepLink'), '导航拦截里异步转交深链');
  check(read('lib/services/open_external.dart').contains('com.nerelict/external'),
      '深链通道名与原生一致');
  final activity33 = read('android/app/src/main/kotlin/com/nerelict/nerelict/MainActivity.kt');
  check(activity33.contains('EXTERNAL_CHANNEL = "com.nerelict/external"') &&
          activity33.contains('Intent.ACTION_VIEW'),
      '原生侧用 ACTION_VIEW 打开深链');
  check(projectFile('tool/click_js_test.js').existsSync(),
      '提供点击脚本的 Node 行为验证');

  // 文件页：分类宫格 + 最近播放 + 单列行，视频不做独立页面。
  // 数据层的规则单独由 verify_media_meta.dart 跑，这里锁「结构没被改回去」。
  stdout.writeln('=== 35. 文件页与媒体元数据 ===');
  final kinds35 = read('lib/services/file_kinds.dart');
  check(kinds35.contains('ebook') && kinds35.contains('apk'),
      '类型细分出电子书与安装包');
  check(kinds35.contains("'.m3u8': LocalFileKind.video"),
      '.m3u8 归入视频（可播放）');
  check(kinds35.contains('kPlaylistExts') && kinds35.contains('isPlaylistName'),
      '清单文件单独识别');
  final meta35 = read('lib/services/media_meta.dart');
  check(meta35.contains('parsePlaylistText') && meta35.contains('formatDuration'),
      '清单解析与时长格式化在纯 Dart 层');
  check(meta35.contains("startsWith('#EXTM3U')"),
      '首个非空行必须是 #EXTM3U（防盗链的 HTML 不会被当成清单）');
  check(meta35.contains('resolutionLabel'), '分辨率档位化');
  final probe35 = read('lib/services/media_probe.dart');
  check(probe35.contains("'com.nerelict/media'"), '元数据走独立原生通道');
  check(probe35.contains('modifiedMs') && probe35.contains('_inflight'),
      '按 size+mtime 缓存并合并并发探测');
  check(probe35.contains('_maxSegmentChecks'), '清单分片核对有上限，不阻塞 UI');
  final activity35 =
      read('android/app/src/main/kotlin/com/nerelict/nerelict/MainActivity.kt');
  check(activity35.contains('MEDIA_CHANNEL = "com.nerelict/media"') &&
          activity35.contains('MediaMetadataRetriever'),
      '原生用 MediaMetadataRetriever 读时长与分辨率');
  final files35 = read('lib/ui/files_tab.dart');
  check(files35.contains('_KindGrid') && files35.contains('kGridKinds'),
      '分类宫格取代原来的类型 chips');
  check(!files35.contains('_FilterBar('), '旧的横向筛选条已移除');
  check(files35.contains('_SearchField') && files35.contains('_showSortSheet'),
      '搜索与排序入口在页内');
  check(files35.contains('_enterSelection') && files35.contains('_BatchBar'),
      '长按进多选、底部批量操作条');
  check(files35.contains('_showRowMenu') && files35.contains('_FileRow'),
      '行尾 ⋮ 菜单承载重命名/删除/信息');
  check(files35.contains('MediaProbe.instance.probe('),
      '行内元数据懒加载');
  check(!files35.contains('PlayerPage'), '视频不另开页面，直接走 Nerelict 播放器');
  check(projectFile('tool/verify_media_meta.dart').existsSync(),
      '提供文件页数据层的纯 Dart 断言');

  // 删除先落回收站：起因是一次真实的误删，成品视频直接被删掉、无法挽回。
  stdout.writeln('=== 36. 删除可撤销 ===');
  final trash36 = read('lib/services/file_trash.dart');
  check(trash36.contains("dirName = '.trash'"), '回收站目录是 .trash（扫描会跳过）');
  check(trash36.contains('keepFor') && trash36.contains('days: 7'),
      '回收站保留 7 天');
  check(trash36.contains('moveToTrash') && trash36.contains('restore('),
      '支持移入与还原');
  check(trash36.contains('_恢复_'), '同名文件还原时不覆盖，改名留痕');
  final state36 = read('lib/state/app_state.dart');
  check(state36.contains('FileTrash.moveToTrash('), '删除走回收站');
  check(state36.contains('return trashed'), '删除返回回收站路径供撤销');
  check(state36.contains('restoreFromTrash'), '提供撤销还原入口');
  check(state36.contains('FileManager.delete(path)'),
      '回收站搬不动时退回硬删，不让「删除」点了没反应');
  check(state36.contains('purgeExpired'), '过期回收站会被清理');
  final files36 = read('lib/ui/files_tab.dart');
  check(files36.contains("label: '撤销'"), '删除后给一次撤销机会');
  check(files36.contains('restoreFromTrash'), '撤销接到状态层');

  // 浏览整个内部存储：Android 11+ 只能靠「所有文件访问权限」，且必须用户手动开。
  stdout.writeln('=== 37. 全盘浏览（所有文件访问权限） ===');
  final manifest37 = read('android/app/src/main/AndroidManifest.xml');
  check(manifest37.contains('MANAGE_EXTERNAL_STORAGE'),
      '声明所有文件访问权限');
  final activity37 =
      read('android/app/src/main/kotlin/com/nerelict/nerelict/MainActivity.kt');
  check(activity37.contains('isExternalStorageManager'),
      '原生按 isExternalStorageManager 判断授权');
  check(activity37.contains('ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION') &&
          activity37.contains('ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION'),
      '跳转到授权页，并对缺失该页的 ROM 兜底');
  check(activity37.contains('getExternalStorageDirectory'),
      '能给出内部存储根路径');
  final access37 = read('lib/services/storage_access.dart');
  check(access37.contains('hasAllFilesAccess') && access37.contains('openSettings'),
      'Dart 侧封装检查与跳转');
  final scanner37 = read('lib/services/local_media_scanner.dart');
  check(scanner37.contains('scanDirectory(') && scanner37.contains('includeDirs'),
      '扫描支持任意目录与目录条目');
  check(scanner37.contains('isDir'), '目录是单独的条目类型');
  final files37 = read('lib/ui/files_tab.dart');
  check(files37.contains('_enterDir') && files37.contains('_leaveDir'),
      '能进子目录并能退回上级');
  check(files37.contains('_Breadcrumb'), '面包屑说明当前位置');
  check(files37.contains('_AccessCard') && files37.contains('_requestAccess'),
      '未授权时给出引导卡');
  check(files37.contains('didChangeAppLifecycleState'),
      '回到前台重新检查授权（系统设置里开完即生效）');
  check(files37.contains('bool get _canManage => _dir == null'),
      '下载目录之外只读：别处不开放删除与重命名');
  check(files37.contains('此目录只读'), '只读目录在菜单里说明原因');
  // 返回键必须先把「页面自己的子状态」问一遍，再切标签：
  // 以前 main.dart 先无条件 setTab(0)，文件页的退多选/退目录永远轮不到。
  final main37 = read('lib/main.dart');
  final backIdx = main37.indexOf('await state.handleBack()');
  final tabIdx = main37.indexOf('state.setTab(0)');
  check(backIdx > 0 && tabIdx > 0 && backIdx < tabIdx,
      '返回键先问页面状态，再退回浏览器标签');

  // 通行证是 HttpOnly，只能让 WebView 自己发一次请求，读它的真实出站头。
  stdout.writeln('=== 38. WebView 代取通行证 ===');
  check(activity37.contains('WEBPROBE_CHANNEL = "com.nerelict/webprobe"'),
      '原生注册代取通道');
  check(activity37.contains('shouldInterceptRequest') &&
          activity37.contains('requestHeaders'),
      '从真实出站请求头里取 Cookie');
  check(activity37.contains('wv.destroy()'), '抓到或超时都销毁 WebView');
  check(activity37.contains('18_000'), '代取有整体超时，不死等');
  // 光有状态码分不出「防盗链 403」和「人机验证 403」，正文才是判据。
  check(activity37.contains('__probeFetchResult'), '回传 fetch 的状态码与正文开头');
  check(activity37.contains('__probeDomainCookies'), '回传该域一共几份 Cookie');
  final res38 = read('lib/services/web_probe_result.dart');
  check(res38.contains('Cloudflare 挑战页'), '能认出正文是挑战页');
  check(res38.contains('该域一份 Cookie 都没下发'),
      '区分「该域没给 cookie」与「给了但没带上」');
  // 人机验证常是「先给挑战页、几秒后自动跳回」：只 fetch 一次正好撞在挑战页上，
  // 所以要一轮轮重试。
  check(activity37.contains('fetchLoop') && activity37.contains('postDelayed(this'),
      '代取每 2 秒重试一次 fetch，给挑战页留出自动通过的窗口');
  check(activity37.contains('__probeFetches'), '回传一共试了几轮，区分「试过多次」与「只来得及一次」');
  // 这台 ROM 会过滤第三方应用的 Log.d——用 Log.i，并且**诊断必须回传给界面**，
  // 否则「为什么没抓到」只能靠用户描述。
  check(!activity37.contains('Log.d("NerelictProbe"'),
      '探针不用 Log.d（部分 ROM 会过滤第三方 debug 日志）');
  check(activity37.contains('Log.i("NerelictProbe"'), '探针用 Log.i');
  check(activity37.contains('__probeRequests') &&
          activity37.contains('__probeWithCookie') &&
          activity37.contains('__probePages'),
      '没抓到 Cookie 也要回传诊断字段，不能只回 null');
  check(read('lib/services/web_probe_result.dart').contains('隐藏页面'),
      '诊断能说清卡在「页面没开 / 没发请求 / 没带 Cookie」哪一步');
  final probe38 = read('lib/services/web_probe.dart');
  check(probe38.contains("'com.nerelict/webprobe'"), '两端通道名一致');
  check(probe38.contains('captureCookie'), '只对外暴露 Cookie 串');
  final hd38 = read('lib/services/hls_downloader.dart');
  check(hd38.contains('captureProbe') && hd38.contains('_clearanceOverrides'),
      '下载器接受代取结果并按 host 复用');
  final capIdx = hd38.indexOf('await _captureBeforeRetry();');
  final delayIdx = hd38.indexOf('await Future<void>.delayed(Duration(milliseconds: 400');
  check(capIdx > 0 && delayIdx > 0 && capIdx < delayIdx,
      '先补凭证再退避重试（顺序反了就白跑一次）');
  check(hd38.contains('missingClearance') || hd38.contains('_lastClearanceSent == false'),
      '只在「缺通行证」时触发代取，不无脑抓');
  check(read('lib/state/app_state.dart').contains('WebProbe.capture('),
      '状态层把代取接到下载器');
  // 代取到的 Cookie 只有「重试时重新算头」才用得上：
  // 头在闭包外算一次的话，三次重试发的都是同一份旧头，代取等于白做。
  check(hd38.contains('每轮重试都重新算头'),
      '重试时重算请求头（否则代取到的 Cookie 用不上）');
  // 同一个地址、同样只剩 UA+Referer，播放代理（dart:io HttpClient）能取到、Dio 403：
  // 差异在客户端本身，所以失败时直接复用「已经跑通」的那套实现。
  check(hd38.contains('_fetchTextViaClient') && hd38.contains('_fetchBytesViaClient'),
      '清单与分片都有「代理同款 HttpClient」兜底');
  final altIdx = hd38.indexOf('_fetchTextViaClient(url, referer)');
  check(altIdx > 0, 'Dio 失败后才走兜底，不改变正常路径');
  check(activity37.contains('window.__nr'),
      'fetch 结果写到 window 上（evaluateJavascript 对 Promise 只回 {}）');

  // 用户实测：关掉「边下边播缓存」时 HLS 直连能播，开启后改走 Dart 代理就播不了。
  // 说明站点按 TLS / HTTP 栈识别客户端：ExoPlayer（Android 栈）能过，dart:io 被拒。
  check(activity37.contains('NATIVE_HTTP_CHANNEL = "com.nerelict/nativehttp"'),
      '原生提供 Android HTTP 栈的取字节通道');
  check(activity37.contains('HttpURLConnection'), '用与 ExoPlayer 同层的 HttpURLConnection');
  check(read('lib/services/native_http.dart').contains("'com.nerelict/nativehttp'"),
      '两端通道名一致');
  check(hd38.contains('nativeFetch') && hd38.contains('_fetchTextFallback'),
      '下载兜底优先走原生栈');
  final nativeIdx = hd38.indexOf('_tryNative(url, headers, null)');
  final clientIdx = hd38.indexOf('_fetchTextViaClient(url, referer);');
  check(nativeIdx > 0 && clientIdx > 0 && nativeIdx < clientIdx,
      '先原生、再 dart:io（顺序反了就还在用被拦的那条）');
  check(read('lib/state/app_state.dart').contains('NativeHttp.fetch'),
      '状态层把原生取字节接到下载器');

  // 代理失败不能直接报错：换个客户端就播不了，等于「开缓存」=「这个站废了」。
  final pp38 = read('lib/ui/player_page.dart');
  check(pp38.contains('_proxyDisabled') && pp38.contains('_proxyBlockedHosts'),
      '代理失败时记住 host，并允许本次改直连');
  check(pp38.contains('proxy failed, retry direct'),
      '代理失败自动换直连重试，而不是直接甩错误');
  // 直链以前完全没有重试：被挑战只能直接失败，必须补一条「补凭证后重试」。
  check(hd38.contains('Future<Response<ResponseBody>> start()'),
      '直链下载抽出可重试的请求');
  final capCount = '_captureBeforeRetry()'.allMatches(hd38).length;
  check(capCount >= 2, '播放列表/分片与直链两条路都接了代取重试');
  check(files37.contains('if (!file.isDir) parts.add(file.sizeText)'),
      '目录行不显示大小');
  // 拦截器全局注册，必须各自判断「我是不是当前页」，否则会互相抢返回
  check(files37.contains('_app.tabIndex != 1'), '文件页只在自己那页处理返回');
  check(read('lib/ui/browser_tab.dart').contains('_state.tabIndex != 0'),
      '浏览器页只在自己那页处理返回');

  // 下载被 Cloudflare 挡下的两层原因：Cookie 读不到（可能 HttpOnly）与请求特征不像浏览器。
  // 方案见 docs/download-auth-and-challenge.md，这里锁住「实现别走偏」：
  // 头只补浏览器必带的项、诊断三种情况不混、ExoPlayer 直连不被动过。
  stdout.writeln('=== 34. 回源请求的浏览器一致性与 403 诊断 ===');
  final bh34 = read('lib/services/browser_headers.dart');
  check(bh34.contains("'Sec-Fetch-Site'") && bh34.contains("'Sec-Fetch-Dest'"),
      '补齐 Sec-Fetch-* 三项');
  check(bh34.contains("'Accept': '*/*'"), '补 Accept');
  check(!bh34.contains("'User-Agent'") && !bh34.contains("'Cookie'"),
      '不产出 UA / Cookie（会覆盖真实会话）');
  // 注释里会提到 Range / sec-ch-ua 以解释「为什么不加」，所以只匹配作为键出现的形态
  check(!bh34.contains("'Range'") && !bh34.contains("'sec-ch-ua"),
      '不产出 Range，也不猜 sec-ch-ua（值必须与 UA 版本对应）');
  final hd34 = read('lib/services/hls_downloader.dart');
  check(hd34.contains('browserMediaHeaders(url'), '下载回源用到这份头');
  check(hd34.contains('describeAuthFailure('), '403 文案走统一诊断');
  check(hd34.contains('PageCookieProbe.lengthFor('), '诊断里带上页面可见 Cookie 读数');
  // 「带了 9 项 Cookie」和「带了通行证」不是一回事：前者可能是 9 个无关的小饼干，
  // 后者才是能过 Cloudflare 的那一张。这一位决定下一步是代取凭证还是查指纹。
  check(hd34.contains('_lastClearanceSent') && hd34.contains('hasClearanceCookie'),
      '记录这次带的 Cookie 里有没有通行证');
  check(read('lib/services/download_diagnosis.dart').contains('kClearanceCookieNames'),
      '通行证名字表集中在诊断模块');
  // 播放器只发 UA + Referer 就能 200，下载多带 Cookie / Sec-Fetch 却 403：
  // 403 的第一步应该是「退回播放器那套头」，而不是去猜凭证。
  check(hd34.contains('_minimalHosts') && hd34.contains('_minimalTriedHosts'),
      '403 先降级到播放器的最小请求头');
  check(hd34.contains('_minimalTriedHosts.add(reqHost)'),
      '精简模式只给 UA + Referer，不写 Cookie');
  // Dio 的 BaseOptions 会合并进每个请求：那里还留着 `Accept: */*` 的话，
  // 「精简模式」其实是 UA + Referer + Accept，跟播放代理并不一致。
  check(!hd34.contains("'Accept': '*/*'"),
      'BaseOptions 不再兜底带 Accept（否则精简模式名不副实）');
  check(hd34.contains('_lastHeaderNames') && hd34.contains('_headerNamesOf'),
      '记录本次实际发出的头名字，并带进错误提示');
  // 「server 含 cloudflare 就算被挑战」是误判来源：普通防盗链 403 也会带这个头
  check(!hd34.contains("server.contains('cloudflare')"),
      '不再把 server: cloudflare 当成被挑战');
  check(hd34.contains("value('cf-mitigated')"), '只认 cf-mitigated 这个明确信号');
  // 播放代理**不能**跟着下载器一起加浏览器特征头：0.4.6 加过一次，
  // 把本来能播的 HLS 站点打回 403。播放是通的路径，不许拿来做实验。
  final proxy34 = read('lib/services/streaming_proxy.dart');
  check(!proxy34.contains('browserMediaHeaders'),
      '播放代理不加浏览器特征头（只发 UA + Referer + Cookie）');
  check(proxy34.contains("req.headers.set('User-Agent', MediaSource.userAgent)") &&
          proxy34.contains("req.headers.set('Referer', referer)"),
      '播放代理的身份头仍是 UA + Referer 那套最小集合');
  check(read('lib/services/browser_headers.dart').contains('只给下载器用'),
      '浏览器头的适用边界写在模块里，避免再被复用');
  check(!read('lib/services/media_source.dart').contains('Sec-Fetch'),
      'ExoPlayer 直连不被动过（当前播放是通的）');
  check(read('lib/services/page_cookie_probe.dart').contains('lastHost'),
      '页面 Cookie 读数按 host 存，换站不串');
  check(read('lib/ui/browser_tab.dart').contains('PageCookieProbe.attach(') &&
          read('lib/ui/browser_tab.dart').contains('_readDocumentCookieLength'),
      'WebView 侧注入读数探针');
  check(projectFile('tool/verify_browser_headers.dart').existsSync(),
      '提供头映射与诊断的纯 Dart 断言');
  check(projectFile('docs/download-auth-and-challenge.md').existsSync(),
      '方案文档落在 docs 下');
  // 实测：master 与 media 两条 m3u8 都会因 Cookie 缺失被拦，换源绕不过这一层。
  // 提示不能再声称「换 video.m3u8 通常能过」。
  check(!hd34.contains('换那条下载通常能过') && hd34.contains('Cookie 这条仍然存在'),
      '提示不再承诺「换源就能过」（两条都被拦过）');
  check(hd34.contains('crossHost') &&
          read('lib/services/download_diagnosis.dart').contains('crossHost'),
      '跨域与 HttpOnly 分开判（分片的 Cookie 读数不通用）');

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
