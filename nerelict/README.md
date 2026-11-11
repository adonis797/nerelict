# Nerelict

浏览网页 → 当前页浮层 MA8N → 下载 / 一键转 MP4 / 应用内播放。Flutter + Android WebView。

> **用途边界**：本项目仅用于个人学习与技术研究，请只对自己拥有合法访问权限的内容使用，
> 并遵守来源网站的服务条款与适用法律；不提供绕过付费、鉴权或 DRM 保护的能力。
> 仓库根目录另有 `README.md` 与 MIT 许可证。

## 名字由来

`Nerelict` = `net` + `relic`（读音也接近 `derelict`）：把网页里散落、易逝的流媒体片段
打捞下来，变成可以长期保存的本地文件 —— 一份「网络遗物」。

> v3.0 在 v2.0 基础上新增：浏览历史（可清空全部）、MA8N统一命名与「不跳页」浮层、
> 各任务独立暂停/继续与断点续传、下载中任务即时删除、已下载内容应用内直接播放、
> 界面不再展示文件路径、用户自选下载位置。原有浏览、嗅探与 HLS 下载链路保持兼容。
>
> v3.1 完善嗅探与播放：M3U8 作为可直接播放条目交给 MA8N；分片识别、去重、聚合为
> 统一资源项并支持整体下载；浮层提升到 Navigator 之上且限制高度，关闭按钮与播放控件固定可见；
> 离开当前页面（网页切换、底部页切换、页面卸载）自动清空本页资源、选中项与播放状态。
>
> v3.2 交互补充：MA8N浮层可从标题栏拖动、位置持久化、边框与外边距收窄；地址栏右上角
> 新增手动嗅探；最近浏览新增「更多」展开框跳转独立历史页；下载页自动扫描本软件下载目录中的
> 视频并点击直接播放；设置新增搜索引擎切换（Bing / Google，默认 Google）。
>
> v3.3 按播放器方案落地：新增 media_source / player_core / media_session / download_cache /
> player_ui 分层；MA8N支持浮层 / 全屏 / 迷你小窗三态、倍速、画质与音轨切换、外挂字幕、
> 手势（进度 / 亮度 / 音量 / 双击 / 长按 2x / 锁定）、播放进度记忆与续播、边下边播缓存、
> 通知栏媒体控制、系统画中画、投屏设置入口、本地截帧、分享与收藏；网页视频长按浮标可手动接管。
>
> v3.3.1 界面调整：播放器控制层与画面层拆开，竖屏视频的进度条恢复浮层全宽、时长信息独占一行；
> 下载页新增文件管理（信息 / 重命名 / 删除），写操作统一同步任务引用、进度记忆、收藏与本地视频列表；
> 移除底部自动嗅探横幅，结果只在右上角「小闪电」面板呈现（带数量角标、可拖至 95%、可查看完整地址）。
>
> v3.3.2 五项交互：播放器去掉「MA8N」标题文字，下载改为标题栏图标并压缩底部操作区；
> 首页「清空全部」改为「全部历史」，历史页支持多选 / 全选 / 批量删除；新增网页收藏（地址栏星标
> + 首页区块，可拖动排序）与文件管理多选批量删除。网页收藏与视频收藏相互独立。
>
> v3.3.3 视觉与入口收敛：播放器底部与画质/音轨旁的「⋯」全部移除，播放增强统一收纳到标题栏
> 右上角三点菜单；标题栏的放大按钮改为迷你小窗（与下方全屏去重）；移除 HLS 角标，面板改为
> 半透明玻璃拟态；地址栏的收藏与主动嗅探合并进右上角三点菜单；网页加载进度条改为赛博朋克
> 霓虹风格（霓虹青→洋红渐变 + 光晕 + 头部亮点 + 未知进度扫描）；首页新增居中搜索框；网页收藏
> 新增独立单页视图（拖动排序 / 打开 / 删除 / 清空）。
>
> v3.3.4 六项改进：播放器不再显示画质档位/音轨数量；下载管理支持全部文件类型并按类型筛选；
> 全局文案由「MA8播放器」统一为「MA8N」；播放内核扩展封装与直链格式、m3u8 探测缓存并并行起播、
> 初始化限时重试，DASH 也能被识别接管；WebView 合并注入脚本、关闭媒体手势限制、进度刷新节流；
> 新增「赛博朋克 2077 × 狂野美漫」主题（霓虹洋红/青 + 深紫底 + 透视网格 + 扫描线 + 半调网点），
> 设置里可随时切换深色 / 浅色 / 赛博朋克。

