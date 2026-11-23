package com.nerelict.nerelict

import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.TextureView
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.TextView
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import kotlin.math.abs

/**
 * 系统悬浮窗播放器（`TYPE_APPLICATION_OVERLAY`）。
 *
 * 为什么需要另开一个播放器：Flutter 的画面走 `video_player` 的纹理，纹理只存在于
 * Activity 的窗口里，Activity 一进后台窗口就被系统收走，画面不可能画到别的应用上层。
 * 想让用户切出去还能看见小窗，只能由我们自己在 WindowManager 上加一层窗口，
 * 并让一个**原生 ExoPlayer** 直接渲染到那层窗口的 `TextureView` 上。
 *
 * 于是后台播放变成两个播放器接力：切后台 → 这里按同一地址、同一进度起播，
 * Flutter 侧暂停让位；回前台 → 这里关窗，把进度交回去。两端都指着同一个 URL
 * （本机回环代理或本地文件），解码能力与前台一致。
 */
class FloatingPlayer(
    context: Context,
    /** 点右上角 ×：关掉悬浮窗并结束整个播放会话 */
    private val onClose: () -> Unit,
    /** 点画面：回到应用（由 Activity 把任务提到前台） */
    private val onBackToApp: () -> Unit,
    /** 播放进度回报：用于刷新媒体会话进度，不影响渲染 */
    private val onTick: (positionMs: Long, durationMs: Long, playing: Boolean) -> Unit,
    /** 悬浮窗自己播不了（防盗链 / 解码失败）：交回给 Flutter 侧继续出声 */
    private val onFailed: () -> Unit,
) {
    private val appContext = context.applicationContext
    private val windowManager =
        appContext.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val handler = Handler(Looper.getMainLooper())

    /** 记住上一次拖到的位置：每次切后台都弹回角落会让人以为拖动没生效。 */
    private val prefs =
        appContext.getSharedPreferences("nerelict_floating", Context.MODE_PRIVATE)

    private var root: FrameLayout? = null
    private var video: TextureView? = null
    private var playPause: ImageButton? = null
    private var timeText: TextView? = null
    private var progressFill: View? = null
    private var params: WindowManager.LayoutParams? = null
    private var player: ExoPlayer? = null
    private var ticker: Runnable? = null

    var showing = false
        private set

    private var lastPlaying = false

    // ---- 对外 ----

    /**
     * 打开悬浮窗并起播。
     *
     * @param uriString http(s) 地址或 `file://` 本地文件
     * @param mimeType 显式 MIME（HLS / DASH 靠它选媒体源，不靠后缀猜）
     */
    fun show(
        uriString: String,
        mimeType: String?,
        headers: Map<String, String>,
        positionMs: Long,
        playing: Boolean,
        aspect: Float,
        speed: Float,
    ): Boolean {
        if (showing) return true
        if (!Settings.canDrawOverlays(appContext)) return false
        if (uriString.isEmpty()) return false
        return try {
            buildViews(aspect)
            buildPlayer(uriString, mimeType, headers)
            val p = player ?: return false
            p.seekTo(positionMs.coerceAtLeast(0L))
            if (speed > 0f) p.setPlaybackSpeed(speed)
            p.playWhenReady = playing
            lastPlaying = playing
            showing = true
            startTicker()
            true
        } catch (e: Exception) {
            hide()
            false
        }
    }

    /** 关闭悬浮窗，返回交回给 Flutter 的播放状态。 */
    fun hide(): Pair<Long, Boolean> {
        val p = player
        val pos = if (p != null) {
            try {
                maxOf(0L, p.currentPosition)
            } catch (_: Exception) {
                0L
            }
        } else {
            0L
        }
        val playing = if (p != null) {
            try {
                p.isPlaying
            } catch (_: Exception) {
                lastPlaying
            }
        } else {
            lastPlaying
        }
        ticker?.let { handler.removeCallbacks(it) }
        ticker = null
        try {
            p?.clearVideoSurface()
            p?.stop()
            p?.release()
        } catch (_: Exception) {
        }
        player = null
        root?.let {
            try {
                windowManager.removeView(it)
            } catch (_: Exception) {
            }
        }
        root = null
        video = null
        playPause = null
        timeText = null
        progressFill = null
        params = null
        showing = false
        return pos to playing
    }

    fun release() {
        hide()
    }

    fun setPlaying(playing: Boolean) {
        val p = player ?: return
        p.playWhenReady = playing
        lastPlaying = playing
        refreshButton()
    }

    fun seekBy(deltaMs: Long) {
        val p = player ?: return
        p.seekTo((p.currentPosition + deltaMs).coerceAtLeast(0L))
        refreshProgress()
    }

    fun seekTo(positionMs: Long) {
        player?.seekTo(positionMs.coerceAtLeast(0L))
        refreshProgress()
    }

    // ---- 视图 ----

    private fun dp(value: Int): Int =
        (value * appContext.resources.displayMetrics.density).toInt()

    private fun buildViews(aspect: Float) {
        val metrics = appContext.resources.displayMetrics
        // 宽度按屏幕比例取，再按视频比例算高；窄到撑不下控制条时保底 150dp
        var width = (metrics.widthPixels * 0.46f).toInt().coerceIn(dp(150), dp(300))
        val safeAspect = aspect.coerceIn(0.42f, 2.4f)
        val barHeight = dp(30)
        var videoHeight = (width / safeAspect).toInt()
        // 竖屏视频别把高度顶到屏幕上三分之一以上
        val maxVideoHeight = (metrics.heightPixels * 0.34f).toInt()
        if (videoHeight > maxVideoHeight) {
            videoHeight = maxVideoHeight
            width = (videoHeight * safeAspect).toInt().coerceAtLeast(dp(120))
        }
        val height = videoHeight + barHeight

        val frame = FrameLayout(appContext)
        frame.background = GradientDrawable().apply {
            setColor(Color.parseColor("#0B0E12"))
            cornerRadius = dp(12).toFloat()
        }
        frame.clipToOutline = true

        val texture = TextureView(appContext)
        frame.addView(
            texture,
            FrameLayout.LayoutParams(width, videoHeight).apply { gravity = Gravity.TOP }
        )
        video = texture

        // 进度条：2dp 轨道 + 自己算宽的填充，随 tick 更新
        val track = FrameLayout(appContext)
        val trackBg = View(appContext).apply {
            setBackgroundColor(Color.parseColor("#33FFFFFF"))
        }
        track.addView(trackBg, FrameLayout.LayoutParams(-1, -1))
        val fill = View(appContext).apply {
            setBackgroundColor(Color.parseColor("#4C8DFF"))
        }
        track.addView(fill, FrameLayout.LayoutParams(0, -1))
        frame.addView(
            track,
            FrameLayout.LayoutParams(width, dp(2)).apply {
                topMargin = videoHeight - dp(2)
                gravity = Gravity.TOP
            }
        )
        progressFill = fill

        val bar = LinearLayout(appContext).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(Color.parseColor("#CC0B0E12"))
            setPadding(dp(4), 0, dp(4), 0)
        }
        frame.addView(
            bar,
            FrameLayout.LayoutParams(width, barHeight).apply {
                topMargin = videoHeight
                gravity = Gravity.TOP
            }
        )

        val toggle = ImageButton(appContext).apply {
            setBackgroundColor(Color.TRANSPARENT)
            setImageResource(R.drawable.ic_float_play)
            scaleType = android.widget.ImageView.ScaleType.FIT_CENTER
            setPadding(dp(6), dp(6), dp(6), dp(6))
            contentDescription = "播放 / 暂停"
            setOnClickListener {
                val p = player ?: return@setOnClickListener
                p.playWhenReady = !p.playWhenReady
                refreshButton()
            }
        }
        bar.addView(toggle, LinearLayout.LayoutParams(dp(30), dp(30)))
        playPause = toggle

        val time = TextView(appContext).apply {
            setTextColor(Color.parseColor("#B8C2CC"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(4), 0, dp(4), 0)
            text = "--:--"
        }
        bar.addView(time, LinearLayout.LayoutParams(0, -1, 1f))
        timeText = time

        val close = ImageButton(appContext).apply {
            setBackgroundColor(Color.TRANSPARENT)
            setImageResource(R.drawable.ic_float_close)
            scaleType = android.widget.ImageView.ScaleType.FIT_CENTER
            setPadding(dp(7), dp(7), dp(7), dp(7))
            contentDescription = "关闭悬浮窗"
            setOnClickListener {
                hide()
                onClose()
            }
        }
        bar.addView(close, LinearLayout.LayoutParams(dp(30), dp(30)))

        attachDrag(frame)

        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }
        val lp = WindowManager.LayoutParams(
            width,
            height,
            type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT
        )
        lp.gravity = Gravity.TOP or Gravity.START
        // 上次拖到哪就还放哪；越界（换过机器分辨率 / 旋转过）就夹回屏幕内
        val savedX = prefs.getInt("x", Int.MIN_VALUE)
        val savedY = prefs.getInt("y", Int.MIN_VALUE)
        lp.x = if (savedX == Int.MIN_VALUE) {
            (metrics.widthPixels - width - dp(10)).coerceAtLeast(0)
        } else {
            savedX.coerceIn(0, (metrics.widthPixels - width).coerceAtLeast(0))
        }
        lp.y = if (savedY == Int.MIN_VALUE) {
            (metrics.heightPixels * 0.28f).toInt()
        } else {
            savedY.coerceIn(0, (metrics.heightPixels - height).coerceAtLeast(0))
        }
        params = lp

        root = frame
        windowManager.addView(frame, lp)
    }

    /**
     * 拖动 / 点按。
     *
     * 只挂在画面区域：控制条上的按钮要能被正常点中，抢了触摸就点不动了。
     * 没拖动就算一次点击，直接回应用——这是从其它应用回到全屏播放器最短的路径。
     */
    private fun attachDrag(frame: FrameLayout) {
        val slop = dp(6)
        var downX = 0f
        var downY = 0f
        var startX = 0
        var startY = 0
        var dragging = false
        // 只处理没被子控件吃掉的那部分触摸：控制条上的按钮是子 View，会先拿到事件
        frame.setOnTouchListener { view, event ->
            val lp = params ?: return@setOnTouchListener false
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = event.rawX
                    downY = event.rawY
                    startX = lp.x
                    startY = lp.y
                    dragging = false
                    true
                }

                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - downX
                    val dy = event.rawY - downY
                    if (!dragging && (abs(dx) > slop || abs(dy) > slop)) {
                        dragging = true
                    }
                    if (dragging) {
                        val metrics = appContext.resources.displayMetrics
                        lp.x = (startX + dx).toInt().coerceIn(-lp.width / 2, metrics.widthPixels - lp.width / 2)
                        lp.y = (startY + dy).toInt().coerceIn(0, metrics.heightPixels - lp.height)
                        try {
                            windowManager.updateViewLayout(view, lp)
                        } catch (_: Exception) {
                        }
                    }
                    true
                }

                MotionEvent.ACTION_UP -> {
                    if (!dragging) onBackToApp() else snapToEdge(lp)
                    true
                }

                MotionEvent.ACTION_CANCEL -> true
                else -> false
            }
        }
    }

    /** 松手贴边：停在屏幕中间会挡住别人，贴左右两侧更好放。 */
    private fun snapToEdge(lp: WindowManager.LayoutParams) {
        val metrics = appContext.resources.displayMetrics
        val margin = dp(10)
        val target = if (lp.x + lp.width / 2 < metrics.widthPixels / 2) {
            margin
        } else {
            metrics.widthPixels - lp.width - margin
        }
        lp.x = target
        prefs.edit().putInt("x", lp.x).putInt("y", lp.y).apply()
        root?.let {
            try {
                windowManager.updateViewLayout(it, lp)
            } catch (_: Exception) {
            }
        }
    }

    // ---- 播放 ----

    private fun buildPlayer(uriString: String, mimeType: String?, headers: Map<String, String>) {
        // 请求头与前台完全一致：Referer / UA / Cookie 由 Dart 侧给全，这里不猜不补
        val http = DefaultHttpDataSource.Factory()
            .setDefaultRequestProperties(headers)
            .setAllowCrossProtocolRedirects(true)
            .setConnectTimeoutMs(15_000)
            .setReadTimeoutMs(20_000)
        val dataSource = DefaultDataSource.Factory(appContext, http)
        val sources = DefaultMediaSourceFactory(dataSource)

        val exo = ExoPlayer.Builder(appContext, sources)
            .setHandleAudioBecomingNoisy(true)
            .build()
        exo.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                refreshButton()
                refreshProgress()
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                lastPlaying = isPlaying
                refreshButton()
            }

            override fun onPlayerError(error: PlaybackException) {
                // 悬浮窗播不了（常见是换客户端后被防盗链拦住）：关窗，把会话交回去，
                // 至少声音不断，也不至于在别人屏幕上挂一块黑
                handler.post {
                    hide()
                    onFailed()
                }
            }
        })

        val builder = MediaItem.Builder().setUri(uriString)
        if (!mimeType.isNullOrEmpty()) builder.setMimeType(mimeType)
        exo.setMediaItem(builder.build())
        video?.let { exo.setVideoTextureView(it) }
        exo.prepare()
        player = exo
    }

    private fun startTicker() {
        ticker?.let { handler.removeCallbacks(it) }
        val runnable = object : Runnable {
            override fun run() {
                if (!showing) return
                refreshProgress()
                val p = player
                if (p != null) {
                    val duration = if (p.duration > 0) p.duration else 0L
                    onTick(maxOf(0L, p.currentPosition), duration, p.isPlaying)
                }
                handler.postDelayed(this, 1_000)
            }
        }
        ticker = runnable
        handler.postDelayed(runnable, 500)
    }

    private fun refreshButton() {
        val playing = player?.playWhenReady == true
        playPause?.setImageResource(
            if (playing) R.drawable.ic_float_pause else R.drawable.ic_float_play
        )
        timeText?.let { timeText ->
            val p = player
            if (p != null) {
                timeText.text = "${format(p.currentPosition)} / ${format(p.duration)}"
            }
        }
    }

    private fun refreshProgress() {
        val p = player ?: return
        val duration = p.duration
        val fraction = if (duration > 0) {
            (p.currentPosition.toFloat() / duration).coerceIn(0f, 1f)
        } else {
            0f
        }
        val track = progressFill?.parent as? FrameLayout ?: return
        val width = track.width
        if (width <= 0) return
        val lp = progressFill?.layoutParams as? FrameLayout.LayoutParams ?: return
        lp.width = (width * fraction).toInt()
        progressFill?.layoutParams = lp
        timeText?.text = "${format(p.currentPosition)} / ${format(duration)}"
    }

    private fun format(ms: Long): String {
        if (ms <= 0) return "--:--"
        val total = ms / 1000
        val h = total / 3600
        val m = (total % 3600) / 60
        val s = total % 60
        return if (h > 0) {
            String.format("%d:%02d:%02d", h, m, s)
        } else {
            String.format("%02d:%02d", m, s)
        }
    }

    companion object {
        /** 把 MIME 交给 media3：HLS / DASH 不能靠后缀猜（地址常带查询串）。 */
        fun mimeFor(kind: String?): String? = when (kind) {
            "hls" -> MimeTypes.APPLICATION_M3U8
            "dash" -> MimeTypes.APPLICATION_MPD
            else -> null
        }

        /** 回到应用：把已有的任务提到前台，不新建实例。 */
        fun bringToFront(context: Context) {
            try {
                val intent = Intent(context, MainActivity::class.java).apply {
                    addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_SINGLE_TOP or
                            Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                    )
                }
                context.startActivity(intent)
            } catch (_: Exception) {
            }
        }
    }
}
