package com.nerelict.nerelict

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * 后台播放保活服务。
 *
 * 为什么需要：ExoPlayer 本身不会因为 Activity 退到后台就暂停，但进程一旦失去
 * 前台优先级，系统的后台执行限制（尤其是国产 ROM）会把它冻住甚至杀掉，表现
 * 就是「切后台就不出声、回来进度也没动」。挂一个 `mediaPlayback` 类型的前台
 * 服务，播放期间进程保持前台优先级，解码与音频在后台继续。
 *
 * 这里只管「保活 + 挂通知」：通知内容与媒体会话仍由 [PlayerPlatform] 构建，
 * 服务通过 [factory] 取当前那条通知，避免两份状态各说各话。
 */
class PlaybackService : Service() {

    companion object {
        /** 与 PlayerPlatform 共用同一个通知 ID，前台通知才能被它就地更新。 */
        const val NOTIFICATION_ID = 8801
        private const val CHANNEL_ID = "nerelict_player_media"
        private const val FALLBACK_CHANNEL_ID = "nerelict_playback_keepalive"

        /** 由 PlayerPlatform 注入：返回当前应该显示的通知。 */
        @Volatile
        private var factory: (() -> Notification?)? = null

        @Volatile
        var running = false
            private set

        /**
         * 起服务。必须在应用可见时调用（Android 12+ 禁止后台启动前台服务）。
         * 重复调用是安全的：服务已在跑时只会再走一次 onStartCommand。
         */
        fun start(context: Context, provide: (() -> Notification?)? = null) {
            if (provide != null) factory = provide
            try {
                val intent = Intent(context, PlaybackService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (_: Exception) {
                // 启动失败只影响后台保活，前台播放照常
            }
        }

        fun stop(context: Context) {
            factory = null
            running = false
            try {
                context.stopService(Intent(context, PlaybackService::class.java))
            } catch (_: Exception) {
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = factory?.invoke() ?: fallbackNotification()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            running = true
        } catch (_: Exception) {
            // 权限被拒 / 系统不允许该类型时退化成普通后台进程，不要崩
            running = false
            stopSelf()
        }
        // 不要 START_STICKY：播放器已经结束的话，系统不该再把服务拉起来
        return START_NOT_STICKY
    }

    /** 用户把任务从最近任务里划掉：播放器已经没了，服务一起收掉。 */
    override fun onTaskRemoved(rootIntent: Intent?) {
        factory = null
        running = false
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        running = false
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (_: Exception) {
        }
        super.onDestroy()
    }

    /**
     * 兜底通知：PlayerPlatform 还没来得及给通知时用。
     * `startForeground` 必须带一条通知，否则系统直接抛异常。
     */
    private fun fallbackNotification(): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (manager.getNotificationChannel(FALLBACK_CHANNEL_ID) == null) {
                val channel = NotificationChannel(
                    FALLBACK_CHANNEL_ID,
                    "后台播放",
                    NotificationManager.IMPORTANCE_LOW
                )
                channel.setSound(null, null)
                channel.description = "Nerelict 在后台继续播放时保活"
                manager.createNotificationChannel(channel)
            }
        }
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, if (manager.getNotificationChannel(CHANNEL_ID) != null) {
                CHANNEL_ID
            } else {
                FALLBACK_CHANNEL_ID
            })
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle("Nerelict 播放器")
            .setContentText("正在后台播放")
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .build()
    }
}
