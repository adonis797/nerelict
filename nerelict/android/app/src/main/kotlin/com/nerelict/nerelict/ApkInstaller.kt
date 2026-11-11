package com.nerelict.nerelict

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * APK 安装：优先静默，能力不足时回退到系统安装器。
 *
 * Android 对「静默安装」有硬性限制：只有被授予 `INSTALL_PACKAGES`
 * （系统签名 / 预装到 priv-app）或拥有 root 的应用才能不弹确认框。
 * 因此这里先探测能力，再按 系统权限 → root → 系统安装器 的顺序降级，
 * 并把实际走的分支如实返回给界面展示。
 */
object ApkInstaller {

    private const val RESULT_ACTION = "com.nerelict.nerelict.INSTALL_RESULT"

    data class Capability(
        val privileged: Boolean,
        val root: Boolean,
        val canSilent: Boolean,
        val detail: String,
    )

    fun capability(context: Context): Capability {
        val privileged = context.checkSelfPermission(
            android.Manifest.permission.INSTALL_PACKAGES
        ) == PackageManager.PERMISSION_GRANTED
        val root = hasRoot()
        val detail = when {
            privileged -> "已获得系统安装权限，可静默安装"
            root -> "检测到 root，可通过 su 静默安装"
            else -> "普通应用无法静默安装：需要系统签名/预装 priv-app，或设备已 root"
        }
        return Capability(privileged, root, privileged || root, detail)
    }

    /** 探测 root 时加 3 秒超时，避免授权弹窗把线程卡死。 */
    private fun hasRoot(): Boolean {
        return try {
            val process = ProcessBuilder("sh", "-c", "su -c id")
                .redirectErrorStream(true)
                .start()
            val finished = process.waitFor(3, TimeUnit.SECONDS)
            if (!finished) {
                process.destroy()
                return false
            }
            val out = process.inputStream.bufferedReader().use { it.readText() }
            process.exitValue() == 0 && out.contains("uid=0")
        } catch (_: Exception) {
            false
        }
    }

    /**
     * 安装入口：[preferSilent] 为 true 时先尝试静默，失败再回退系统安装器。
     * 返回 map：ok / mode(system|root|privileged) / message
     */
    fun install(context: Context, path: String, preferSilent: Boolean = true): Map<String, Any> {
        val file = File(path)
        if (!file.exists() || file.length() <= 0) {
            return mapOf(
                "ok" to false,
                "mode" to "none",
                "message" to "安装包不存在或为空",
            )
        }
        val cap = capability(context)

        if (preferSilent && cap.privileged) {
            val (ok, message) = installPrivileged(context, file)
            if (ok) {
                return mapOf("ok" to true, "mode" to "privileged", "message" to "已静默安装")
            }
            // 系统权限路径失败时继续尝试 root / 系统安装器
        }
        if (preferSilent && cap.root) {
            val (ok, message) = installAsRoot(file)
            if (ok) {
                return mapOf("ok" to true, "mode" to "root", "message" to "已通过 root 静默安装")
            }
            return systemInstaller(context, file, "root 安装失败：$message")
        }
        return systemInstaller(context, file, null)
    }

