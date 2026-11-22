# AGENTS.md

面向在本仓库中工作的 AI 代理与协作者的约定。README 讲“项目是什么”，这里讲“怎么改、怎么验、别踩什么”。

## 仓库布局

Git 仓库根是仓库根目录，Flutter 工程在子目录 `nerelict/`。

```
.
├── LICENSE                  MIT
├── README.md                仓库说明：名字由来、用途边界、环境要求、构建、国内镜像
├── .gitignore / .gitattributes
└── nerelict/                Flutter 工程（pubspec、lib、android、tool、test）
```

- **所有 Flutter / Dart / Gradle 命令都在 `nerelict/` 下执行**，不在仓库根执行。
- 根目录只放仓库级文件；功能文档主要在 `nerelict/README.md`（功能表、结构、分层、已知限制）。
- `.tmp/`、`.workbuddy/`、`android-sdk-inventory.md` 是本机私有数据，已被忽略，**不要提交，也不要当作产品代码修改**。

## 环境

| 工具 | 版本 |
|---|---|
| Flutter | 3.47.x stable（Dart 3.13+） |
| JDK | 17 |
| Android SDK | Platform 36 / Build Tools 36 |
| NDK + CMake | 必需（`webview_flutter_android` 的 jni 模块） |
| Gradle | 9.3.1（wrapper） |

- `flutter` / `dart` / `adb` 不保证在 `PATH` 中；需要时用绝对路径，或先加载本机环境脚本（不入库）。
- `nerelict/android/local.properties` 由 `flutter pub get` 生成，含本机路径，已忽略，**不要提交、不要手改**。
- `nerelict/android/key.properties` 指向本机 keystore，已忽略，**不要提交**；缺失时自动回退 debug 签名。
- 本机已知问题：`flutter test` 曾因 `flutter_tester` WebSocket 连接失败而不可用；Android 原生改动只能靠真实构建 + 真机验证确认。

## 常用命令

