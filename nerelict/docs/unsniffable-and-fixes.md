# 嗅探不到 / 播不了的视频：原因分类与适配方案

这份文档回答一个问题：**什么样的网页视频，Nerelict 抓不到或播不了，能不能补。**
每条都写清「怎么判断」「现在什么状态」「打算怎么做」，代码里已实现的会标注。

判定优先级：先看页面是不是有真实网络请求（能抓），再看这个请求 Nerelict 能不能放（能播），
最后才谈「页面根本不给地址」的情况（抓不到）。

---

## 一、抓不到（页面里没有可下载的地址）

| 场景 | 判定信号 | 现状 | 方案 | 优先级 |
|---|---|---|---|---|
| **MSE / `blob:` 播放** | `<video src="blob:...">`，`MediaSource` 在用；网络面板里只有分片 | 已做：三条路收分片并聚合 `segmentGroup`；**0.4.3 起分片组可直接播放**（合成 VOD 播放列表走本地代理，分片仍带 Cookie/Referer） | 剩下的是 **fMP4 分片组**：缺 init 段，当前显式提示「建议下载」而不是硬凑一个放不了的文件 | 已做（fMP4 除外） |
| **Canvas / WebGL 自绘** | 页面里没有 `<video>`，只有 `<canvas>`；数据走 `WebSocket` / `wss` | 抓不到 | 不做。这类播放器不产生可复用的媒体请求，硬解只能靠录屏 | — |
| **WebRTC 推拉流** | `RTCPeerConnection`、`stun:`/`turn:` 地址 | 抓不到 | 不做（需要协议栈，不是嗅探问题） | — |
| **地址只存在于 POST 响应体里** | `fetch('/api/play', {method:'POST'})`，返回 JSON 里带 `m3u8` | **已做**（0.4.3）：包装 `fetch` 读 `response.clone().text()`，XHR 也监听 `load` 读响应体 | 只扫 `json/text/xml`、限 512KB、`\/` 转义还原、每次最多 8 条，不阻塞原请求 | 已完成 |
| **Service Worker 代理** | 请求被 SW 拦下，页面侧看不到真实地址 | 抓不到 | 不做（SW 在自己的线程里，页面上下文拿不到） | — |
| **跨域 `<iframe>` 播放器** | 点击后插入 `iframe`，`contentDocument` 访问被拒 | 已做：只上报播放器地址，面板里给候选卡，点进去在那一页继续嗅探 | 保持 | 已完成 |
| **fMP4 的 HLS 只有一段 init** | `#EXT-X-MAP` 只出现一次 | **0.4.3 已修**：init 挂在分片上，播放列表中途换 init（多段 MAP、换编码、插播）都按分片写入；`BYTERANGE` 也支持 | — | 已完成 |
| **地址由 JS 动态拼装且一次性** | 地址里带 `expire`/`sign`，过期即 403 | 已做：抓到就立刻可用；下载器会把完整 URL 存进任务 | 补：任务里记录「首次抓到的 Referer/Cookie/UA/鉴权头」，重试时沿用（鉴权头部分 0.4.4 已完成） | P1 |

## 二、抓到了但播不了

| 场景 | 判定信号 | 现状 | 方案 | 优先级 |
|---|---|---|---|---|
| **DASH（`.mpd`）** | 地址以 `.mpd` 结尾，或响应是 XML `<MPD>` | **能播**：`video_player_android` 直接依赖 `androidx.media3:media3-exoplayer-dash`，ExoPlayer 按后缀识别 MPD；**下载明确拒绝**（HLS 解析器读不懂 MPD，直接提示「可直接在线播放」） | 若要支持下载，才需要写 MPD 解析（`SegmentTemplate` 的 `$Number$`/`$Time$`）。当前不做 | 已完成（播放） |
| **DRM（Widevine / PlayReady / FairPlay）** | `#EXT-X-KEY:METHOD=SAMPLE-AES`、`mp4` 里 `pssh`、`MediaSource` + `requestMediaKeySystemAccess` | 不支持，播放时抛错 | **不做**。解密需要 license 服务器与设备证书，属于绕过版权保护。识别到就明确告诉你「受 DRM 保护」，别让用户以为是网络问题 | 已完成（识别+提示） |
| **SAMPLE-AES 加密 HLS** | `#EXT-X-KEY:METHOD=SAMPLE-AES` | 只支持 `AES-128`（CBC + PKCS7，含 IV 推导）；其它 METHOD 直接拒绝合并没有静默产出坏文件 | 保持拒绝 + 在任务卡里说明原因 | 已完成 |
| **编码不支持** | 报 `decoder init failed` / `MediaCodec` 错误 | 已做：错误文案归一化成「设备解码器不支持该编码（常见于 HEVC / AV1）」 | 可选：失败后提供「下载后转 MP4」入口（转封装不改编码，HEVC 仍解不了，需注明） | P2 |
| **直播 HLS（无 `#EXT-X-ENDLIST`）** | 播放列表没有 ENDLIST，`MEDIA-SEQUENCE` 在滚动 | 只保存当前窗口的分片，会提示「直播流仅保存当前片段」 | 增加「录制」模式：按 `TARGETDURATION` 轮询刷新播放列表，持续追加分片，停止时合并。需要前台服务保活 | P1 |
| **分片经 JS 二次解密 / 混淆** | 分片字节不是合法 TS/fMP4，页面里有 wasm 解密逻辑 | 合并后播放失败 | 不做（等于逆向站点私有协议） | — |
| **音频编码不支持（AC-3 / E-AC-3）** | 有画面没声音，或 `AudioTrack` 报错 | 部分设备不支持 | 提示「该音轨设备不支持」，并在音轨面板标出来 | P2 |
| **需要额外请求头** | 403，但浏览器里能播（带 `Authorization` / `X-Token` / 自定义 `Origin`） | **0.4.4 已做**：包装 `fetch` 读 `init.headers` / `Request.headers`，hook `XMLHttpRequest.setRequestHeader` 并在 `send` 时上报，按白名单（`Authorization`、`X-*`、`Origin`）挑头；`Cookie` 仍从 WebView 实时读（按 host 缓存 90s），`Referer` 单独传 | 播放：代理内存表只存头，URL 上带 12 位地址摘要令牌，m3u8 分片与 `#EXT-X-KEY` 沿用同一令牌；下载：头随任务持久化，回读时再过一遍白名单 | 已完成 |
| **`.ts` 直接当 `<video src>`** | 页面把 TS 当普通文件播 | 能下不能直接播 | 下载后走现有 TS→MP4 转封装 | 已完成 |

