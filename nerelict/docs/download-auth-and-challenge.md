# 下载被鉴权 / 人机验证拦下：原因与方案

这份文档回答一个问题：**同一个地址，App 里能播、下载却 403（或被 Cloudflare 挑战），
到底是哪一环不对，能不能补。**

判定优先级：先确认「挑战是否已经在 WebView 里过了」，再确认「我们复用的身份是否完整」，
最后才谈「客户端的请求特征够不够像浏览器」。

---

## 一、现象与已确认的事实

真实报错（下载 `playlist.m3u8`）：

```
被站点的 Cloudflare 人机验证拦下（/66a85ca0-…/playlist.m3u8，Cookie 未取到）。
这类验证由服务端判定，下载请求比浏览更容易被打成自动化访问。
```

三条事实可以先钉住：

1. **同一个地址在 App 的 WebView 里能播** —— 说明挑战已经在该 WebView 上下文中通过，
   `cf_clearance` 之类的凭证**存在于 WebView 的 Cookie 存储里**。
2. **下载侧读到的是空 Cookie** —— 报错里的「Cookie 未取到」来自
   `CookieStore.cookiesFor()` → 原生 `CookieManager.getCookie(url)` 返回空。
3. **不是地址问题** —— 地址是刚嗅探到的、同一路径下的分片清单，没有过期迹象。

所以缺口不在「站点不给」，而在「我们复用的身份不完整」。

## 二、现在的链路

| 环节 | 代码 | 实际发出的请求头 |
|---|---|---|
| 取 Cookie | `lib/services/cookie_store.dart` → `com.nerelict/cookie` → `CookieManager.getCookie(url)` | — |
| 下载回源 | `lib/services/hls_downloader.dart` 的 `_headersFor()` | `User-Agent`、`Referer`、`Cookie`、（0.4.4 起可带页面白名单头 `Authorization` / `X-*` / `Origin`） |
| 播放代理回源 | `lib/services/streaming_proxy.dart` 的 `_applyHeaders()` | 同上 |
| ExoPlayer 直连 | `lib/services/media_source.dart` 的 `headers` | `User-Agent`、`Referer` |

0.4.4 统一 UA 之后，「能播」那一半修好了；剩下的是「能下」这一半。

## 三、两堵墙

### 3.1 第一堵：`cf_clearance` 是 HttpOnly，读不到

- Cloudflare 下发的 `cf_clearance` 带 `HttpOnly`。
- Android 的 `CookieManager.getCookie(url)` 走的是 **JS 可见的那份存储**，
  HttpOnly 的 Cookie 不会出现在返回值里（这是推断，见 §4 的判读表；本机无法联网核实文档，
  所以用一次构建把结论坐实）。
- 于是出现自相矛盾的组合：**页面能播（挑战已过），下载说「Cookie 未取到」**。
- 代码里还有一处放大效应：`CookieStore.cookiesFor()` 把 `null` 也写进缓存并保留 90 秒，
  一次失败读会被放大成一分半的「没有 Cookie」。0.4.4 在 403 时会先 `invalidate` 再重试，
  缓解了但没有根治。

### 3.2 第二堵：请求不像浏览器

即使拿到 Cookie，请求本身的特征仍然和浏览器差得远：

| 维度 | 浏览器 | 我们 |
|---|---|---|
| 请求头 | `Accept`、`Accept-Language`、`Sec-Fetch-Site/Mode/Dest` 等 | 只有 UA / Referer / Cookie |
| TLS 指纹 | Chromium 的 JA3/JA4 | `dart:io` 的 OpenSSL |
| 连接复用 | 与页面同一条连接池 | 独立连接 |

Cloudflare 的 bot score 主要吃这些信号。**TLS 指纹这一项在纯 Dart 侧改不了**，
所以第二堵墙只能减小，不能保证拆掉。

## 四、阶段一：诊断（本次实现）

目的：把「Cookie 未取到」这一句话拆成三种互斥的情况，一次复现就能定性。

采集三个信号：

| 信号 | 来源 | 说明 |
|---|---|---|
| Cookie 条数 | `CookieManager.getCookie(url)` 按 `;` 切分 | 只数个数与名字，值不落日志 |
| 页面可见 Cookie 长度 | 注入 JS 读 `document.cookie.length` | 由 `PageCookieProbe` 在页面加载完成后刷新一次 |
| 响应特征 | `cf-mitigated`、`server`、状态码 | 已有 `_isBotChallenge()`，这里把原始值也留下 |

判读表：

| CookieManager | 页面可见 | 结论 | 下一步 |
|---|---|---|---|
| 0 项 | 0 字符 | 该域确实没有 Cookie：用户没在 App 里过挑战，或分片在另一个域 | 修引导，不改代码 |
| 0 项 | > 0 字符 | **HttpOnly 被过滤** | 上阶段三（隐藏 WebView） |
| > 0 项 | — | 带了 Cookie 仍被拒 | 是特征问题，先上阶段二 |