```bash
cd nerelict

flutter pub get
flutter analyze --no-pub                      # 必须保持 No issues found
dart run tool/verify_v35.dart                 # 主回归脚本，断言最多
flutter build apk --release --no-pub --target-platform android-arm64
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

### 回归脚本（`nerelict/tool/`）

不带 Flutter 引擎依赖，可用 `dart run` 直接跑；改动对应模块后至少跑相关的那些，最后跑 `verify_v35.dart`：

| 脚本 | 覆盖范围 |
|---|---|
| `verify_v35.dart` | 主回归脚本，安装能力、版本号、文案、常量与第 N 节分块断言 |
| `verify_paths.dart` | `app_paths.dart` 路径层边界（配置缺失 / 相对 / 绝对 / 穿越 / 回退 / 端口） |
| `verify_browser_headers.dart` | 回源请求的浏览器等效头（`Sec-Fetch-*` 推导、不覆盖 UA/Cookie/Range）+ 403 诊断三种情况不混 |
| `verify_media_meta.dart` | 文件页数据层：分类宫格覆盖、`.m3u8` 认作清单、清单解析、时长/分辨率文案、元数据缓存序列化 |
| `verify_playback.dart` | 播放代理链路：302 回源、最终 URI、m3u8 改写、MIME、缓存键 |
| `verify_p0.dart` | 重定向 base、直播标记、续传不串片、直链 `If-Range` |
| `verify_p1.dart` | `ss_*` 残留清理、直链背压写盘、中途暂停状态收敛 |
| `verify_v042.dart` | 本地 HTTP 服务跑「选流 / Cookie 鉴权 / 字节区间 / 断点」真实下载（不依赖公网） |
| `verify_windows.dart` | 多窗口：地址归一化、去重键、状态隔离、去重与上限、生命周期与资源释放护栏（纯 Dart） |
| `verify_storage_scan.dart` | 文件类型 MIME 嗅探（魔数）与全盘递归扫描：深度/系统目录/隐藏项/半成品/缓存与分片过滤、`includeNoise` 开关、用户目录优先、取消、上限截断（纯 Dart） |
| `verify_mp4_timeline.dart` | 转封装时间轴算法：B 帧重排识别、等间隔网格重建、缺段缺口（纯算法，不依赖设备） |
| `verify_download.dart` | 真实公开测试流跑“解析 → 分片 → 解密 → 合并”（依赖公网，可能超时） |
| `smoke_device.dart` | 真机冒烟：冷启动、三页切换、截图、崩溃日志（需要 adb + 设备，**不进常规回归链**） |
| `click_js_test.js` | 点击归因脚本的行为验证：登录弹窗不被误判成遮挡层、`window.open` 收窄并降级成同页跳转、`target=_blank` 接管、深链不被劫持（需要 Node，**不进 Dart 回归链**） |
| `verify_file_manager.dart` / `verify_v2_features.dart` / `verify_v34.dart` / `verify_v334.dart` | 文件管理、直链分流、转换策略、文件类型与主题解析 |
| `serve_test_hls.dart` | 起本地 HLS 服务，配合 `adb reverse` 做真机端到端 |

断言数量会随版本增长，**以脚本自身输出的汇总行为准**，不要在文档里写死数字。

## 版本号规则（用户已定，不要自行发挥）

- 三段式：`pubspec.yaml` 的 `version: 0.4.2+22`，`+22` 是 Android `versionCode`，整数、只增不减，每次发版 +1。
- `versionName` 由 `android/app/build.gradle.kts` 的 `flutter.versionName` 直取三段，**不覆盖第四段**。
- 第三段按整数顺延（`0.4.0` → `0.4.9` → `0.4.10`），**不逢十进一**；提升第二、第一段必须先得到用户明确同意。
- 发版需同步四处：`pubspec.yaml`、`lib/ui/settings_tab.dart` 的 `appVersion`、`README.md`（`nerelict/` 内）的版本历史、`tool/verify_v35.dart` 第 9 节断言。以下路径均相对 `nerelict/`。

## 构建策略（用户已定）

- 发布构建固定 `--target-platform android-arm64`，产物约 21 MB，明确放弃 32 位 `armeabi-v7a` 与 x86_64 模拟器。
- 体积差异来自少打两组 `libflutter.so` / `libapp.so`，不是代码裁剪。**不要为了“对齐历史体积”去掉该参数。**
- 将来需要模拟器时改为 `--target-platform android-arm64,android-x64`，不改源码。
- release 构建在存在 `android/key.properties` 时用正式 keystore 签名，缺失时自动回退 debug 签名（保证他人 clone 后可直接构建）。
  `key.properties` 与 `.jks` 一律放在仓库外或保持忽略状态，**绝不提交**；签名材料丢失会导致已安装用户无法覆盖升级。
- **真机验证一律安装正式签名包**：保留 `android/key.properties`，`flutter build apk --release` 之后 `adb install -r`，测的就是要发布的那个包。
  **不要**为了装机把 `key.properties` 临时移走、让构建回退 debug 签名——两套签名的包不能互相覆盖，来回切换必须卸载，
  会清空应用数据（播放缓存、收藏、续播、站点登录态），验证结果也不再等于发布包的真实表现。
  设备上若装过 debug 签名的包，卸载一次之后就一直用正式签名覆盖升级。
- `packaging { jniLibs { excludes } }` 剔除了 `armeabi-v7a` / `x86_64` 的插件 so，使不支持的设备在安装阶段即报不兼容，而不是装完启动崩溃。要支持模拟器时同步调整这里与 `--target-platform`。

## 代码约定

- **对外品牌统一为 `Nerelict`**：播放器在设置里叫「Nerelict 播放器」，源码注释、
  文案、缓存目录、通知渠道与持久化键一律不用历史代号。旧键只能以「迁移常量」形式出现，
  `verify_v35.dart` 第 23 节会扫描并阻止回归。
- **状态管理用 `provider` + `ChangeNotifier`**（`lib/state/` 下 `AppState` / `SettingsState` / `HistoryState` / `WebFavoritesState`），不引入其他状态库。
- **JS 注入脚本与 Dart 通信走 `JavaScriptChannel`**：`SniffChannel`（嗅探）、`PlayerChannel`（可播放视频探测与接管）、`FloatChannel`（网页 `<video>` 长按浮标）。三个脚本各自包一层 `fetch` / `XHR` / `media src`，链式调用必须互不干扰。
- **原生能力走 `MethodChannel`，两端名字必须同步改**：`com.nerelict/mp4`、`com.nerelict/storage`、`com.nerelict/player`、`com.nerelict/screen`、`com.nerelict/install`、`com.nerelict/network`、`com.nerelict/cookie`、`com.nerelict/external`、`com.nerelict/media`。Dart 端在 `lib/services/*.dart`，Kotlin 端在 `MainActivity.kt` 注册。
- **回源请求的身份要一致**：UA 统一读 `UserAgent.current`（WebView 建好后采纳真实 UA），
  浏览器等效头统一走 `lib/services/browser_headers.dart`。下载器与播放代理必须用同一份，
  否则同一个地址在站点眼里是两个客户端——这就是 0.4.4 之前「能播不能下」的根因。
  方案与取舍见 `nerelict/docs/download-auth-and-challenge.md`。
- **路径一律走 `lib/services/app_paths.dart`**：`joinPath` 拼接、环境变量键 `NERELICT_DOWNLOAD_DIR` / `NERELICT_INSTALL_SKILL_DIR` / `NERELICT_PROJECT_ROOT` / `NERELICT_HLS_HOST` / `NERELICT_HLS_PORT`。**禁止硬编码盘符、`Directory.current` 或固定项目位置**；下载目录名统一用 `kDownloadDirName`（`Nerelict`）。
- **MP4 转换只做无重编码转封装**（`MediaExtractor` + `MediaMuxer`，`Mp4Converter.kt`），不引入 FFmpeg；只搬 H.264/HEVC + AAC 样本，其它编码明确报不支持。
- **播放器分层不要打穿**：`media_source` → `player_core`（抽象接口，UI 只依赖它）→ `player_ui`；`download_cache`（本地代理）与 `media_session`（原生通知/音频焦点）是两条可独立关闭的旁路。
- 网络用 `dio`，AES-128 解密用 `pointycastle`，播放用 `video_player`（Android 底层 media3/ExoPlayer）。**新增依赖前先确认能否用现有依赖实现。**
- **多窗口是轻量浏览上下文**：`lib/ui/browser_windows_page.dart` 每个窗口独立 `WebViewController`，
  不注入 `SniffChannel` / `PlayerChannel` / `FloatChannel` / `ClickChannel`（这些依赖按「单一当前页」
  设计的全局单例）；嗅探与下载只在主界面 `browser_tab.dart` 里做。窗口状态走
  `window_registry.dart`（纯 Dart，可用 `dart run` 测）+ `windows_state.dart`（ChangeNotifier），
  窗口上限 5 个；关闭时先换掉 `NavigationDelegate` 再卸载 `about:blank`，
  **不要调用 `clearCache()`**（Android 缓存是应用级共享的）。
- **多窗口入口必须留在首页第一屏**：起始页搜索框下方常驻 `_WindowsEntryCard`（`browser_tab.dart`），
  和三点菜单里的同名项并存；上限文案取 `WindowRegistry.maxWindows`，不要写死数字。
- **多窗口交互**（对齐主流手机浏览器）：顶部一条地址栏 + 底部一条工具条
  （后退 / 前进 / 首页 / 窗口 / 关闭），窗口列表是卡片总览弹窗，**不要再加常驻标签条**；
  **新建窗口直接 `openBlank()` 落到窗口首页**（`_WindowHomeView`：搜索框 + 常用站点），
  不要退回「弹对话框要网址」的老做法。首页由 UI 层画，`BrowserWindow.isHome` 即 `url == null`；
  回首页 / 关闭窗口都会载 `about:blank`，导航回调必须对 `about:blank` 短路
  （`_isBlank`），否则窗口会被写成「正在加载 about:blank」，首页状态被覆盖。
- **文件页默认全盘、下载目录进菜单**：`lib/ui/files_tab.dart` 默认递归扫描整个内部存储
  （`_view == _FilesView.storage`，走 `lib/services/storage_scanner.dart`），下载目录是「更多」
  菜单里的入口（`_view == _FilesView.downloads` → `AppState.localFiles`）。
  **全盘与下载目录都可以重命名 / 删除**：两者共用 `showFileManagerSheet`（`onMoved` 把结果回写
  全盘快照，避免改个名字就重扫整个存储）；删除先进回收站，`FileTrash` 用 `.origin` 旁注记下原路径，
  撤销时回到删除前的目录。类型识别分两级：扩展名映射 `kExtKinds` 优先，无/未知扩展名
  读文件头魔数 `sniffKind` 兜底；`file_kinds.dart` 与 `storage_scanner.dart` 都保持纯 Dart
  （`LocalFile` 已挪进 `file_kinds.dart`），能被 `dart run` 直接断言。全盘扫描需
  `MANAGE_EXTERNAL_STORAGE`（「所有文件访问权限」），未授权显示引导卡。
- **全盘扫描必须过滤缓存与分片**（对齐系统 MediaStore，也是夸克 / 迅雷文件管理「识别正常」的原因）：
  - 任意层级跳过 `kStorageSkipDirs`（`Android`、`LOST.DIR` 等）与 `kNoiseDirNames`
    （`cache` / `thumbnails` / `tmp` / `logs` / `trash` 等），带 `.nomedia` 标记的目录整体跳过；
  - 同一目录内「纯数字段号 + 媒体扩展名」（`253.ts`、`0012.m4s`）达到 `kSegmentGroupMin = 3`
    个，才整组判为 HLS 缓存分片；**不要改成单文件判定**，否则 `2024.mp4` 这类正常命名会被误杀；
  - `seg_<hash>.bin` / `*.part` / `*.tmp` 是下载半成品，任何情况都不列；
  - 用户目录（`kStoragePriorityDirs`：Download / DCIM / Movies / Pictures / Music …）优先扫描，
    避免文件数上限（`kStorageScanMaxFiles`）先被冷门目录吃光；
  - 过滤是固定策略：**界面上不再有「显示缓存与视频分片」开关，也不弹「忽略了 N 个」横幅**；
    `scanAllStorage` 的 `includeNoise` 只留给回归脚本验证过滤本身。
- 注释与文档用简体中文，全角标点，引号用“”，不用直角引号；代码标识符用反引号。
- 换行符按 `.gitattributes`：文本 LF，`*.bat` CRLF。`gradlew` 必须保持 LF，否则 Linux/CI 无法执行。

## 文档同步

改动用户可见行为时，同步更新：

- `nerelict/README.md`：功能与开关表、结构树、分层说明、版本历史段落；
- 根 `README.md`：环境要求、构建参数、路径与环境变量；
- 两者都不写本机路径与镜像配置，镜像只作为“本机可选配置”说明。

## Git

- 远端 `origin` = `git@github.com:adonis797/nerelict.git`，主分支 `main`。
- 提交身份 `adonis797 <150109247+adonis797@users.noreply.github.com>`（已全局配置）。
- 常规流程：改动 → `flutter analyze --no-pub` + 相关 verify 脚本 → 必要时构建装机验证 → `git add . && git commit && git push`。
- 不要提交：`build/`、`.dart_tool/`、`.gradle/`、`.idea/`、`*.iml`、`local.properties`、`.env*`、`*.apk`、`*.log`、签名与密钥文件、`.tmp/`、`.workbuddy/`、`android-sdk-inventory.md`。

## 用途边界（不可协商）

本项目仅用于个人学习与技术研究，只对自己拥有合法访问权限的内容使用；**不提供、也不打算提供绕过付费、账号鉴权或 DRM 保护的能力**。`INSTALL_PACKAGES` 属系统级权限，普通安装包不会获得，只能自动回退到系统安装器。

## 已知限制与踩坑记录

- 真机截图在预览里是缩放图（1080x2400 设备截图显示为 483x1080），**不要靠目测换算坐标**：
  一律先 `adb shell uiautomator dump /sdcard/ui.xml` 拉下来读 `bounds`，再点。
  目测换算会偏几十到上百像素，轻则点空，重则点到相邻控件——本项目曾因此误删用户的一个成品视频。
- vivo 百度输入法会把 `adb shell input text` 的 ASCII 当拼音；可临时 `ime disable` / `ime enable` 恢复，用完必须还原。
- **`shouldInterceptRequest` 的 `requestHeaders` 里没有 `Cookie`**（Android 安全设计，cookie 在网络栈注入）。
  「用隐藏 WebView 抓真实出站头拿 HttpOnly 凭证」这条路从根上不成立；`CookieManager.getCookie()`
  又能读到该域的一部分 cookie，所以「读不到」和「没下发」是两件事，别混。
- **`evaluateJavascript` 对 Promise 只回 `{}`**。要拿异步结果必须让 JS 写进 `window.xxx`，下一轮再读。
  诊断写了却不生效时，先怀疑测量工具本身。
- **Cloudflare 这类站点按 TLS / HTTP 栈识别客户端，不按请求头**：同一个地址、同样只剩 UA + Referer，
  ExoPlayer 直连能过，Dart 的 `dart:io` 一律被拒。排查「能播不能下」时，**先确认播放走的是直连还是代理**
  ——`playerStreamingCache` 打开时 HLS 会改走 `StreamingProxy`（dart:io），关掉才是 ExoPlayer 直连。
  下载同理：优先用 `com.nerelict/nativehttp` 的 `HttpURLConnection`，别在请求头上继续加东西。
- `adb reverse` 不跨命令持久，需与设备操作放在同一条命令里；PC 侧访问 `adb forward` 端口要加 `--noproxy '*'`。
- Git Bash 会把设备侧 `/sdcard/...` 转成 Windows 路径，涉及设备路径的操作改用 PowerShell。
- Gradle wrapper 可能因 hash 目录只有 `.part` 而卡住；**不要改仓库里的 `distributionUrl`**，改为补齐本机缓存。
- 直播流（无 `#EXT-X-ENDLIST`）只下载当前列表分片；应用未接入前台服务，长时间后台播放受厂商省电策略限制。