## 二之二、403 的分型：三种完全不同的原因

403 最容易被一句「需要登录」打发，但原因分三类，处理方式完全不同。
0.4.4 起，下载失败的提示会带上**被拒的路径 + Cookie 有没有带上 + 服务端原文**，
按这三项就能分流：

| 类型 | 提示特征 | 根因 | 处理 |
|---|---|---|---|
| **缺鉴权头** | 条目没有「已带鉴权头」，网页里却能播 | 站点用 `Authorization` / `X-*`，Nerelict 只带 Cookie | 已在嗅探时采集，播放与下载回放 |
| **客户端身份不一致** | 网页能播、Nerelict 403，提示里 `Cookie 已带` | 下载器的 UA 与 WebView 不一致，CDN 按 UA 判盗链 | 已统一成 WebView 的真实 UA |
| **人机验证** | 服务端原文是 `Attention Required!` / `Just a moment`，或响应头有 `cf-mitigated` | Cloudflare 一类 WAF 把请求判成自动化访问 | 单独识别并提示；403 时先让 Cookie 缓存失效再重试；master 被拦时先换 media 列表 |

判断顺序：

1. 面板条目有没有「已带鉴权头」——没有、且网页里能播，先怀疑第一类；
2. 有头仍 403、且 `Cookie 已带`，看服务端原文是不是挑战页；
3. 是挑战页就属于服务端风控，客户端只能尽量贴近浏览器（UA 一致、Cookie 最新、
   退避重试），不保证成功，也不该假装能成功。

两条实测经验：

- `playlist.m3u8`（master）比 `video.m3u8`（media）更容易被挑战，因为前者常是
  站点的入口页。面板里同时存在两者时，先下 media 那条。
- 人机验证 Cookie（`cf_clearance` 一类）轮换很快，而 CookieStore 有 90 秒缓存。
  不失效缓存的话，三次重试实际用的是同一份旧凭证，等于白试——所以 403 时先
  `invalidate` 再重试。

## 三、页面上的「广告挡住播放器 / 点播放跳广告」

这类不是嗅探问题，是交互被劫持。已做的通用处理（不认站点）：

- **透明遮挡层**：整屏 `fixed/absolute` + `z-index ≥ 20` + 覆盖 ≥45% 视口 + 背景透明度 > 0.65 + 内部没有
  `video/iframe/canvas` + 文字少于 80 字 → 判为广告层，点击时只把它 `pointer-events` 设为 `none`
  （不删节点、不改外观），**并把当次这一下点击在 document 捕获阶段掐掉**——否则这次触摸的 click
  目标在 pointerdown 时已经锁定，仍会触发广告层自己的跳转。拦完立即复位，后续点击完全不受影响
  （全脚本仅此一处 `preventDefault`，其余监听保持 passive）。再点一次就能落到真正的播放器上。
  右上角菜单另有「清理页面遮挡层」手动入口。
- **点播放弹广告窗**：点击后 1.5 秒内的 `window.open` 一律拒绝并计数（正常「点链接开新窗口」不会只隔一瞬）。
- **播放中弹窗**：应用内播放器打开时接管 `window.open`/`alert`/`confirm`/`prompt`，关闭即还原。
- **跳到广告页**：点击后 6 秒内跳到高置信广告域名，500ms 后自动回退一次；中置信只提示不劫持。

边界：这些规则都基于 DOM 特征，改版后可能失效；不透明的整屏层（真遮罩）故意不处理，
避免把「点开大图」「登录弹窗」一起干掉。

---

## 四、实施顺序建议

1. ~~P0：fMP4 init segment、`segmentGroup` 合成播放列表、POST 响应体抓地址~~ —— 0.4.3 已完成。
2. ~~P1：自定义请求头透传~~ —— 0.4.4 已完成。
3. **P1**：直播录制、DASH 下载（MPD 解析）。
4. **P2**：音轨不支持提示、下载后转码入口。
5. **永远不做**：DRM 解密、WASM 私有解密、Canvas/WebRTC 录屏。

已完成的：AES-128 解密、`#EXT-X-MAP`、`#EXT-X-BYTERANGE`、`#EXT-X-DISCONTINUITY`、
跨域 iframe 地址上报、Cookie/Referer 鉴权、**自定义请求头透传（0.4.4）**、
广告遮挡层与弹窗拦截、错误文案归一化。
