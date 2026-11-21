# 下载被鉴权 / 人机验证拦下：结论与复盘

这份文档回答一个问题：**同一个地址，App 里能播、下载却 403（或被 Cloudflare 挑战），
到底是哪一环不对。**

结论写在最前面，因为它是用六轮真机复现换来的，前面几轮都走错了方向：

> **不是请求头的问题，是“谁在发这个请求”。**
>
> 站点按 **TLS / HTTP 栈** 识别客户端：ExoPlayer 直连（Android 自己的网络栈）能过，
> Dart 的 `dart:io`（下载器、播放代理）发一模一样的头也会被拒。

---

## 一、证据链

| 观察 | 排除了什么 |
|---|---|
| 浮层播放器能播，提示里却写着「Cookie 未取到（9 项）」 | 不是“没读到 Cookie”，也不是“没登录” |
| 换 `video.m3u8` 一样被拦 | 不是入口页规则更严，是凭证/客户端层面 |
| 提示细化成「缺 `cf_clearance`」，代取后仍是「没拿到」 | 代取链路有问题（当时以为） |
| 关掉「边下边播缓存」能播，开启后播不了 | **关键一击**：缓存开关正是 HLS 是否走 Dart 代理的开关 |
| 日志 `domainCookies=1` 但 `withCookie=0` | 该域其实有 Cookie，是**API 不给看** |

最后两条把结论钉死了。

### 为什么「开缓存就播不了」

`lib/ui/player_page.dart`：

```dart
if (settings.playerStreamingCache && source.kind == MediaKind.hls) {
  playbackUrl = await StreamingProxy.instance.playbackUrl(source);  // 走 dart:io
}
```

- 关缓存 → ExoPlayer 直连（Android 栈）→ 能播；
- 开缓存 → `StreamingProxy` 用 `dart:io` 取流 → 403 → 播不了。

同一个地址、同一套头，换一个客户端就不一样——说明被识别的是**发送方**。

## 二、三个被证伪的假设

| 假设 | 实际上 |
|---|---|
| `cf_clearance` 是 HttpOnly，`CookieManager.getCookie()` 读不到 | 前半句对，但**这不是卡点**。该域确实有 Cookie，读得到 1 份；卡住的是我们拿不到“真实出站头” |
| 从 `shouldInterceptRequest` 的 `requestHeaders` 里取 `Cookie` | **Android 不把 Cookie 放进 `requestHeaders`**（安全设计，cookie 在网络栈注入）。这条从根上不成立，写了三版代取都在追一个拿不到的东西 |
| 补齐 `Accept` / `Accept-Language` / `Sec-Fetch-*` 就更像浏览器 | 对通过没有任何帮助；更糟的是把它加到**播放代理**上，反而把本来能播的 HLS 打回 403（0.4.6 → 0.4.8 的回归） |

还有一条纯技术的坑：`evaluateJavascript` 对 Promise 只回 `{}`，
所以前几版“页面内 fetch 返回了什么”的诊断从未生效——**一直以为在测，其实没测到**。

## 三、最终实现

### 3.1 下载：换客户端，不换头

新增原生通道 `com.nerelict/nativehttp`，用 `HttpURLConnection`（与 ExoPlayer 同层 TLS）
取清单与分片。调用顺序：

```
Dio（现状）
  └─ 失败 → 原生 HttpURLConnection（同 ExoPlayer 那层）
       └─ 失败 → dart:io HttpClient（与播放代理同款）
```

只发 `User-Agent` + `Referer`，**不补任何头**。分片带 `Range`。

### 3.2 播放：代理失败自动直连

`player_page` 在代理取流失败时，自动改直连重试一次，并把该 host 记进
`_proxyBlockedHosts`——下次这个站直接直连，不再白失败一次。

这样“开缓存”不会再等于“这个站播不了”。

### 3.3 诊断保留

`download_diagnosis.dart` 仍然有用：它现在能区分「该域没 Cookie」「跨域」「带了 Cookie
仍被拒」「代取过但没取到（原因）」。虽然最终解法不是调头，但**它把“该改哪里”问清楚了**——
没有它，就不会发现“该域其实有 1 份 Cookie”这个反证。

## 四、边界与不做

- **不再为“像浏览器”补头**：`browser_headers.dart` 只保留给下载器，且随时可以整体删掉。
- **不做**：伪造 JA3/JA4、驱动 Turnstile/captcha、复用他人的 clearance。
- **不做**：把整段下载搬进 WebView（`fetch` + base64 回传）。指纹天然一致，但吞吐掉到 MB/s 级，
  且要重做进度、断点与合并。
- **代理不是万能**：它对“需要 Referer / Cookie 才能播”的站点仍然必要，只是对“按栈识别”的站点
  必须让位给直连。

## 五、验证

- `dart run tool/verify_v35.dart`：第 34、38 节锁住诊断分支、原生通道两端一致、
  「先原生后 dart:io」的顺序、代理失败自动直连。
- `dart run tool/verify_browser_headers.dart`：头映射与诊断文案的纯函数断言。
- 真机：出问题的站点直链与 HLS 均能下载；开缓存后 HLS 仍可播。

## 六、方法论

这轮最贵的教训不是技术细节，是排查顺序：

1. **先找出“有没有一条已知能通的请求”，并确认它到底走了哪条代码路径。**
   我一直假设“播放走代理是通的”，这个前提从未被验证；实际是关缓存才走直连。
2. **诊断要能自证生效。** 写了三版日志都没出现，本身就是信号——先修“测量工具”，再改被测对象。
3. **不要拿可用功能做实验。** 为了让下载更像浏览器而给播放代理加头，直接造成了一次播放回归。
4. **API 的行为要落到实测。** “`shouldInterceptRequest` 能拿到 Cookie 头”是查文档也不一定写清的事，
   一次 `domainCookies` 计数就拆穿了。
