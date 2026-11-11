# Nerelict

Flutter + Android WebView 的浏览器应用：浏览网页时嗅探当前页的视频资源（HLS / 直链），
支持下载与断点续传、TS 转 MP4 封装，以及应用内浮层播放。

完整的功能、架构与开发说明见 [nerelict/README.md](nerelict/README.md)。

## 名字由来

**Nerelict** 是 `net` + `relic` 的混搭词，读音也靠近 `derelict`（被遗弃、随波漂流的东西）。
名字指向这个应用真正在做的事：网页里的流媒体地址往往是散落、临时、随时会失效的，
Nerelict 把它们从页面上打捞出来，整理成可以长期保存、随时回放的本地文件 ——
一份「网络遗物」。

## 用途与边界

本项目仅用于个人学习与技术研究，请只对你自己拥有合法访问权限的内容使用，
并遵守来源网站的服务条款与适用法律。项目不提供、也不打算提供任何绕过付费、
账号鉴权或 DRM 保护的能力。

`INSTALL_PACKAGES` 是 Android 系统级权限，只有系统签名 / priv-app / root 设备才能生效；
普通安装的应用不会获得该权限，安装功能会自动回退到系统安装器。

## 环境要求

| 工具 | 开发时版本 |
|---|---|
| Flutter | 3.47.x stable（Dart 3.13+） |
| JDK | 17 |
| Android SDK | Platform 36 / Build Tools 36 |
| NDK + CMake | `webview_flutter_android` 的 jni 模块需要 |

按本机实际路径设置 `ANDROID_HOME`、`ANDROID_SDK_ROOT`、`JAVA_HOME`。
`flutter pub get` 会生成 `android/local.properties`，该文件含本机路径，已忽略、不要提交。

## 路径与运行配置（可选）

项目不依赖固定项目位置、盘符或本机目录结构：

- **应用内目录**：下载成品、分片、任务状态、诊断日志都基于 `path_provider`
  提供的应用私有目录，用平台分隔符拼接，不需要存储权限，也不需要任何路径配置。
- **主机端脚本默认输出目录**：未注入 `resolveOutputDir` 时落在系统临时目录的
  `Nerelict` 子目录。设置 `NERELICT_DOWNLOAD_DIR` 可覆盖，支持绝对路径与相对路径
  （相对路径相对默认根目录解析）；空白、含 `..`、指向文件或不可创建的配置会自动回退，
  不会让下载中断。
- **项目自检脚本**：`tool/verify_v35.dart` 以脚本自身位置定位项目根，可从任意工作目录
  运行，不读取当前工作目录；特殊部署可用 `NERELICT_PROJECT_ROOT` 显式指定项目根。
  若要一并校验外部安装确认脚本，设置 `NERELICT_INSTALL_SKILL_DIR` 指向其目录；
  未设置时相关断言自动跳过。
- **本地 HLS 测试服务**：`NERELICT_HLS_HOST` / `NERELICT_HLS_PORT` 可覆盖默认的
  `127.0.0.1:8899`，端口非法或越界会回退默认值。
- **构建链**：Gradle 通过 Flutter 生成的 `android/local.properties` 读取 SDK 位置，
  仓库内不写死任何 SDK 路径；`ANDROID_HOME` / `JAVA_HOME` 由本机环境提供。

路径层边界验证：`dart run tool/verify_paths.dart`（27 项断言）。

## 构建

```bash
cd nerelict
flutter pub get
flutter analyze
flutter build apk --release --target-platform android-arm64
```

产物为 `nerelict/build/app/outputs/flutter-apk/app-release.apk`（约 21 MB）。

当前发布策略是**仅 arm64-v8a 单架构**：适配新设备，不打包 32 位 armeabi-v7a，
x86_64 模拟器暂不在支持范围（标准镜像会报 `INSTALL_FAILED_NO_MATCHING_ABIS`）。
因此体积比三架构通用包（约 57 MB）小约 36 MB，这来自少打两份
`libflutter.so` / `libapp.so`，不是代码裁剪或压缩。
将来需要模拟器时，把参数换成 `--target-platform android-arm64,android-x64` 即可，
无需改动源码，产物会相应增大约 21 MB。

## 签名

release 构建会读取 `nerelict/android/key.properties`（本机文件，已忽略）中的 keystore 信息，
用它给 `app-release.apk` 做正式签名；该文件不存在时自动回退 debug 签名，
因此克隆仓库后不做任何签名配置也能直接构建。

要自己出发布包，用 `keytool` 生成一份 keystore，再新建 `nerelict/android/key.properties`：

```properties
storePassword=你的库密码
keyPassword=你的库密码
keyAlias=你的别名
storeFile=/keystore/的绝对路径/release.jks
```

路径用正斜杠或双反斜杠。keystore 与密码放在仓库之外并做好备份——
**换一份签名后，已安装用户无法覆盖升级，只能卸载重装**。
验证签名是否生效：

```bash
"$ANDROID_HOME/build-tools/36.0.0/apksigner" verify --print-certs \
  nerelict/build/app/outputs/flutter-apk/app-release.apk
```

## 国内网络（可选，本机配置，不要提交）

仓库内 Gradle 使用官方源。若下载缓慢，可在本机做如下调整：

- Gradle 发行版：把 `nerelict/android/gradle/wrapper/gradle-wrapper.properties` 的
  `distributionUrl` 临时改为 `https://mirrors.cloud.tencent.com/gradle/gradle-9.3.1-all.zip`。
- 依赖仓库：新建 `~/.gradle/init.gradle`（本机全局文件，不在仓库内）：

```groovy
beforeSettings { settings ->
    settings.pluginManagement.repositories {
        maven { url = 'https://maven.aliyun.com/repository/google' }
        maven { url = 'https://maven.aliyun.com/repository/gradle-plugin' }
    }
}
allprojects {
    repositories {
        maven { url = 'https://maven.aliyun.com/repository/google' }
        maven { url = 'https://maven.aliyun.com/repository/central' }
    }
}
```

- pub 与 Flutter SDK：`export PUB_HOSTED_URL=https://pub.flutter-io.cn`、
  `export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn`。

## 许可证

[MIT](LICENSE)