> v3.4.0 八项改进：重写 MP4 转封装（时间戳重建 / ADTS→ASC / 关键帧对齐 / 产物解码校验），
> 修复转换后无法播放；下载任务与分片持久化到应用私有目录，退出应用后重新进入可恢复并自动续传；
> 播放器内点下载不再跳页，改为约 0.5 秒的底部悬停提示；「自动转 MP4」定义为下载完成即转换并删除
> 原 TS，下载页另设独立的批量 MP4 转换入口；全部历史支持时间正/倒序与按日期筛选、按日分组；
> 网页收藏支持编辑、分类、拖动归类、快速访问与网站图标自动识别；移除地址栏最左侧返回框并重做
> 地址栏样式；修复进入首个网址后返回直接退出应用（现在回到首页）。

> v3.5.0 运行与安装能力：设置新增「屏幕常亮」（默认开启，前台通过 FLAG_KEEP_SCREEN_ON
> 保持亮屏，下载 / 转换 / 播放不被自动息屏打断，不需要 WAKE_LOCK 权限）；新增「应用安装」
> 面板，支持能力探测与 APK 安装：系统签名 / priv-app（INSTALL_PACKAGES）或 root 设备走
> 静默安装，普通安装包自动回退系统安装器（FileProvider 交付，需点一次「安装」）。
> 静默安装受 Android 平台限制，普通第三方应用无法获得该权限，界面会如实显示当前设备能力。

> v3.5.1 修复与收敛：MP4 转封装改为「ADTS 拆帧 + 裸 AAC 写入」（原实现把带 ADTS 头的多帧样本
> 直接写进 MP4，esds 却声明 ASC，解码器必然失败 → 转换后无声）；音频编码选择独立，支持 AAC/MP3，
> 音频不被支持时只降级为纯视频而不是整体失败；安装功能从设置页移出，改为「关于 → 安装应用更新」，
> 只接受本应用包名的更新包。

> v0.3.5.2 安装链路收敛：移除应用内无障碍服务（不再申请、不再作为设置项），
> 「点击确认安装」整条流程改由电脑侧的独立安装脚本完成
> （adb install + uiautomator 识别安装页 + 勾选协议 + 点继续安装 + 版本校验），
> 与应用主流程完全解耦，任何 APK、任何设备都能复用。
> 同时修复：迷你小窗在切页 / 切后台往返时不再被关闭或替换；收藏提示缩短到 1.6 秒并支持点 × 或下滑关闭；
> 设置改为二级分类菜单（常规 / 播放 / 下载与存储 / 其他），关于页去掉包名与更新说明，仅保留「安装应用更新」入口；
> 版本号改为四位迭代号 0.3.5.2（pubspec 仍为 0.3.5+14，Gradle 覆盖 versionName）。

> v0.4.0 稳定性收尾：清除已结束任务时让仍在运行的自动转换 / 导出脱离，后台不再写回状态或弹提示；
> 新增残留 `ss_*` 临时分片目录的启动自动清理与下载页手动清理入口；目录扫描出错时保留上一次完整列表并给出提示；
> 直链下载改为受背压约束的流式写入。版本号统一为 pubspec 三段（`0.4.0+20`），不再覆盖第四段。
>
> v0.3.9.0 下载与播放链路正确性：播放列表跟随 CDN 重定向后用最终 URI 解析分片，
> 分片按 URL 身份命名并原子落盘（续传不再串片），直链续传带 If-Range 校验，
> 非 AES-128 加密与直播流给出明确提示，暂停立即生效；
> 播放代理同步支持重定向、BOM / 非 UTF-8 列表、独立音轨标签、Range / HEAD 语义与按扩展名的 MIME；
> 代理地址补齐可推断的文件名后缀，修复「边下边播缓存」开启时 HLS 被系统播放器误判为渐进式流而无法起播；
> 切到「文件 / 设置」时不再销毁正在播放的浮层播放器。
>
> v0.3.8.0 文件与下载拆分：底部第二个入口改为「文件」（浏览器 / 文件 / 设置），
> 文件页只展示下载目录中的实际文件（不再把已完成任务引用的文件排除，任务完成后立即可见）；
> 下载队列移为文件页顶部菜单的独立分支，顶部扫把替换为下载入口，扫把移入下载页（清除已完成）；
> 文件页顶部保留进行中任务提示（数量 + 平均进度），可直接进入下载页。
>
> v0.3.7.1 修复播放器初始位置与拖动：打开视频时面板贴住页面顶部（不再停在底部），
> 标题栏恢复拖动把手，可上下拖动到任意位置并在本次播放会话内保持；面板仍左右铺满。
>
> v0.3.7.0 交互细化：所有下拉框统一为主题化菜单（贴锚点、自动翻转、安全区避让、赛博描边）；
> 播放器默认贴合布局（左右铺满、贴住底部导航、仅上方圆角），小窗拖动避让状态栏与手势条并支持双击还原；
> 播放器双击分区（左退/右进 10 秒、中间暂停）并只在首次提示手势；下载卡片支持右滑暂停/左滑删除；
> 嗅探面板固定高度并支持分类筛选、搜索与批量下载；新增设置搜索（可直接定位并高亮）、下载/收藏空状态引导、
> 首页「再按一次退出」以及统一的错误提示「复制详情」。
>
> v0.3.6.0 三项优化：迷你小窗补进度条与点击定位、松手自动贴边；
> 下载调度新增并发上限、仅 Wi-Fi、失败自动重试；反馈统一为可关闭轻提示，新增诊断日志与导出。
> 另外修复：浮层拖动逐帧位移未累加（拖动只动一下就回弹）；系统媒体会话 stop 会误关迷你小窗（现在小窗只暂停）。
>
> 安装确认脚本属于外部工具，不包含在本仓库中。

