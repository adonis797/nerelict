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
import android.util.DisplayMetrics
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
import androidx.media3.common.VideoSize
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import kotlin.math.abs
import kotlin.math.hypot

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

    private var root: View? = null
    private var stage: FloatingStageLayout? = null
    private var video: TextureView? = null
    private var playPause: ImageButton? = null
    private var timeText: TextView? = null
    private var progressFill: View? = null
    private var params: WindowManager.LayoutParams? = null
    private var player: ExoPlayer? = null
    private var ticker: Runnable? = null

    /** 双指缩放后的倍率（相对默认宽度），记在本地，下次弹窗还是这个大小。 */
    private var scale = 1f

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
        stage = null
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
        // 上次双指缩放到多大，这次还是多大
        scale = prefs.getFloat("scale", 1f).coerceIn(MIN_SCALE, MAX_SCALE)

        val metrics = appContext.resources.displayMetrics
        val barHeight = dp(30)
        val width = windowWidth(metrics)
        val height = windowHeight(width, barHeight)

        // 根用竖直排列：台面高度由宽度推出、控制条固定高，窗口被缩放后自动重排，
        // 不用重建视图也不会留下空隙
        val frame = LinearLayout(appContext).apply {
            orientation = LinearLayout.VERTICAL
            background = GradientDrawable().apply {
                setColor(Color.parseColor("#0B0E12"))
                cornerRadius = dp(12).toFloat()
            }
            clipToOutline = true
        }

        // 台面恒 16:9 横屏：竖屏视频在这里被等比缩到中间、两侧补黑边，
        // 而不是把整个小窗挤成一条细长竖条
        val stageView = FloatingStageLayout(appContext).apply {
            videoAspect = if (aspect.isFinite() && aspect > 0f) aspect else 0f
        }
        val texture = TextureView(appContext)
        stageView.addView(
            texture,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
        )
        video = texture
        stage = stageView

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
        stageView.addView(
            track,
            FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, dp(2))
        )
        progressFill = fill

        frame.addView(
            stageView,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            )
        )

        val bar = LinearLayout(appContext).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(Color.parseColor("#CC0B0E12"))
            setPadding(dp(4), 0, dp(4), 0)
        }
        frame.addView(
            bar,
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, barHeight)
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
     * 单指拖动 / 双指缩放 / 点击回应用。
     *
     * 只挂在根视图上：控制条上的按钮是子 View，会先拿到事件，抢了触摸就点不动了。
     * 单指没拖动算一次点击，直接回应用——这是从其它应用回到全屏播放器最短的路径。
     * 两指起手就切成缩放，此时不再拖动窗口，否则窗口会一边放大一边乱跑。
     */
    private fun attachDrag(frame: View) {
        val slop = dp(6)
        var downX = 0f
        var downY = 0f
        var startX = 0
        var startY = 0
        var dragging = false
        // 双指缩放：记下起手时的指间距与窗口宽度，按比值改宽高
        var pinchStartSpan = 0f
        var pinchStartWidth = 0
        var pinching = false
        var pinchDone = false

        frame.setOnTouchListener { view, event ->
            val lp = params ?: return@setOnTouchListener false
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = event.rawX
                    downY = event.rawY
                    startX = lp.x
                    startY = lp.y
                    dragging = false
                    pinching = false
                    pinchDone = false
                    true
                }

                MotionEvent.ACTION_POINTER_DOWN -> {
                    if (event.pointerCount >= 2) {
                        pinching = true
                        dragging = false
                        pinchStartSpan = span(event)
                        pinchStartWidth = lp.width
                    }
                    true
                }

                MotionEvent.ACTION_MOVE -> {
                    if (pinching && event.pointerCount >= 2) {
                        if (pinchStartSpan > 0f) {
                            val ratio = span(event) / pinchStartSpan
                            if (abs(ratio - 1f) > 0.02f) pinchDone = true
                            applyWidth((pinchStartWidth * ratio).toInt(), view, lp)
                        }
                    } else {
                        val dx = event.rawX - downX
                        val dy = event.rawY - downY
                        if (!dragging && (abs(dx) > slop || abs(dy) > slop)) {
                            dragging = true
                        }
                        if (dragging) {
                            val metrics = appContext.resources.displayMetrics
                            lp.x = (startX + dx).toInt().coerceIn(
                                -lp.width / 2,
                                metrics.widthPixels - lp.width / 2
                            )
                            lp.y = (startY + dy).toInt()
                                .coerceIn(0, metrics.heightPixels - lp.height)
                            try {
                                windowManager.updateViewLayout(view, lp)
                            } catch (_: Exception) {
                            }
                        }
                    }
                    true
                }

                // 抬起一根手指：从双指回单指。剩下那根重新起算，
                // 否则接着一划会按上一根手指的位移把窗口甩出去
                MotionEvent.ACTION_POINTER_UP -> {
                    if (event.pointerCount - 1 < 2 && pinching) {
                        pinching = false
                        rememberScale(lp)
                        val lifting = event.actionIndex
                        val remain = if (lifting == 0) 1 else 0
                        val offsetX = event.rawX - event.getX(lifting)
                        val offsetY = event.rawY - event.getY(lifting)
                        downX = event.getX(remain) + offsetX
                        downY = event.getY(remain) + offsetY
                        startX = lp.x
                        startY = lp.y
                        dragging = false
                    }
                    true
                }

                MotionEvent.ACTION_UP -> {
                    if (pinching) {
                        pinching = false
                        pinchDone = true
                        rememberScale(lp)
                    }
                    if (!pinchDone && !dragging) onBackToApp()
                    if (!pinchDone && dragging) snapToEdge(lp)
                    true
                }

                MotionEvent.ACTION_CANCEL -> {
                    pinching = false
                    true
                }
                else -> false
            }
        }
    }

    /** 两指间距；少于两指记为 0，缩放逻辑据此跳过。 */
    private fun span(event: MotionEvent): Float {
        if (event.pointerCount < 2) return 0f
        val dx = event.getX(0) - event.getX(1)
        val dy = event.getY(0) - event.getY(1)
        return hypot(dx, dy)
    }

    // ---- 尺寸 ----

    /** 默认宽度取屏幕的 46%，夹在 150~320dp：太窄放不下控制条，太宽就不像小窗了。 */
    private fun defaultWidth(metrics: DisplayMetrics): Int =
        (metrics.widthPixels * 0.46f).toInt().coerceIn(dp(150), dp(320))

    private fun minWindowWidth(): Int = dp(150)

    /** 上限：横向别糊满屏幕，竖向也要留出余量。 */
    private fun maxWindowWidth(metrics: DisplayMetrics): Int {
        val byScreen = (metrics.widthPixels * 0.92f).toInt()
        val byHeight =
            (((metrics.heightPixels * 0.8f) - dp(30)) * FloatingStageLayout.ASPECT).toInt()
        return maxOf(minWindowWidth(), minOf(byScreen, byHeight))
    }

    private fun windowWidth(metrics: DisplayMetrics): Int =
        (defaultWidth(metrics) * scale).toInt()
            .coerceIn(minWindowWidth(), maxWindowWidth(metrics))

    /** 窗口高度 = 16:9 台面 + 控制条；缩放时两者一起变，比例不变。 */
    private fun windowHeight(width: Int, barHeight: Int): Int =
        (width / FloatingStageLayout.ASPECT).toInt() + barHeight

    /**
     * 把窗口改到指定宽度并立刻生效。
     *
     * 只改窗口宽高、不碰子 View：台面按宽度自己重排画面、控制条固定高，
     * 所以缩放过程不用重建视图，也不会在中间留下黑缝。
     */
    private fun applyWidth(widthPx: Int, view: View, lp: WindowManager.LayoutParams) {
        val metrics = appContext.resources.displayMetrics
        val target = widthPx.coerceIn(minWindowWidth(), maxWindowWidth(metrics))
        if (target == lp.width) return
        lp.width = target
        lp.height = windowHeight(target, dp(30))
        // 变大之后可能顶出屏幕，顺手夹回来
        lp.x = lp.x.coerceIn(0, (metrics.widthPixels - lp.width).coerceAtLeast(0))
        lp.y = lp.y.coerceIn(0, (metrics.heightPixels - lp.height).coerceAtLeast(0))
        try {
            windowManager.updateViewLayout(view, lp)
        } catch (_: Exception) {
        }
    }

    /** 记住缩放倍率与位置：下次切后台弹窗还是这个大小，不用每次重新调。 */
    private fun rememberScale(lp: WindowManager.LayoutParams) {
        val metrics = appContext.resources.displayMetrics
        val base = defaultWidth(metrics).coerceAtLeast(1)
        scale = (lp.width.toFloat() / base).coerceIn(MIN_SCALE, MAX_SCALE)
        prefs.edit()
            .putFloat("scale", scale)
            .putInt("x", lp.x)
            .putInt("y", lp.y)
            .apply()
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

            /** 拿到真实画面比例：竖屏视频按它在 16:9 台面里居中补黑边，不拉伸变形。 */
            override fun onVideoSizeChanged(videoSize: VideoSize) {
                if (videoSize.height <= 0 || videoSize.width <= 0) return
                var width = videoSize.width.toFloat()
                var height = videoSize.height.toFloat()
                // 旋转信息还没被解码器吃进去时宽高是反的，先换回来
                if (videoSize.unappliedRotationDegrees == 90 ||
                    videoSize.unappliedRotationDegrees == 270
                ) {
                    val swap = width
                    width = height
                    height = swap
                }
                val ratio = width * videoSize.pixelWidthHeightRatio / height
                if (ratio.isFinite() && ratio > 0f) stage?.videoAspect = ratio
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
        /** 双指缩放的倍率范围：再小就点不中控制条，再大就遮掉半个屏幕。 */
        private const val MIN_SCALE = 0.5f
        private const val MAX_SCALE = 2.6f

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
