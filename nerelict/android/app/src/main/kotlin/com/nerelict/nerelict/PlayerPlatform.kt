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
import android.net.Uri
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
     * 后台播放保活开关。
     *
     * 打开后挂一个 `mediaPlayback` 前台服务：切到后台时进程仍是前台优先级，
     * ExoPlayer 的解码与音频不会被系统冻住。只负责保活，不做画中画——
     * 后台看不到画面是系统限制，但进度与声音必须继续。
     */
    private var keepAlive = false
    private var pipAspect = 16f / 9f

    /**
     * 后台悬浮窗。
     *
     * 切到后台时由 Flutter 侧交接过来：窗口用 `TYPE_APPLICATION_OVERLAY` 挂在
     * 其它应用之上，内部是独立的 ExoPlayer；回到前台再交接回去。窗口用的是
     * application context，不跟着 Activity 一起销毁。
     */
    private var floating: FloatingPlayer? = null

    private val floatingActive: Boolean
        get() = floating?.showing == true

    private var lastTitle = "Nerelict 播放器"
    private var lastPlaying = false
    private var lastPositionMs = 0L
    private var lastDurationMs = 0L
    private var lastSpeed = 1f

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val action = intent?.getStringExtra("action") ?: return
            route(action)
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
                    // 悬浮窗接管期间不接受 Flutter 侧的会话更新：那边已经暂停、
                    // 进度是冻结的，覆盖上去会让通知栏与小窗各说各话
                    if (floatingActive) {
                        result.success(null)
                        return
                    }
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
                "keepAlive" -> {
                    setKeepAlive(call.argument<Boolean>("enabled") ?: false)
                    result.success(null)
                }
                "overlaySupported" -> result.success(overlaySupported())
                "hasOverlayPermission" -> result.success(hasOverlayPermission())
                "requestOverlayPermission" -> result.success(requestOverlayPermission())
                "showFloating" -> result.success(showFloating(call))
                "hideFloating" -> {
                    val (pos, playing) = hideFloating()
                    result.success(
                        mapOf("positionMs" to pos, "playing" to playing)
                    )
                }
                "floatingActive" -> result.success(floatingActive)
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
            // 后台保活还开着时不能撤掉通知：那是前台服务的通知，
            // 撤了服务就变成「前台服务却没有通知」的非法状态。
            if (!keepAlive) notificationManager.cancel(NOTIFICATION_ID)
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
                // 悬浮窗在播时控制权在它手上：Flutter 侧已经暂停，
                // 这时候把 play 转给 Dart 只会得到一个「看起来在播、其实没声音」的会话。
                override fun onPlay() = route("play")
                override fun onPause() = route("pause")
                override fun onFastForward() = route("forward")
                override fun onRewind() = route("rewind")
                override fun onSkipToNext() = route("forward")
                override fun onSkipToPrevious() = route("rewind")
                override fun onStop() = route("stop")
                override fun onSeekTo(pos: Long) = route("seek", pos)
            })
            mediaSession = session
        }
        mediaSession?.isActive = true
        requestFocus()
        publishState()
    }

    // ---- 后台保活 ----

    /**
     * 打开 / 关闭后台播放保活。
     *
     * 只动服务、不动会话：通知内容仍由 [publishState] 更新（同一个通知 ID），
     * 服务负责把它挂上通知栏并让进程保持前台优先级，切后台后解码与音频继续。
     */
    private fun setKeepAlive(enabled: Boolean) {
        if (enabled == keepAlive) return
        keepAlive = enabled
        if (!enabled) {
            PlaybackService.stop(activity)
            return
        }
        ensureChannel()
        PlaybackService.start(activity) { buildNotification() }
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

    /**
     * 悬浮窗自己的事件（关窗 / 播放失败）。
     *
     * 不走 `mediaAction`：那条链只在用户开着「媒体通知控制」时才在 Dart 侧挂回调，
     * 悬浮窗的行为不该被这个设置影响。
     */
    private fun emitFloating(method: String) {
        main.post {
            try {
                channel.invokeMethod(method, null)
            } catch (_: Exception) {
            }
        }
    }

    /**
     * 媒体按键的去向：悬浮窗在播就直接控它，否则转给 Flutter 播放器。
     *
     * 通知栏 / 锁屏 / 蓝牙耳机都从这条链进来，两条链同时活着的话，
     * 必然有一边点了没反应——所以必须按「谁在播」分流。
     */
    private fun route(action: String, positionMs: Long = lastPositionMs) {
        val fp = floating
        if (fp != null && fp.showing) {
            when (action) {
                "play" -> fp.setPlaying(true)
                "pause" -> fp.setPlaying(false)
                "toggle" -> fp.setPlaying(!lastPlaying)
                "forward" -> fp.seekBy(10_000)
                "rewind" -> fp.seekBy(-10_000)
                "seek" -> fp.seekTo(positionMs)
                "stop" -> {
                    // 通知栏被滑掉 / 会话被停：收掉悬浮窗并结束会话
                    hideFloating()
                    main.post { emit("stop") }
                    return
                }
                else -> return
            }
            return
        }
        emit(action, positionMs)
    }

    // ---- 后台悬浮窗 ----

    private fun overlaySupported(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.M

    private fun hasOverlayPermission(): Boolean = try {
        Settings.canDrawOverlays(activity)
    } catch (_: Exception) {
        false
    }

    /**
     * 跳系统设置页开「显示在其他应用上层」。
     *
     * 这个权限只能由用户在系统设置里开，应用内弹窗代替不了；返回值是**当前**是否
     * 已授权，调用方要按 false 处理并等用户回来再复查一次。
     */
    private fun requestOverlayPermission(): Boolean {
        if (!overlaySupported()) return false
        if (hasOverlayPermission()) return true
        return try {
            val intent = Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:${activity.packageName}")
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            activity.startActivity(intent)
            false
        } catch (_: Exception) {
            // 部分 ROM 没有这一页，退到应用详情页让用户自己找
            try {
                activity.startActivity(
                    Intent(
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.parse("package:${activity.packageName}")
                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            } catch (_: Exception) {
            }
            false
        }
    }

    /**
     * 打开后台悬浮窗。
     *
     * 地址与请求头原样交给原生 ExoPlayer：与前台播放器指着同一个 URL
     * （本机回环代理或本地文件），解码结果和前台一致。
     */
    private fun showFloating(call: MethodCall): Boolean {
        if (!hasOverlayPermission()) return false
        val url = call.argument<String>("url") ?: return false
        val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
        val positionMs = (call.argument<Number>("positionMs") ?: 0).toLong()
        val playing = call.argument<Boolean>("playing") ?: true
        val aspect = (call.argument<Number>("aspect") ?: 16.0 / 9.0).toFloat()
        val speed = (call.argument<Number>("speed") ?: 1.0).toFloat()
        val kind = call.argument<String>("kind")
        call.argument<String>("title")?.let { if (it.isNotBlank()) lastTitle = it }

        val fp = floating ?: FloatingPlayer(
            context = activity.applicationContext,
            onClose = {
                // × 关窗：悬浮窗自己已经隐藏，这里只把会话结束的信号交回 Dart
                emitFloating("floatingClosed")
            },
            onBackToApp = {
                main.post { FloatingPlayer.bringToFront(activity.applicationContext) }
            },
            onTick = { pos, duration, isPlaying ->
                if (isPlaying != lastPlaying) {
                    lastPositionMs = pos
                    lastDurationMs = duration
                    lastPlaying = isPlaying
                    publishState(notify = true)
                } else {
                    lastPositionMs = pos
                    if (duration > 0) lastDurationMs = duration
                    publishState(notify = false)
                }
            },
            onFailed = {
                // 悬浮窗播不了：交回 Flutter 侧继续出声，别在别人屏幕上留一块黑
                emitFloating("floatingFailed")
            },
        ).also { floating = it }

        val ok = fp.show(
            uriString = url,
            mimeType = FloatingPlayer.mimeFor(kind),
            headers = headers,
            positionMs = positionMs,
            playing = playing,
            aspect = aspect,
            speed = speed,
        )
        return ok
    }

    private fun hideFloating(): Pair<Long, Boolean> {
        val fp = floating ?: return 0L to false
        return fp.hide()
    }

    private fun publishState(notify: Boolean = true) {
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
        // 会话已经关掉就别再发通知：关闭播放器的顺序是「关会话 → 清会话状态」，
        // 这里若再 notify 一次，通知栏会留下一条点了没反应、也滑不掉的残影。
        if (!sessionEnabled || !notify) return
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
            .setContentText(
                when {
                    lastPlaying -> "Nerelict 播放器 · 正在播放"
                    keepAlive -> "Nerelict 播放器 · 后台保活中"
                    else -> "Nerelict 播放器"
                }
            )
            .setContentIntent(open)
            // 前台服务的通知必须常驻，否则暂停一下就变成可滑掉的通知
            .setOngoing(lastPlaying || keepAlive)
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
        // 没有媒体会话时不要挂动作按钮：那几个按钮靠广播回到会话，
        // 会话没开的话点了没有任何反应，比不给按钮更糟。
        val session = mediaSession
        if (session != null && sessionEnabled) {
            builder.setStyle(
                Notification.MediaStyle()
                    .setMediaSession(session.sessionToken)
                    .setShowActionsInCompactView(0, 1, 2)
            )
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
        }
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

    /** 播放器菜单里的手动入口；不再接管首页键。 */
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
        keepAlive = false
        try {
            floating?.release()
        } catch (_: Exception) {
        }
        floating = null
        PlaybackService.stop(activity)
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