## 功能与开关

| 功能 | 入口 | 默认 | 关闭后行为 |
|---|---|---|---|
| 自动接管网页视频 | 设置 → 自动接管网页视频 | 开 | 视频继续在网页内播放，仅保留原有嗅探 |
| 浅色主题 | 设置 → 浅色主题 | 关（原深色） | 恢复原有深色主题 |
| 下载完成后自动转 MP4 | 设置 → 下载完成后自动转 MP4 | 开 | 保留 TS，可在「下载」页的 MP4 转换入口手动转换 |
| 谷歌快捷入口 | 首页「快速访问」 | — | 与原有 3 个入口并存 |
| 通知栏 / 锁屏媒体控制 | 设置 → MA8N | 关 | 完全沿用原有播放方式，不申请音频焦点、不显示通知 |
| 自动续播 | 设置 → MA8N | 开 | 每次从头播放，不读取进度记忆 |
| 画面手势 | 设置 → MA8N | 开 | 画面只响应单击显示/隐藏控件 |
| 边下边播缓存 | 设置 → MA8N | 关 | HLS 直接回源播放，不经过本地代理 |
| 默认倍速 | 设置 → MA8N | 1x | 播放器内也可临时调整并记住 |
| 屏幕常亮 | 设置 → 屏幕常亮 | 开 | 交由系统息屏策略，长时间任务可能因休眠中断 |
| 应用内安装 APK | 设置 → 应用安装 | — | 静默不可用时回退系统安装器，需手动确认 |

- **MA8N**：`video_player`（Android 底层 media3/ExoPlayer）原生支持 HLS m3u8 与 MP4，
  可传 Referer。检测到视频后先暂停网页内 `<video>`，再以浮层形式叠在**当前页面**之上自动播放，
  不 push 路由、不替换 body，网页滚动位置与浏览状态不中断；浮层内有醒目的「下载当前视频」按钮，
  右上角可随时关闭。嗅探横幅上的手动「播放」入口同样只打开浮层。
  每页每个地址只自动接管一次，关闭后 10 秒内不重复接管。
- **浏览历史**：页面加载完成时记录地址/标题/访问时间，首页「最近浏览」按时间倒序展示并可清空全部。
- **下载**：m3u8 走原有 HLS 解析/解密/合并链路；mp4 等直链视频走流式直链下载；
  每个任务可独立暂停/继续（保留已下载分片，续传用 Range），删除立即响应且不残留。
- **MP4 转换**：Android 原生 `MediaExtractor` + `MediaMuxer` 无重编码转封装
  （`android/app/src/main/kotlin/.../Mp4Converter.kt`），通过 MethodChannel 调用；
  只搬运 H.264/HEVC + AAC 样本，不重新编码、不引入 FFmpeg。转换后可直接在应用内播放产物。

## 环境要求

| 工具 | 开发时版本 |
|---|---|
| Flutter | 3.47.x stable（Dart 3.13+） |
| JDK | 17 |
| Android SDK | Platform 36 / Build Tools 36 |
| NDK + CMake | `webview_flutter_android` 的 jni 模块需要，缺一不可 |

按本机实际路径设置 `ANDROID_HOME`、`ANDROID_SDK_ROOT`、`JAVA_HOME`；
`flutter pub get` 会生成 `android/local.properties`（含本机路径，已忽略，不要提交）。
国内网络的可选镜像配置、路径与运行配置见仓库根目录 `README.md`；
路径层边界验证：`dart run tool/verify_paths.dart`（27 项断言）。

