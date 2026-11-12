package com.nerelict.nerelict

import android.app.Activity
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.content.Intent
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.view.WindowManager
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
                    else -> result.notImplemented()
                }
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
