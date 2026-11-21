package com.nerelict.nerelict

import android.app.Activity
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.content.Intent
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.Settings
import android.provider.OpenableColumns
import android.util.Log
import android.view.ViewGroup
import android.view.WindowManager
import android.webkit.CookieManager
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    companion object {
        private const val MP4_CHANNEL = "com.nerelict/mp4"
        private const val STORAGE_CHANNEL = "com.nerelict/storage"
        private const val PLAYER_CHANNEL = "com.nerelict/player"
        private const val SCREEN_CHANNEL = "com.nerelict/screen"
        private const val INSTALL_CHANNEL = "com.nerelict/install"
        private const val NETWORK_CHANNEL = "com.nerelict/network"
        private const val COOKIE_CHANNEL = "com.nerelict/cookie"
        private const val EXTERNAL_CHANNEL = "com.nerelict/external"
        private const val MEDIA_CHANNEL = "com.nerelict/media"
        private const val WEBPROBE_CHANNEL = "com.nerelict/webprobe"
        private const val REQ_PICK_DIR = 1001
        private const val REQ_PICK_APK = 1002
    }

    private var pendingDirResult: MethodChannel.Result? = null
    private var pendingApkResult: MethodChannel.Result? = null
    private var playerPlatform: PlayerPlatform? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        configureMp4Channel(flutterEngine)
        configureStorageChannel(flutterEngine)
        configurePlayerChannel(flutterEngine)
        configureScreenChannel(flutterEngine)
        configureInstallChannel(flutterEngine)
        configureNetworkChannel(flutterEngine)
        configureCookieChannel(flutterEngine)
        configureExternalChannel(flutterEngine)
        configureMediaChannel(flutterEngine)
        configureWebProbeChannel(flutterEngine)
    }

    /**
     * 把 WebView 里的 Cookie 交给 Dart 侧的下载器与播放代理。
     *
     * 下载器此前只发 Referer / UA，需要登录态的分片会被 CDN 判 403，
     * 而同一地址在 WebView 里能播——差别就是浏览器自己带了 Cookie。
     * 这里只做读取，不写入、不持久化；凭证由 Dart 侧存内存，用完即弃。
     */
    private fun configureCookieChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, COOKIE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "get" -> {
                        val url = call.argument<String>("url")
                        if (url.isNullOrEmpty()) {
                            result.success(null)
                            return@setMethodCallHandler
                        }
                        // CookieManager 只能在主线程访问
                        runOnUiThread {
                            try {
                                val manager = CookieManager.getInstance()
                                manager.setAcceptCookie(true)
                                result.success(manager.getCookie(url))
                            } catch (_: Exception) {
                                // 取不到就按匿名请求继续，不阻断下载
                                result.success(null)
                            }
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 自定义 scheme 深链：微信 / QQ / 支付宝 / 运营商一键登录。
     *
     * WebView 自己开不了这些地址，拦下来用户就只会看到「点登录没反应」，
     * 所以交给系统去起对应应用；没有可用应用时返回 false，由 Dart 侧给提示。
     */
    private fun configureExternalChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, EXTERNAL_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "open" -> {
                        val url = call.argument<String>("url")
                        if (url.isNullOrEmpty() || !url.contains("://")) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        try {
                            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(true)
                        } catch (_: Exception) {
                            // 没有能处理该 scheme 的应用（ActivityNotFoundException）
                            result.success(false)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 用 WebView 上下文代取请求头。
     *
     * 为什么需要：Cloudflare 的 `cf_clearance` 带 HttpOnly，`CookieManager.getCookie()`
     * 走的是 JS 可见的那份存储，读不到；而 `shouldInterceptRequest` 拿到的是**真实出站头**，
     * 包含 HttpOnly。这里只抓「某个地址这一次请求的头」，抓完立即销毁 WebView，
     * 不加载页面、不执行页面脚本、不保存任何 Cookie 值。
     */
    private fun configureWebProbeChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WEBPROBE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "captureHeaders" -> {
                        val url = call.argument<String>("url")
                        val ua = call.argument<String>("userAgent")
                        if (url.isNullOrEmpty()) {
                            result.success(null)
                            return@setMethodCallHandler
                        }
                        runOnUiThread { captureHeadersViaWebView(url, ua, result) }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    private fun captureHeadersViaWebView(
        url: String,
        ua: String?,
        result: MethodChannel.Result,
    ) {
        var finished = false
        var webView: WebView? = null
        var seenRequests = 0
        var sawCookie = false
        var fetched = false

        fun log(msg: String) {
            Log.d("NerelictProbe", msg)
        }

        fun finish(payload: Map<String, String>?) {
            if (finished) return
            finished = true
            log("finish requests=$seenRequests cookie=$sawCookie payload=${payload != null}")
            try {
                webView?.let { wv ->
                    wv.stopLoading()
                    (wv.parent as? ViewGroup)?.removeView(wv)
                    wv.destroy()
                }
            } catch (_: Exception) {
            }
            webView = null
            result.success(payload)
        }

        fun startFetch(wv: WebView) {
            if (fetched) return
            fetched = true
            // 主框架导航拿不到完整请求头（Cookie 常被略去），
            // 用页面内 fetch 触发一次**子资源**请求，那里才有 Cookie。
            val quoted = org.json.JSONObject.quote(url)
            val js = "fetch($quoted,{credentials:'include',cache:'no-store'})" +
                ".then(function(r){return r.text()})" +
                ".then(function(t){return 'ok:'+t.length})" +
                ".catch(function(e){return 'err:'+e})"
            log("startFetch $url")
            wv.evaluateJavascript(js) { value -> log("fetchResult=$value") }
        }

        try {
            val target = Uri.parse(url)
            val host = target.host ?: ""
            val originRoot = "${target.scheme}://$host/"
            val wv = WebView(this)
            webView = wv
            wv.settings.javaScriptEnabled = true
            // 不要图片：我们要的是请求头，不是页面内容
            wv.settings.blockNetworkImage = true
            wv.settings.cacheMode = WebSettings.LOAD_NO_CACHE
            if (!ua.isNullOrEmpty()) wv.settings.userAgentString = ua
            wv.webViewClient = object : WebViewClient() {
                override fun shouldInterceptRequest(
                    view: WebView?,
                    request: WebResourceRequest?,
                ): WebResourceResponse? {
                    val req = request ?: return null
                    val reqUrl = req.url ?: return null
                    // 只认目标主机：跳转到登录页之类的不参与
                    if (host.isNotEmpty() && reqUrl.host != host) return null
                    seenRequests++
                    val headers = req.requestHeaders ?: emptyMap()
                    val cookieKey = headers.keys.firstOrNull {
                        it.equals("Cookie", ignoreCase = true)
                    }
                    log("req #$seenRequests ${reqUrl.path} headers=${headers.size} cookie=${cookieKey != null}")
                    if (cookieKey != null) {
                        sawCookie = true
                        val payload = HashMap(headers)
                        payload["__probeRequests"] = seenRequests.toString()
                        finish(payload)
                        return null
                    }
                    return null
                }

                override fun onPageFinished(view: WebView?, pageUrl: String?) {
                    super.onPageFinished(view, pageUrl)
                    log("onPageFinished $pageUrl")
                    if (view != null) startFetch(view)
                }
            }
            // 必须挂到窗口里才会真正发请求：1x1、不可见、不占布局
            val root = findViewById<ViewGroup>(android.R.id.content)
            root.addView(wv, ViewGroup.LayoutParams(1, 1))
            log("load $originRoot")
            wv.loadUrl(originRoot)
            // 根页若是挑战页、脚本跑不起来，退一步直接加载目标地址再试
            Handler(Looper.getMainLooper()).postDelayed({
                if (!finished && !sawCookie) {
                    log("fallback load target")
                    webView?.loadUrl(url)
                }
            }, 5_000)
            Handler(Looper.getMainLooper()).postDelayed({ finish(null) }, 12_000)
        } catch (_: Exception) {
            finish(null)
        }
    }

    /**
     * 本地媒体元数据：时长与分辨率。
     *
     * 只读元信息、不解码整段（`MediaMetadataRetriever` 内部按需解析头部），
     * 失败一律回 null，由 Dart 侧标成「读不出元数据」而不是时长 0。
     */
    private fun configureMediaChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MEDIA_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "probe" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrEmpty() || !File(path).exists()) {
                            result.success(null)
                            return@setMethodCallHandler
                        }
                        // 元数据读取是阻塞操作，放到工作线程，避免卡住主线程
                        Thread {
                            var retriever: MediaMetadataRetriever? = null
                            try {
                                retriever = MediaMetadataRetriever()
                                retriever.setDataSource(path)
                                val duration = retriever
                                    .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                                    ?.toLongOrNull() ?: 0L
                                val width = retriever
                                    .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                                    ?.toIntOrNull() ?: 0
                                val height = retriever
                                    .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                                    ?.toIntOrNull() ?: 0
                                val payload = mapOf(
                                    "durationMs" to duration,
                                    "width" to width,
                                    "height" to height,
                                )
                                runOnUiThread { result.success(payload) }
                            } catch (_: Exception) {
                                runOnUiThread { result.success(null) }
                            } finally {
                                try {
                                    retriever?.release()
                                } catch (_: Exception) {
                                }
                            }
                        }.start()
                    }

                    else -> result.notImplemented()
                }
            }
    }

    /** Nerelict 播放器：通知栏媒体控制、音频焦点、亮度、PIP、截帧、分享。 */
    private fun configurePlayerChannel(flutterEngine: FlutterEngine) {
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PLAYER_CHANNEL)
        val platform = PlayerPlatform(this, channel)
        playerPlatform = platform
        channel.setMethodCallHandler { call, result -> platform.handle(call, result) }
    }

    override fun onDestroy() {
        playerPlatform?.dispose()
        playerPlatform = null
        super.onDestroy()
    }

    /**
     * 屏幕常亮：FLAG_KEEP_SCREEN_ON 只在窗口可见时生效，
     * 不需要 WAKE_LOCK 权限，也不会阻止用户按电源键锁屏。
     */
    private fun configureScreenChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SCREEN_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setKeepAwake" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: true
                        runOnUiThread {
                            if (enabled) {
                                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            } else {
                                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            }
                        }
                        result.success(true)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    /**
     * APK 安装：能力探测 / 静默安装 / 选择安装包安装 / 未知来源授权页。
     * 静默安装需要系统权限或 root，能力不足时自动回退系统安装器。
     */
    /** 网络类型：仅 Wi-Fi 下载门控用，不读 SSID */
    private fun configureNetworkChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NETWORK_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isWifi" -> result.success(isWifi())
                    else -> result.notImplemented()
                }
            }
    }

    private fun isWifi(): Boolean {
        return try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                ?: return false
            val network = cm.activeNetwork ?: return false
            val caps = cm.getNetworkCapabilities(network) ?: return false
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
        } catch (_: Exception) {
            false
        }
    }

    private fun configureInstallChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, INSTALL_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "capability" -> Thread {
                        val cap = ApkInstaller.capability(this)
                        post {
                            result.success(
                                mapOf(
                                    "privileged" to cap.privileged,
                                    "root" to cap.root,
                                    "canSilent" to cap.canSilent,
                                    "detail" to cap.detail
                                )
                            )
                        }
                    }.start()

                    "install" -> {
                        val path = call.argument<String>("path")
                        val silent = call.argument<Boolean>("silent") ?: true
                        if (path.isNullOrEmpty()) {
                            result.error("BAD_ARG", "安装包路径为空", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            val res = ApkInstaller.install(this, path, silent)
                            post { result.success(res) }
                        }.start()
                    }

                    "pickAndInstall" -> pickApk(result)

                    "openUnknownSources" -> {
                        ApkInstaller.openUnknownSourcesSettings(this)
                        result.success(true)
                    }

                    "appVersion" -> result.success(
                        mapOf(
                            "versionName" to (packageManager
                                .getPackageInfo(packageName, 0).versionName ?: ""),
                            "versionCode" to (if (android.os.Build.VERSION.SDK_INT >= 28) {
                                packageManager.getPackageInfo(packageName, 0).longVersionCode
                            } else {
                                @Suppress("DEPRECATION")
                                packageManager.getPackageInfo(packageName, 0).versionCode.toLong()
                            })
                        )
                    )

                    else -> result.notImplemented()
                }
            }
    }

    private fun pickApk(result: MethodChannel.Result) {
        if (pendingApkResult != null) {
            result.error("BUSY", "已有安装请求在处理", null)
            return
        }
        pendingApkResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/vnd.android.package-archive"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            startActivityForResult(intent, REQ_PICK_APK)
        } catch (e: Exception) {
            pendingApkResult = null
            result.error("NO_PICKER", e.message ?: "无法打开文件选择器", null)
        }
    }

    private fun handlePickApk(resultCode: Int, data: Intent?) {
        val pending = pendingApkResult ?: return
        pendingApkResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pending.success(mapOf("ok" to false, "mode" to "none", "message" to "已取消"))
            return
        }
        Thread {
            try {
                val name = queryDisplayName(uri) ?: "selected.apk"
                val dir = File(cacheDir, "apk_install").apply { mkdirs() }
                val target = File(dir, "${System.currentTimeMillis()}_$name")
                contentResolver.openInputStream(uri)?.use { input ->
                    target.outputStream().use { out -> input.copyTo(out, 64 * 1024) }
                } ?: throw IllegalStateException("无法读取所选文件")
                // 这个入口只用于安装本应用的更新包，别的 APK 直接拒绝
                val archive = packageManager.getPackageArchiveInfo(target.absolutePath, 0)
                val apkPackage = archive?.packageName
                if (apkPackage != packageName) {
                    target.delete()
                    post {
                        pending.success(
                            mapOf(
                                "ok" to false,
                                "mode" to "none",
                                "message" to "所选安装包不是本应用（${apkPackage ?: "无法识别"}）"
                            )
                        )
                    }
                    return@Thread
                }
                val res = ApkInstaller.install(this, target.absolutePath, true)
                // 系统安装器分支已把文件复制到 cache/shared，这里可以安全清理
                target.delete()
                post { pending.success(res) }
            } catch (e: Exception) {
                post {
                    pending.success(
                        mapOf(
                            "ok" to false,
                            "mode" to "none",
                            "message" to (e.message ?: "读取安装包失败")
                        )
                    )
                }
            }
        }.start()
    }

    private fun queryDisplayName(uri: Uri): String? = try {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }
    } catch (_: Exception) {
        null
    }

    private fun configureMp4Channel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MP4_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "convert" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrEmpty()) {
                            result.error("BAD_ARG", "源文件路径为空", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val out = Mp4Converter.convert(path)
                                post { result.success(out) }
                            } catch (e: Exception) {
                                post {
                                    result.error(
                                        "CONVERT_FAILED",
                                        e.message ?: "转换失败",
                                        null
                                    )
                                }
                            }
                        }.start()
                    }

                    // 用系统解码器读一下产物，用于确认生成的 mp4 确实可解析
                    "info" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrEmpty()) {
                            result.error("BAD_ARG", "路径为空", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            val retriever = MediaMetadataRetriever()
                            try {
                                retriever.setDataSource(path)
                                val duration = retriever
                                    .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                                    ?.toLongOrNull() ?: 0L
                                val width = retriever
                                    .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                                    ?.toIntOrNull() ?: 0
                                val height = retriever
                                    .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                                    ?.toIntOrNull() ?: 0
                                val hasAudio = retriever
                                    .extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO) == "yes"
                                val frame: Bitmap? = retriever.frameAtTime
                                post {
                                    result.success(
                                        mapOf(
                                            "durationMs" to duration,
                                            "width" to width,
                                            "height" to height,
                                            "hasFrame" to (frame != null),
                                            "hasAudio" to hasAudio
                                        )
                                    )
                                    frame?.recycle()
                                }
                            } catch (e: Exception) {
                                post { result.error("INFO_FAILED", e.message ?: "无法解析", null) }
                            } finally {
                                try {
                                    retriever.release()
                                } catch (_: Exception) {
                                }
                            }
                        }.start()
                    }

                    else -> result.notImplemented()
                }
            }
    }

    /** 用户自选下载位置：系统目录选择器 + 成品导出（SAF，无需存储权限）。 */
    private fun configureStorageChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, STORAGE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickDirectory" -> pickDirectory(result)
                    "exportFile" -> exportFile(call, result)
                    "allFilesAccess" -> result.success(hasAllFilesAccess())
                    "openAllFilesSettings" -> result.success(openAllFilesSettings())
                    "externalRoot" -> result.success(
                        Environment.getExternalStorageDirectory()?.absolutePath
                    )
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 「所有文件访问权限」是否已授予。
     *
     * Android 11+ 用 `Environment.isExternalStorageManager()` 判断；
     * 低版本没有这个限制，恒为 true。
     */
    private fun hasAllFilesAccess(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                Environment.isExternalStorageManager()
            } catch (_: Exception) {
                false
            }
        } else {
            true
        }

    /**
     * 跳到系统的「所有文件访问权限」开关。
     *
     * 先试应用自己的那一页，部分国产 ROM 没有实现，退回通用列表页；
     * 都打不开就返回 false，由 Dart 侧提示手动去找。
     */
    private fun openAllFilesSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return true
        val direct = Intent(
            Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
            Uri.parse("package:$packageName")
        )
        try {
            startActivity(direct)
            return true
        } catch (_: Exception) {
        }
        return try {
            startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun pickDirectory(result: MethodChannel.Result) {
        if (pendingDirResult != null) {
            result.error("BUSY", "已有目录选择请求", null)
            return
        }
        pendingDirResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
            )
        }
        try {
            startActivityForResult(intent, REQ_PICK_DIR)
        } catch (e: Exception) {
            pendingDirResult = null
            result.error("NO_PICKER", e.message ?: "无法打开目录选择器", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            REQ_PICK_DIR -> handlePickDirectory(resultCode, data)
            REQ_PICK_APK -> handlePickApk(resultCode, data)
        }
    }

    private fun handlePickDirectory(resultCode: Int, data: Intent?) {
        val pending = pendingDirResult ?: return
        pendingDirResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pending.success(null)
            return
        }
        try {
            try {
                contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                )
            } catch (_: Exception) {
                // 部分系统不授予持久权限，仍尝试当次使用
            }
            val name = runCatching {
                val id = DocumentsContract.getTreeDocumentId(uri)
                id.substringAfterLast(':').substringAfterLast('/').ifEmpty { "已选目录" }
            }.getOrDefault("已选目录")
            pending.success(mapOf("uri" to uri.toString(), "name" to name))
        } catch (e: Exception) {
            pending.error("PICK_FAILED", e.message ?: "目录授权失败", null)
        }
    }

    private fun exportFile(call: MethodCall, result: MethodChannel.Result) {
        val uriStr = call.argument<String>("uri")
        val path = call.argument<String>("path")
        val name = call.argument<String>("name")
        if (uriStr.isNullOrEmpty() || path.isNullOrEmpty() || name.isNullOrEmpty()) {
            result.error("BAD_ARG", "参数不完整", null)
            return
        }
        Thread {
            try {
                val treeUri = Uri.parse(uriStr)
                val treeId = DocumentsContract.getTreeDocumentId(treeUri)
                val parent = DocumentsContract.buildDocumentUriUsingTree(treeUri, treeId)
                val mime = if (name.endsWith(".mp4", true)) "video/mp4" else "video/mp2t"
                val target = DocumentsContract.createDocument(
                    contentResolver, parent, mime, name
                ) ?: throw IllegalStateException("无法在所选目录创建文件")
                contentResolver.openOutputStream(target, "w")?.use { out ->
                    File(path).inputStream().use { src -> src.copyTo(out) }
                } ?: throw IllegalStateException("无法写入所选目录")
                post { result.success(true) }
            } catch (_: Exception) {
                post { result.success(false) }
            }
        }.start()
    }

    private fun post(block: () -> Unit) {
        Handler(Looper.getMainLooper()).post(block)
    }
}