    /** 静默安装（需要 INSTALL_PACKAGES）：PackageInstaller 会话，无确认框。 */
    private fun installPrivileged(context: Context, file: File): Pair<Boolean, String> {
        var receiver: BroadcastReceiver? = null
        return try {
            val installer = context.packageManager.packageInstaller
            val params = PackageInstaller.SessionParams(
                PackageInstaller.SessionParams.MODE_FULL_INSTALL
            )
            val sessionId = installer.createSession(params)
            val session = installer.openSession(sessionId)
            val input = context.contentResolver.openInputStream(Uri.fromFile(file))
            if (input == null) {
                session.close()
                return false to "无法读取安装包"
            }
            input.use { src ->
                session.openWrite("base.apk", 0, file.length()).use { out ->
                    src.copyTo(out, 64 * 1024)
                    session.fsync(out)
                }
            }

            val latch = CountDownLatch(1)
            val status = intArrayOf(PackageInstaller.STATUS_FAILURE)
            val message = arrayOf("")
            receiver = object : BroadcastReceiver() {
                override fun onReceive(ctx: Context?, intent: Intent?) {
                    status[0] = intent?.getIntExtra(
                        PackageInstaller.EXTRA_STATUS,
                        PackageInstaller.STATUS_FAILURE
                    ) ?: PackageInstaller.STATUS_FAILURE
                    message[0] = intent?.getStringExtra(
                        PackageInstaller.EXTRA_STATUS_MESSAGE
                    ) ?: ""
                    latch.countDown()
                }
            }
            context.registerReceiver(receiver, IntentFilter(RESULT_ACTION))

            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    PendingIntent.FLAG_MUTABLE
                } else {
                    0
                }
            val intent = Intent(RESULT_ACTION).setPackage(context.packageName)
            val pending = PendingIntent.getBroadcast(context, sessionId, intent, flags)
            session.commit(pending.intentSender)
            latch.await(90, TimeUnit.SECONDS)

            val ok = status[0] == PackageInstaller.STATUS_SUCCESS
            val detail = if (ok) "安装成功" else message[0]
            session.close()
            ok to detail
        } catch (e: Exception) {
            false to (e.message ?: "静默安装失败")
        } finally {
            try {
                receiver?.let { context.unregisterReceiver(it) }
            } catch (_: Exception) {
            }
        }
    }

    /** root 静默安装：pm install 属于 system 权限范畴，su 下可直接执行。 */
    private fun installAsRoot(file: File): Pair<Boolean, String> {
        return try {
            val cmd = "pm install -r -d \"${file.absolutePath}\""
            val process = ProcessBuilder("su", "-c", cmd)
                .redirectErrorStream(true)
                .start()
            val out = process.inputStream.bufferedReader().use { it.readText() }
            val finished = process.waitFor(180, TimeUnit.SECONDS)
            val ok = finished && process.exitValue() == 0 &&
                (out.contains("Success") || out.contains("成功"))
            ok to out.trim().takeLast(200)
        } catch (e: Exception) {
            false to (e.message ?: "root 执行失败")
        }
    }

    /** 回退：系统安装器（需要用户点一次「安装/允许」）。 */
    private fun systemInstaller(
        context: Context,
        file: File,
        prefix: String?,
    ): Map<String, Any> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !context.packageManager.canRequestPackageInstalls()
        ) {
            openUnknownSourcesSettings(context)
            return mapOf(
                "ok" to false,
                "mode" to "system",
                "message" to listOfNotNull(
                    prefix,
                    "已打开「安装未知应用」授权页，请允许本应用后重试",
                ).joinToString("；"),
            )
        }
        return try {
            val shared = copyToSharedCache(context, file)
            val uri = FileProvider.getUriForFile(
                context,
                "${context.packageName}.fileprovider",
                shared
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(intent)
            mapOf(
                "ok" to true,
                "mode" to "system",
                "message" to listOfNotNull(
                    prefix,
                    "已打开系统安装器，请点「安装」确认",
                ).joinToString("；"),
            )
        } catch (e: Exception) {
            mapOf(
                "ok" to false,
                "mode" to "system",
                "message" to "无法打开系统安装器：${e.message}",
            )
        }
    }

    fun openUnknownSourcesSettings(context: Context) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startActivity(
                    Intent(
                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:${context.packageName}")
                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            }
        } catch (_: Exception) {
        }
    }

    /** FileProvider 只能共享自己声明过的目录，先复制到 cache/shared。 */
    fun copyToSharedCache(context: Context, file: File): File {
        val dir = File(context.cacheDir, "shared").apply { mkdirs() }
        val dst = File(dir, file.name.ifEmpty { "update.apk" })
        file.copyTo(dst, overwrite = true)
        return dst
    }
}