## 构建 / 安装

```bash
flutter pub get
flutter analyze
flutter build apk --release --target-platform android-arm64
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

产物：`build/app/outputs/flutter-apk/app-release.apk`（约 20 MB，arm64-v8a 单架构，
由本机 `android/key.properties` 指定的 keystore 签名，未配置时回退 debug 签名）。
只面向 64 位 ARM 新设备，`armeabi-v7a` 与 `x86_64` 的插件 so 已在打包阶段剔除；如需模拟器支持，
把参数改为 `--target-platform android-arm64,android-x64` 并调整 `packaging` 排除规则，详见根目录 `README.md`。
应用名来自 `android/app/src/main/res/values/strings.xml` 的 `app_name`，
桌面显示「Nerelict」，`applicationId` 为 `com.nerelict.nerelict`。

Gradle 与 Maven 使用官方源。若国内网络下载缓慢，可按仓库根目录 `README.md`
的说明在本机配置镜像，这类改动属于本机配置，不要提交。

## 验证下载内核（不依赖 Flutter，可直接跑）

```bash
dart run tool/verify_download.dart
```

拿两个公开测试流跑完整链路：主播放列表选码率、分片并发下载、AES-128 解密、合并，
并校验输出头部的 TS 同步字节（0x47）。

## 结构

```
lib/
  main.dart                   入口、设置预加载、三页底部导航
  models/
    download_task.dart        任务状态机 + MP4 转换状态
    sniffed_media.dart        一条嗅探结果
  services/
    sniffer_js.dart           注入 WebView 的 m3u8 嗅探脚本（自动 + 手动重扫）
    player_probe_js.dart      注入 WebView 的「可播放视频」探测 + 暂停网页视频
    video_float_js.dart       网页 <video> 长按浮标（独立 FloatChannel，不干扰嗅探）
    resource_aggregator.dart  分片去重 / 变体聚合
    media_source.dart         [播放器] URL 归一化、Referer/UA、类型与 DRM 探测
    player_core.dart          [播放器] 抽象内核 + video_player/ExoPlayer 适配层
    player_platform.dart      [播放器] 原生媒体能力 MethodChannel 封装
    playback_memory.dart      [播放器] 播放进度记忆（续播）
    streaming_proxy.dart      [播放器] 本地 HTTP 代理，HLS 边下边播缓存（256MB 上限）
    favorites.dart            [播放器] 收藏（仅在播放器内读写）
    hls_parser.dart           m3u8 解析（主列表/媒体列表/KEY/MAP/序列号）
    hls_downloader.dart       分片并发下载 + AES 解密 + 合并；直链视频下载
    mp4_converter.dart        MethodChannel 封装（convert / info）
    local_media_scanner.dart  扫描本软件下载目录中的视频
    file_manager.dart         下载文件的信息 / 重命名 / 删除（保留扩展名、校验同名）
  models/
    web_favorite.dart         网页收藏条目（地址 / 标题 / 收藏时间，顺序由状态维护）
  state/
    app_state.dart            provider 状态：嗅探列表 + 任务列表 + 播放浮层三态 + 转换
    settings_state.dart       SharedPreferences 持久化的开关、搜索引擎与下载位置
    history_state.dart        浏览历史（按时间倒序，支持批量删除）
    web_favorites_state.dart  网页收藏（有序，支持拖动排序）
  ui/
    app_theme.dart            深/浅两套配色 + buildAppTheme
    browser_tab.dart          地址栏 + WebView + 嗅探横幅 + 起始页 + 长按视频浮标
    player_page.dart          [播放器] 浮层/全屏/迷你三态 + 手势 + 轨道菜单 + 内嵌面板
    downloads_tab.dart        任务列表、暂停/继续、播放、续播入口、MP4 转换
    history_page.dart         「全部历史」单页（多选 / 全选 / 批量删除）
    file_manager_sheet.dart   下载页文件管理面板（信息 / 重命名 / 删除 / 多选批量删除）
    settings_tab.dart         搜索/外观/视频播放/MA8N/下载与转换 + 关于
android/app/src/main/kotlin/.../
  MainActivity.kt             MethodChannel: convert / info / pickDirectory / exportFile / player
  Mp4Converter.kt             MediaExtractor + MediaMuxer 转封装
  PlayerPlatform.kt           MediaSession/通知栏媒体控制、音频焦点、亮度/音量、
                              屏幕方向与常亮、系统画中画、投屏设置、本地截帧、分享
