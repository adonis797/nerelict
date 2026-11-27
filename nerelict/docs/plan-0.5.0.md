# 0.5.0 实施方案

版本定位：把「音轨被拆成独立流的视频」从下不了变成能下，再补上三条日常闭环——
自动更新、字幕闭环、睡眠定时器。多窗口嗅探属于架构重构，单列 0.5.1 / 0.6，不进本版本。

版本号 `0.5.0+35`；`publishedVersionCode` 从 33 改为 34。第二段从 0.4 提到 0.5 已经确认。

---

## 一、音视频分离流下载（主线）

### 现状

- `parseMasterPlaylistFull` 已经解析出 `HlsRendition`，`isSeparate` 表示 AUDIO 组声明了 `URI`。
- `HlsDownloader` 目前主动拒绝：`hls_downloader.dart` 里 `separateAudioFor(chosen)` 非空时，
  用户明确选中就抛异常，默认落到该档就自动降级并写 `variantNote`。
- 选流面板把这类档位标成不可选（`variant_picker.dart` 的提示文案）。
- `Mp4Converter.convert(inputPath)` 是单输入：一个 `MediaExtractor` 对一个 `MediaMuxer`。

### 目标

1. 选流面板不再把这类档位标成不可选。
2. 下载时同时取视频轨与音轨，产出有声 MP4。
3. 任一条轨失败要明确说是哪条失败，绝不产出无声成品。

### 拆解

1. **模型**：`DownloadTask` 增加 `audioUrl`（独立音轨的子播放列表地址）、`audioName`（音轨
   语言 / 名称，用于界面说明）、`audioPath`（分轨中间产物）。序列化与反序列化都要补，
   旧任务缺字段按 `null` 处理，不影响续传。
2. **解析**：`HlsMaster` 补一个 `preferredAudioFor(v)`：按 `DEFAULT=YES` → 用户语言 → 组内第一条
   的顺序选一条 `isSeparate` 的 AUDIO rendition。`separateAudioFor` 保留，用于界面标注。
3. **下载**：把 `_downloadMedia` 的「按 media playlist 下载分片并合并到目标文件」抽成可复用方法，
   第二次用音轨 playlist 调用，产物落 `<id>.audio.ts`（fMP4 音轨则是 `.m4a`）。
   - 进度分母必须合并：`totalSegments = 视频分片数 + 音频分片数`，`doneSegments` 跨两段累加，
     否则第二条轨开始时进度条会往回跳。
   - 两条轨共用同一份 `Referer` / 请求头 / Cookie 解析，音轨 URL 可能在不同 host。
4. **原生**：`Mp4Converter` 增加 `convert(videoPath, audioPath)` 重载，`remux` 从单 extractor
   扩成两个 extractor、两个 `addTrack`，按 PTS 交错 `writeSampleData`。
   - 视频轨沿用现有的等间隔网格重建（B 帧处理逻辑不能动）。
   - 音频轨直接按原始 PTS 写，只做起点归零（`sampleTime(0)` 减去首帧时间）。
   - 两轨各自归零后，若首帧时间差超过 100ms，以视频轨为基准整体平移音频。
5. **兜底与文案**：音轨失败 → 任务失败，文案「画面已下载，音轨抓取失败」；转封装失败 →
   保留两个分轨文件并在任务上提示可手动重试。
6. **不做**：播放器运行期切音轨。多轨 HLS 在播放时由 ExoPlayer 自己处理，这部分本来就能用。

### 验收

- 新增 `tool/verify_hls_audio.dart`（纯 Dart）：音轨分离识别、`preferredAudioFor` 的选择顺序、
  进度分母合并、旧任务缺字段的反序列化。
- 真机：找一条音轨分离的公开 HLS，下载 → 产物 MP4 有声音，拖到 3 个位置试听音画同步。
- 回归：`verify_download.dart`、`verify_mp4_timeline.dart`、`verify_v35.dart` 全过。

### 风险

- **音轨是 fMP4**：`#EXT-X-MAP` + `.m4s` 合并后本身就是 mp4，`canConvert` 只认 `.ts` 会挡住
  转换入口，需要放宽成「视频轨是 ts，音频轨任意可 `MediaExtractor` 读取」。
- **音频 PTS 不从 0 开始**：很常见，必须归零，否则整段音频偏移。
- **采样率 / 声道不一致**：不重编码，直接交给 `MediaMuxer`；失败就如实报不支持。

---

## 二、自动更新检查

### 现状

设置 → 其他 →「安装应用更新」走 `ApkInstaller.pickAndInstall()`，需要用户自己选 APK；
项目没有任何版本源。Release 就发在自己的 GitHub 上，天然可当更新源。

### 拆解

