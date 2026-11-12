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
| `verify_playback.dart` | 播放代理链路：302 回源、最终 URI、m3u8 改写、MIME、缓存键 |
| `verify_p0.dart` | 重定向 base、直播标记、续传不串片、直链 `If-Range` |
| `verify_p1.dart` | `ss_*` 残留清理、直链背压写盘、中途暂停状态收敛 |
| `verify_download.dart` | 真实公开测试流跑“解析 → 分片 → 解密 → 合并”（依赖公网，可能超时） |
| `smoke_device.dart` | 真机冒烟：冷启动、三页切换、截图、崩溃日志（需要 adb + 设备，**不进常规回归链**） |
| `verify_file_manager.dart` / `verify_v2_features.dart` / `verify_v34.dart` / `verify_v334.dart` | 文件管理、直链分流、转换策略、文件类型与主题解析 |
| `serve_test_hls.dart` | 起本地 HLS 服务，配合 `adb reverse` 做真机端到端 |

断言数量会随版本增长，**以脚本自身输出的汇总行为准**，不要在文档里写死数字。

## 版本号规则（用户已定，不要自行发挥）

- 三段式：`pubspec.yaml` 的 `version: 0.4.1+21`，`+21` 是 Android `versionCode`，整数、只增不减，每次发版 +1。
- `versionName` 由 `android/app/build.gradle.kts` 的 `flutter.versionName` 直取三段，**不覆盖第四段**。
- 第三段按整数顺延（`0.4.0` → `0.4.9` → `0.4.10`），**不逢十进一**；提升第二、第一段必须先得到用户明确同意。
- 发版需同步四处：`pubspec.yaml`、`lib/ui/settings_tab.dart` 的 `appVersion`、`README.md`（`nerelict/` 内）的版本历史、`tool/verify_v35.dart` 第 9 节断言。以下路径均相对 `nerelict/`。

## 构建策略（用户已定）

- 发布构建固定 `--target-platform android-arm64`，产物约 21 MB，明确放弃 32 位 `armeabi-v7a` 与 x86_64 模拟器。
- 体积差异来自少打两组 `libflutter.so` / `libapp.so`，不是代码裁剪。**不要为了“对齐历史体积”去掉该参数。**
- 将来需要模拟器时改为 `--target-platform android-arm64,android-x64`，不改源码。
- release 构建在存在 `android/key.properties` 时用正式 keystore 签名，缺失时自动回退 debug 签名（保证他人 clone 后可直接构建）。
  `key.properties` 与 `.jks` 一律放在仓库外或保持忽略状态，**绝不提交**；签名材料丢失会导致已安装用户无法覆盖升级。
- `packaging { jniLibs { excludes } }` 剔除了 `armeabi-v7a` / `x86_64` 的插件 so，使不支持的设备在安装阶段即报不兼容，而不是装完启动崩溃。要支持模拟器时同步调整这里与 `--target-platform`。

## 代码约定

- **对外品牌统一为 `Nerelict`**：播放器在设置里叫「Nerelict 播放器」，源码注释、
  文案、缓存目录、通知渠道与持久化键一律不用历史代号。旧键只能以「迁移常量」形式出现，
  `verify_v35.dart` 第 23 节会扫描并阻止回归。
- **状态管理用 `provider` + `ChangeNotifier`**（`lib/state/` 下 `AppState` / `SettingsState` / `HistoryState` / `WebFavoritesState`），不引入其他状态库。
- **JS 注入脚本与 Dart 通信走 `JavaScriptChannel`**：`SniffChannel`（嗅探）、`PlayerChannel`（可播放视频探测与接管）、`FloatChannel`（网页 `<video>` 长按浮标）。三个脚本各自包一层 `fetch` / `XHR` / `media src`，链式调用必须互不干扰。
- **原生能力走 `MethodChannel`，两端名字必须同步改**：`com.nerelict/mp4`、`com.nerelict/storage`、`com.nerelict/player`、`com.nerelict/screen`、`com.nerelict/install`、`com.nerelict/network`。Dart 端在 `lib/services/*.dart`，Kotlin 端在 `MainActivity.kt` 注册。
- **路径一律走 `lib/services/app_paths.dart`**：`joinPath` 拼接、环境变量键 `NERELICT_DOWNLOAD_DIR` / `NERELICT_INSTALL_SKILL_DIR` / `NERELICT_PROJECT_ROOT` / `NERELICT_HLS_HOST` / `NERELICT_HLS_PORT`。**禁止硬编码盘符、`Directory.current` 或固定项目位置**；下载目录名统一用 `kDownloadDirName`（`Nerelict`）。
- **MP4 转换只做无重编码转封装**（`MediaExtractor` + `MediaMuxer`，`Mp4Converter.kt`），不引入 FFmpeg；只搬 H.264/HEVC + AAC 样本，其它编码明确报不支持。
- **播放器分层不要打穿**：`media_source` → `player_core`（抽象接口，UI 只依赖它）→ `player_ui`；`download_cache`（本地代理）与 `media_session`（原生通知/音频焦点）是两条可独立关闭的旁路。
- 网络用 `dio`，AES-128 解密用 `pointycastle`，播放用 `video_player`（Android 底层 media3/ExoPlayer）。**新增依赖前先确认能否用现有依赖实现。**
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

- 真机截图是缩放图（1080x2400 设备截图常见为 483x1080），**点击坐标要按比例换算**，否则会点错行。
- vivo 百度输入法会把 `adb shell input text` 的 ASCII 当拼音；可临时 `ime disable` / `ime enable` 恢复，用完必须还原。
- `adb reverse` 不跨命令持久，需与设备操作放在同一条命令里；PC 侧访问 `adb forward` 端口要加 `--noproxy '*'`。
- Git Bash 会把设备侧 `/sdcard/...` 转成 Windows 路径，涉及设备路径的操作改用 PowerShell。
- Gradle wrapper 可能因 hash 目录只有 `.part` 而卡住；**不要改仓库里的 `distributionUrl`**，改为补齐本机缓存。
- 直播流（无 `#EXT-X-ENDLIST`）只下载当前列表分片；应用未接入前台服务，长时间后台播放受厂商省电策略限制。