实现位置：

- `lib/services/page_cookie_probe.dart`：一个静态探针，`browser_tab` 在页面加载完成后
  刷新一次 `document.cookie.length`，下载器**同步**读最近一次结果（不阻塞错误文案生成）。
- `lib/services/download_diagnosis.dart`：纯函数，把上面几个数字翻译成
  「Cookie 标签 + 一句建议」，主机端可断言。
- `hls_downloader.dart` 的 403 分支改用它的输出。

## 五、阶段二：补齐浏览器特征头（本次实现）

新增 `lib/services/browser_headers.dart`，给「回源媒体请求」补一组浏览器一定会带的头：

| Header | 值 | 说明 |
|---|---|---|
| `Accept` | `*/*` | 浏览器发起 XHR/fetch 取媒体时的默认值 |
| `Accept-Language` | `zh-CN,zh;q=0.9,en;q=0.8` | 固定值即可，站点只用来判「像不像人」 |
| `Sec-Fetch-Dest` | `empty` | XHR 的特征 |
| `Sec-Fetch-Mode` | `cors` | XHR 的特征 |
| `Sec-Fetch-Site` | `same-origin` / `cross-site` / `none` | 按 Referer 与目标 host 是否一致推导 |

边界与取舍：

- **不参与 UA / Referer / Cookie / Range** —— 这几项由调用方按真实会话填，本模块不覆盖。
- **不加 `sec-ch-ua` 系列**。Chromium 会带，但品牌串必须与 UA 里的 Chrome 版本一一对应，
  猜错比不带更像爬虫；`sec-ch-ua-mobile` / `-platform` 同理，单独带更奇怪。
- **不改 ExoPlayer 直连**（`MediaSource.headers`）。现在播放是通的，往这条已知可用的路径上
  加头只会引入新变量；要加也等有「播放也被挑战」的实例再说。
- 生效范围：`hls_downloader._headersFor()` 与 `streaming_proxy._applyHeaders()`，
  页面带来的白名单头仍然最后合并、优先级更高。

## 六、阶段三：隐藏 WebView 抓真实 Cookie（设计先行，等诊断结果）

只有 §4 判读表命中「0 项 / > 0 字符」时才值得做。

思路：**用系统 WebView 发一次真实请求，从 `WebViewClient.shouldInterceptRequest`
里读 `request.requestHeaders['Cookie']`** —— 这是真实出站头，包含 HttpOnly。

时序：

1. 下载器 403、且诊断为「HttpOnly」→ 调 `com.nerelict/webprobe` 的 `requestHeaders(url)`。
2. 原生在主线程 new 一个 `WebView`（不加入视图树，`getSettings().setUserAgentString(UserAgent.current)`），
   挂一个只做一件事的 `WebViewClient`。
3. `loadUrl(url)`；`shouldInterceptRequest` 命中目标 host 时：
   取 `requestHeaders`，`stopLoading()`、`destroy()`，把 header 表回传。
4. 12 秒超时或未命中 → 回传 null，下载链路按原逻辑继续（不死等）。
5. Dart 侧把 `Cookie` 值塞进内存表（不落盘、不进任务 JSON、不打日志），本次任务内复用。

前置条件与局限：

- 只在**可见 WebView 已经过挑战**之后才有意义：隐藏 WebView 与它同进程共享 CookieManager，
  会直接带上 `cf_clearance`，不会再被挑战一次。
- 隐藏 WebView 的 TLS 指纹是 Chromium 的，比 `dart:io` 更像浏览器，但**请求本身仍是我们发的**，
  所以它解决的是「拿 Cookie」，不解决「后续分片请求的指纹」。
- 资源：用完立即 `destroy()`；同一 host 的抓取结果缓存在内存，避免每次 403 都起一个 WebView。

## 七、不做

- 伪造 JA3/JA4 指纹、驱动 Turnstile/captcha、复用他人的 clearance。
- 把整段下载搬进 WebView（`fetch` + base64 回传）：指纹与 Cookie 都天然一致，但吞吐量掉到
  MB/s 级，且要重做进度、断点与合并，投入产出不成比例。作为最后手段记录在此，不实现。

## 八、验证

- `dart run tool/verify_browser_headers.dart`：头映射的纯函数断言（同源 / 跨域 / 无 Referer、
  不覆盖调用方已设的 UA/Referer/Cookie）。
- `dart run tool/verify_v35.dart`：第 34 节锁住「诊断三信号 + 头清单 + 未改 ExoPlayer」。
- 真机：在出问题的站点点下载，看提示里的三个数字，按 §4 判读表对号。

## 九、回滚

- 阶段二只影响请求头：删掉 `browser_headers.dart` 的两处 `addAll` 即回到现状，不涉及数据迁移。
- 阶段一只是文案与日志，无副作用。
- 阶段三需要原生通道，回滚时删 `com.nerelict/webprobe` 即可，Dart 侧有 `MissingPluginException` 兜底。