```

### 播放器分层与边界（v3.3）

`media_detect`（现有 JS 通道） → `media_source`（归一化/请求头/类型探测） →
`player_core`（抽象接口，当前实现包住 `video_player`，Android 底层仍是 media3/ExoPlayer，
复用其 HLS/DASH/Progressive 解码与 video/audio track 选择） →
`player_ui`（浮层 / 全屏 / 迷你三态共用一个内核与一个 `PlayerPanel` 实例）；
`download_cache`（本地代理，默认关闭）与 `media_session`（MethodChannel + 原生）是两个可独立关闭的旁路。

菜单改为浮层内嵌面板，不使用 Navigator 弹窗，避免被「始终置顶」的浮层自己盖住。
UI 只依赖 `PlayerCore` 接口，将来替换成自研 Texture / PlatformView 内核不需要改 UI。

### 嗅探与接管怎么做的

`sniffer_js.dart` 在 `onPageStarted` / `onPageFinished` 时注入，三条互补路径：

1. 包装 `window.fetch` 和 `XMLHttpRequest.prototype.open` —— 页面自己发请求时立刻命中；
2. 每 2 秒扫 `performance.getEntriesByType('resource')` —— 兜住脚本注入之前就发出的请求；
3. 扫 `<video>/<source>` 的 src，以及页面地址本身（直接把 m3u8 地址当网页打开也能识别）。

命中后通过 `JavaScriptChannel('SniffChannel')` 回传，Dart 层去重后弹底部横幅。

`player_probe_js.dart` 是独立的第二条通道 `PlayerChannel`：
m3u8 命中 fetch/XHR/performance/video/页面地址任一即可；mp4 等直链只认 `<video>/<source>`
和页面地址，避免广告视频误触发。两个脚本各自包一层 fetch/XHR/media src，
链式调用互不干扰。只放行 `http/https` 导航，拦掉 App 深链。

### 下载怎么做的

- 主播放列表按 `BANDWIDTH` 排序取最高码率，码率标签显示在任务卡片上；
- 分片并发 4 路；`AES-128` 用 `pointycastle` CBC + PKCS7 解密，未显式给 `IV` 时按分片序号推 16 字节大端 IV；
- 每个请求 45 秒整体超时（dio 的 `receiveTimeout` 只管两次数据之间，慢速滴流会一直挂着），超时后 `CancelToken` 取消并重试 3 次；
- 分片先落临时目录，全部完成后按顺序流式合并，避免内存峰值；
- 直链 mp4 流式落盘到临时文件，暂停后用 `Range` 从已下载字节续传；服务端不支持 Range 时自动从头重写；
- 暂停会中断在途请求但保留临时分片，删除任务会立即掐断请求并清理，各任务互不影响；
- 成品默认写入应用私有目录（无需存储权限）；若用户在「设置 → 下载位置」选了目录，
  会通过系统目录选择器（SAF）把成品再导出一份，应用内播放始终使用私有目录里的原件。

## 已知限制

- MP4 转换仅支持 H.264/HEVC + AAC 编码的 TS；其它编码（如 MPEG-2、AC3）会提示不支持，
  原 `.ts` 文件仍然可用。fMP4 分片本身输出就是 `.mp4`，不显示转换按钮。
- Service Worker、WebSocket 推流或 blob 地址的站点可能嗅探不到。
- 直播流（无 `#EXT-X-ENDLIST`）只下载当前列表里的分片。
- 应用图标仍是 Flutter 默认图标；release 包由本机 keystore 签名，未上传应用商店。
- 播放器：DRM（Widevine / ChinaDRM / SAMPLE-AES）、MSE/EME、`blob:` 地址、短时效签名 URL 不承诺支持；
  AV1、杜比视界、AC3/E-AC3 等编解码能力随设备而异；DASH 由系统解码器决定，未做专门适配。
- 投屏只提供系统投屏设置入口，未接入设备发现 / DLNA / Cast 协议；网络流无法截取纹理画面，
  截图只对本地文件可用（系统 `MediaMetadataRetriever` 取帧）。
- 未接入前台服务：应用切到后台时 `video_player` 会自动暂停、回前台自动恢复；通知栏控制与音频焦点
  用于前台/近期任务场景，长时间后台播放受厂商省电策略限制。系统画中画需 API 26+ 且设备支持。
- 边下边播缓存只缓存 HLS 分片的完整 GET 响应，带 Range 的请求直接回源转发；
  缓存与「下载完成导出」是两条独立路径，缓存有 256MB 上限并会在启动时清理。
