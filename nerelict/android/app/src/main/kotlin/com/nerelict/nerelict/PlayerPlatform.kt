package com.nerelict.nerelict

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.MediaMetadataRetriever
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Rational
import android.view.WindowManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import kotlin.math.roundToInt

/**
 * media_session 层：把系统级播放能力以 MethodChannel 暴露给 Nerelict 播放器。
 *
 * 只包含 framework API，不新增第三方依赖；能力不支持或权限缺失时降级返回，
 * 不会影响 Flutter 侧的播放链路。
 */
class PlayerPlatform(
    private val activity: Activity,
    private val channel: MethodChannel
) {
    companion object {
        private const val CHANNEL_ID = "nerelict_player_media"
        private const val LEGACY_CHANNEL_ID = "ma8_player_media"
        private const val NOTIFICATION_ID = 8801
        private const val ACTION_MEDIA = "com.nerelict.nerelict.MEDIA_ACTION"
        private const val REQ_NOTIFICATION = 2002
    }

    private val main = Handler(Looper.getMainLooper())
    private val notificationManager =
        activity.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private val audioManager =
        activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private var mediaSession: MediaSession? = null
    private var focusRequest: AudioFocusRequest? = null
    private var receiverRegistered = false
    private var sessionEnabled = false

    /**
     * 切后台自动进画中画：只由 Flutter 侧「有播放器」时打开。
     *
     * 这个开关不代表「现在就在 PiP 里」，只是一个许可位：真正的触发在
     * `MainActivity.onUserLeaveHint`，免得和系统的首页键 / 最近任务抢事件。
     */
    private var autoPipArmed = false
    private var pipAspect = 16f / 9f

    private var lastTitle = "Nerelict 播放器"
    private var lastPlaying = false
    private var lastPositionMs = 0L
    private var lastDurationMs = 0L
    private var lastSpeed = 1f

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val action = intent?.getStringExtra("action") ?: return
            emit(action)
        }
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "ping" -> result.success(true)
                "enableMediaControls" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    setEnabled(enabled)
                    result.success(null)
                }
                "updateSession" -> {
                    lastTitle = call.argument<String>("title") ?: lastTitle
                    lastPlaying = call.argument<Boolean>("playing") ?: false
                    lastPositionMs = (call.argument<Number>("positionMs") ?: 0).toLong()
                    lastDurationMs = (call.argument<Number>("durationMs") ?: 0).toLong()
                    lastSpeed = (call.argument<Number>("speed") ?: 1).toFloat()
                    publishState()
                    result.success(null)
                }
                "clearSession" -> {
                    lastPlaying = false
                    publishState()
                    result.success(null)
                }
                "ensureNotificationPermission" -> result.success(ensureNotificationPermission())
                "requestAudioFocus" -> {
                    requestFocus()
                    result.success(null)
                }
                "abandonAudioFocus" -> {
                    abandonFocus()
                    result.success(null)
                }
                "getVolume" -> result.success(currentVolume())
                "setVolume" -> {
                    setSystemVolume((call.argument<Number>("value") ?: 0.5).toDouble())
                    result.success(null)
                }
                "getBrightness" -> result.success(currentBrightness().toDouble())
                "setBrightness" -> {
                    setBrightness((call.argument<Number>("value") ?: 0.5).toFloat())
                    result.success(null)
                }
                "setOrientation" -> {
                    setOrientation(call.argument<String>("mode") ?: "auto")
                    result.success(null)
                }
                "keepScreenOn" -> {
                    keepScreenOn(call.argument<Boolean>("enabled") ?: false)
                    result.success(null)
                }
                "pipSupported" -> result.success(pipSupported())
                "enterPip" -> {
                    val aspect = (call.argument<Number>("aspect"))?.toFloat() ?: pipAspect
                    result.success(enterPip(aspect))
                }
                "setAutoPip" -> {
                    autoPipArmed = call.argument<Boolean>("enabled") ?: false
                    val aspect = (call.argument<Number>("aspect"))?.toFloat()
                    if (aspect != null && aspect.isFinite() && aspect > 0f) {
                        pipAspect = aspect
                    }
                    result.success(null)
                }
                "captureFrame" -> captureFrame(call, result)
                "shareText" -> {
                    result.success(shareText(call.argument<String>("text") ?: ""))
                }
                "openCastSettings" -> result.success(openCastSettings())
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("PLAYER_PLATFORM", e.message ?: "原生播放能力调用失败", null)
        }
    }

    // ---- MediaSession / 通知栏 ----

    private fun setEnabled(enabled: Boolean) {
        if (enabled == sessionEnabled) return
        sessionEnabled = enabled
        if (!enabled) {
            abandonFocus()
            mediaSession?.isActive = false
            notificationManager.cancel(NOTIFICATION_ID)
            unregisterReceiver()
            return
        }
        ensureChannel()
        ensureNotificationPermission()
        if (!receiverRegistered) {
            val filter = IntentFilter(ACTION_MEDIA)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                activity.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("DEPRECATION")
                activity.registerReceiver(receiver, filter)
            }
            receiverRegistered = true
        }
        if (mediaSession == null) {
            val session = MediaSession(activity, "NerelictPlayer")
            session.setFlags(
                MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or
                    MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS
            )
            session.setCallback(object : MediaSession.Callback() {
                override fun onPlay() = emit("play")
                override fun onPause() = emit("pause")
                override fun onFastForward() = emit("forward")
                override fun onRewind() = emit("rewind")
                override fun onSkipToNext() = emit("forward")
                override fun onSkipToPrevious() = emit("rewind")
                override fun onStop() = emit("stop")
                override fun onSeekTo(pos: Long) = emit("seek", pos)
            })
            mediaSession = session
        }
        mediaSession?.isActive = true
        requestFocus()
        publishState()
    }

    private fun emit(action: String, positionMs: Long = lastPositionMs) {
        main.post {
            try {
                channel.invokeMethod(
                    "mediaAction",
                    mapOf("action" to action, "positionMs" to positionMs)
                )
            } catch (_: Exception) {
            }
        }
    }

    private fun publishState() {
        val session = mediaSession ?: return
        val state = PlaybackState.Builder()
            .setActions(
                PlaybackState.ACTION_PLAY or
                    PlaybackState.ACTION_PAUSE or
                    PlaybackState.ACTION_PLAY_PAUSE or
                    PlaybackState.ACTION_FAST_FORWARD or
                    PlaybackState.ACTION_REWIND or
                    PlaybackState.ACTION_SEEK_TO or
                    PlaybackState.ACTION_SKIP_TO_NEXT or
                    PlaybackState.ACTION_SKIP_TO_PREVIOUS
            )
            .setState(
                if (lastPlaying) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                lastPositionMs,
                lastSpeed
            )
            .build()
        session.setPlaybackState(state)
        session.setMetadata(
            MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, lastTitle)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, "Nerelict · 媒体播放")
                .putLong(MediaMetadata.METADATA_KEY_DURATION, lastDurationMs)
                .build()
        )
        try {
            notificationManager.notify(NOTIFICATION_ID, buildNotification())
        } catch (_: Exception) {
            // 无通知权限时静默降级：媒体按键仍可用
        }
    }

    private fun buildNotification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(activity, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(activity)
        }
        val open = PendingIntent.getActivity(
            activity,
            0,
            Intent(activity, activity.javaClass).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        builder.setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(lastTitle)
            .setContentText("Nerelict 播放器")
            .setContentIntent(open)
            .setOngoing(lastPlaying)
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
        mediaSession?.let {
            builder.setStyle(
                Notification.MediaStyle()
                    .setMediaSession(it.sessionToken)
                    .setShowActionsInCompactView(0, 1, 2)
            )
        }
        builder.addAction(
            Notification.Action.Builder(
                android.R.drawable.ic_media_rew,
                "后退 10 秒",
                actionIntent("rewind")
            ).build()
        )
        builder.addAction(
            Notification.Action.Builder(
                if (lastPlaying) android.R.drawable.ic_media_pause
                else android.R.drawable.ic_media_play,
                if (lastPlaying) "暂停" else "播放",
                actionIntent("toggle")
            ).build()
        )
        builder.addAction(
            Notification.Action.Builder(
                android.R.drawable.ic_media_ff,
                "前进 10 秒",
                actionIntent("forward")
            ).build()
        )
        return builder.build()
    }

    private fun actionIntent(action: String): PendingIntent {
        val intent = Intent(ACTION_MEDIA)
            .setPackage(activity.packageName)
            .putExtra("action", action)
        return PendingIntent.getBroadcast(
            activity,
            action.hashCode(),
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // 通知渠道 ID 一旦创建便常驻系统设置；换名后主动删掉旧渠道，
            // 避免残留两条同名渠道、用户之前的通知开关失效。
            notificationManager.deleteNotificationChannel(LEGACY_CHANNEL_ID)
            val existing = notificationManager.getNotificationChannel(CHANNEL_ID)
            if (existing == null) {
                val c = NotificationChannel(
                    CHANNEL_ID,
                    "Nerelict 播放器",
                    NotificationManager.IMPORTANCE_LOW
                )
                c.description = "播放控制与媒体按键"
                c.setSound(null, null)
                notificationManager.createNotificationChannel(c)
            }
        }
    }

    private fun ensureNotificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        val granted = activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        if (!granted) {
            activity.requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                REQ_NOTIFICATION
            )
        }
        return granted
    }

    // ---- 音频焦点 ----

    private fun requestFocus() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (focusRequest != null) return
            val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                        .build()
                )
                .setWillPauseWhenDucked(true)
                .build()
            focusRequest = req
            audioManager.requestAudioFocus(req)
        } else {
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus(
                null,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN
            )
        }
    }

    private fun abandonFocus() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
            focusRequest = null
        } else {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(null)
        }
    }

    // ---- 系统音量 / 亮度 / 方向 / 常亮 ----

    private fun currentVolume(): Double {
        val max = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        if (max <= 0) return 0.5
        return audioManager.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble() / max
    }

    private fun setSystemVolume(value: Double) {
        val max = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        if (max <= 0) return
        val target = (value.coerceIn(0.0, 1.0) * max).roundToInt().coerceIn(0, max)
        audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, target, 0)
    }

    private fun currentBrightness(): Float {
        val windowBrightness = activity.window?.attributes?.screenBrightness ?: -1f
        if (windowBrightness >= 0f) return windowBrightness.coerceIn(0.02f, 1f)
        val system = try {
            Settings.System.getInt(
                activity.contentResolver,
                Settings.System.SCREEN_BRIGHTNESS,
                128
            )
        } catch (_: Exception) {
            128
        }
        return (system / 255f).coerceIn(0.02f, 1f)
    }

    private fun setBrightness(value: Float) {
        val window = activity.window ?: return
        val lp = window.attributes
        lp.screenBrightness = value.coerceIn(0.02f, 1f)
        window.attributes = lp
    }

    private fun setOrientation(mode: String) {
        activity.requestedOrientation = when (mode) {
            "landscape" -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
            "portrait" -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT
            else -> ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        }
    }

    private fun keepScreenOn(enabled: Boolean) {
        val window = activity.window ?: return
        if (enabled) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    // ---- 画中画 / 投屏设置 / 截帧 / 分享 ----

    private fun pipSupported(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            activity.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    /**
     * 画中画参数。
     *
     * 系统只接受 0.418 ~ 2.39 的比例，越界 `setAspectRatio` 会抛异常；
     * 竖屏短视频也想占满窗口，所以比例按视频自身的宽高来，夹到合法区间。
     */
    private fun pipParams(aspect: Float): PictureInPictureParams? {
        if (!pipSupported()) return null
        val ratio = aspect.coerceIn(0.418f, 2.39f)
        // 用整数比表达，避免浮点比例被系统规整成奇怪的值
        val height = 1000
        val width = (height * ratio).roundToInt().coerceAtLeast(1)
        return PictureInPictureParams.Builder()
            .setAspectRatio(Rational(width, height))
            .build()
    }

    /** 有播放器、且系统支持时才接管「用户按下首页键」。 */
    fun shouldEnterPip(): Boolean = autoPipArmed && pipSupported()

    fun enterPip(aspect: Float = pipAspect): Boolean {
        val params = pipParams(aspect) ?: return false
        return try {
            activity.enterPictureInPictureMode(params)
        } catch (_: Exception) {
            false
        }
    }

    /** 把 PiP 状态回报给 Flutter：UI 据此决定只画播放画面。 */
    fun notifyPipChanged(isInPip: Boolean) {
        main.post {
            try {
                channel.invokeMethod("pipChanged", isInPip)
            } catch (_: Exception) {
            }
        }
    }

    private fun openCastSettings(): Boolean = try {
        val intent = Intent(Settings.ACTION_CAST_SETTINGS)
        if (intent.resolveActivity(activity.packageManager) == null) return false
        activity.startActivity(intent)
        true
    } catch (_: Exception) {
        false
    }

    private fun shareText(text: String): Boolean = try {
        if (text.isEmpty()) return false
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, text)
        }
        activity.startActivity(Intent.createChooser(send, "分享视频"))
        true
    } catch (_: Exception) {
        false
    }

    /** 网络流无法从纹理取帧，只有本地文件可用系统解码器截帧。 */
    private fun captureFrame(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        val posMs = (call.argument<Number>("positionMs") ?: 0).toLong()
        if (path.isNullOrEmpty()) {
            result.error("BAD_ARG", "本地文件路径为空", null)
            return
        }
        Thread {
            var bitmap: Bitmap? = null
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(path)
                bitmap = retriever.getFrameAtTime(
                    posMs * 1000L,
                    MediaMetadataRetriever.OPTION_CLOSEST
                ) ?: retriever.frameAtTime
                if (bitmap == null) throw IllegalStateException("该位置没有可解码画面")
                val dir = File(
                    activity.getExternalFilesDir(Environment.DIRECTORY_PICTURES),
                    "Nerelict"
                )
                if (!dir.exists()) dir.mkdirs()
                val out = File(dir, "Nerelict_${System.currentTimeMillis()}.jpg")
                FileOutputStream(out).use { stream ->
                    bitmap!!.compress(Bitmap.CompressFormat.JPEG, 90, stream)
                }
                main.post { result.success(out.absolutePath) }
            } catch (e: Exception) {
                main.post {
                    result.error("CAPTURE_FAILED", e.message ?: "无法截取当前画面", null)
                }
            } finally {
                try {
                    retriever.release()
                } catch (_: Exception) {
                }
                bitmap?.recycle()
            }
        }.start()
    }

    fun dispose() {
        abandonFocus()
        unregisterReceiver()
        try {
            mediaSession?.release()
        } catch (_: Exception) {
        }
        mediaSession = null
        sessionEnabled = false
        notificationManager.cancel(NOTIFICATION_ID)
    }

    private fun unregisterReceiver() {
        if (!receiverRegistered) return
        try {
            activity.unregisterReceiver(receiver)
        } catch (_: Exception) {
        }
        receiverRegistered = false
    }
}