1. 新增 `lib/services/release_feed.dart`（纯逻辑可测部分单独抽出来）：
   `GET https://api.github.com/repos/adonis797/nerelict/releases/latest`，
   取 `tag_name`、`body`、`assets` 里第一个 `.apk` 的 `browser_download_url` 与 `size`。
2. 版本比较按三段语义，不按字符串：`0.4.9 < 0.4.10`、`0.4.14 < 0.5.0`。
3. 节流：`lastCheckedAt` 存 prefs，6 小时内不重复请求（匿名 API 每小时 60 次）。
4. 界面：「检查更新」一行显示当前版本；有新版本时显示版本号与红点，点开底部 sheet：
   更新说明（可滚动，截断到 400 字）、包大小、「下载并安装」。
5. 下载到临时目录 `update-<tag>.apk`，显示进度，完成后调 `ApkInstaller.install(path)`，
   已经是「静默安装失败回退系统安装器」的既有路径。
6. 校验：只比对 `asset.size`，不一致就重试一次并报「下载不完整」。签名交给系统安装器拦。

### 验收

- 新增 `tool/verify_update.dart`：三段版本比较（含 `0.4.9` vs `0.4.10`）、tag 解析、
  节流窗口、API 返回缺 assets 时的降级。
- 真机：装 0.5.0 之前的包 → 提示有新版本 → 下载 → 安装 → 版本变化、数据保留。

### 风险

GitHub API 可能超时或被限流，必须给出「检查失败，稍后再试」，不能静默转圈。

---

## 三、字幕闭环

### 现状

- `DownloadTask.subtitleNote` 只记了一串名字，字幕本身不下载。
- 播放器的外挂字幕是手填 URL（`player_page.dart` 的 `_subtitleCtrl`），能用的前提是用户自己
  知道字幕地址。
- `PlayerCore.setSubtitle(content, name)` 接收的是**字幕内容**，不是地址——这个接口正好可直接复用。

### 拆解

1. **下载**：`subtitlesFor(v)` 拿到字幕 rendition 后，取默认那条（`DEFAULT=YES`，没有就第一条），
   与成品放同目录，命名 `<成品基名>.<语言或序号>.vtt`。
2. **取内容**：字幕可能是单文件 `.vtt/.srt`，也可能是 `.m3u8` 分片包。后者要走分片下载再拼成
   一份 WebVTT，不能当单文件读。
3. **播放器字幕面板**：现在只显示「字幕 N 条」文字，改成可点列表，点一条即拉取内容并
   `setSubtitle(content, name)`；手填 URL 保留为兜底入口。
4. **本地视频**：`player_page` 打开本地文件时探测同名同目录字幕（`x.srt`、`x.zh.vtt`、
   `x.zh.srt`），命中自动加载。

### 验收

- 新增 `tool/verify_subtitle.dart`：字幕 rendition 选择、同名匹配规则（大小写、语言后缀）、
  m3u8 包字幕的拼接。
- 真机：带字幕的 HLS → 下载后目录里出现 `.vtt`；播放器点列表能出字幕；本地 mp4 + 同名字幕自动加载。

---

## 四、睡眠定时器

- 播放器三点菜单加「定时关闭」：15 / 30 / 60 分钟、播完当前。
- 实现：`player_page` 内 `Timer`，到点 `core.pause()`；「播完当前」用位置监听 + 时长判断。
- 约束：播放器关闭时必须取消 timer，否则会在别的页面把播放暂停掉；悬浮小窗接手播放时，
  定时器仍按前台时间计，不回退。

### 验收

- 组件层不易测，靠真机：设 15 分钟档，把常量临时改成 20 秒验证行为，再改回。
- `verify_v35` 增加断言：菜单项存在、timer 在 `dispose` 里取消。

---

## 五、发版配套

- 版本 `0.5.0+35`，同步 `pubspec.yaml`、`settings_tab.dart`、`README.md` 版本历史、
  `verify_v35.dart` 第 9 / 23 节；`publishedVersionCode` 33 → 34。
- README 功能表新增三行：音轨分离流下载（默认开）、检查更新（手动触发）、定时关闭（默认关）。
- README「已知限制」删掉「音轨独立成流无法下载」，改成「音轨独立流会一并下载并合并，
  但不会重编码，采样率异常时可能失败」。

## 排期

| 阶段 | 内容 | 说明 |
|---|---|---|
| 1 | 音轨分离下载（模型 + 双轨下载 + 原生 mux） | 最费时间，原生改动要留真机验证 |
| 2 | 自动更新 + 字幕闭环 | 两件都是纯 Dart 为主，可并行 |
| 3 | 睡眠定时器 + 文案 + 四处版本号 | 收尾 |

先做 1 的「能下能播」，跑通再进 2；播放器内切音轨不进本版本。
