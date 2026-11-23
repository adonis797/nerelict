package com.nerelict.nerelict

import android.content.Context
import android.view.View
import android.widget.FrameLayout

/**
 * 悬浮小窗的「台面」：外框恒为 16:9 横屏，画面按视频自身比例等比缩放后居中，两侧（或上下）补黑边。
 *
 * 为什么固定外框：竖屏短视频若按自身比例开窗，小窗会变成一条细长竖条，
 * 和横屏视频在同一个角落出现时尺寸来回跳，看着像渲染出错。统一成同一个横屏形状后，
 * 变化的只有画面内容，窗口本身稳定；双指放大缩小时也只是整体等比变化。
 *
 * 内部不用布局参数摆孩子：画面与进度条的位置全部在 [onLayout] 里按当前尺寸现算，
 * 所以窗口被缩放后只需要改窗口宽高，画面会自动重新等比适配，不用每次都重建视图。
 */
class FloatingStageLayout(context: Context) : FrameLayout(context) {

    /** 视频真实比例（宽 / 高）。<= 0 表示还没拿到，先按外框比例铺满。 */
    var videoAspect = 0f
        set(value) {
            if (field != value) {
                field = value
                requestLayout()
            }
        }

    /** 第 0 个孩子是画面，第 1 个是贴在画面底部的进度条。 */
    private val surface: View?
        get() = if (childCount > 0) getChildAt(0) else null

    private val overlay: View?
        get() = if (childCount > 1) getChildAt(1) else null

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = MeasureSpec.getSize(widthMeasureSpec)
        val height = (width / ASPECT).toInt()
        super.onMeasure(
            MeasureSpec.makeMeasureSpec(width, MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec(height, MeasureSpec.EXACTLY),
        )
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        val boxWidth = right - left
        val boxHeight = bottom - top
        if (boxWidth <= 0 || boxHeight <= 0) return

        // 等比缩放：先按宽度铺满，撑高了再退回按高度铺满——两种情况下都不裁切
        val aspect = if (videoAspect > 0f) videoAspect else ASPECT
        var videoWidth = boxWidth
        var videoHeight = (boxWidth / aspect).toInt()
        if (videoHeight > boxHeight) {
            videoHeight = boxHeight
            videoWidth = (boxHeight * aspect).toInt()
        }
        val videoLeft = (boxWidth - videoWidth) / 2
        val videoTop = (boxHeight - videoHeight) / 2
        surface?.layout(videoLeft, videoTop, videoLeft + videoWidth, videoTop + videoHeight)

        // 进度条贴着画面下沿，而不是整个台面下沿：竖屏两侧有黑边时不会横跨黑边
        overlay?.let {
            val height = it.measuredHeight.coerceAtLeast(0)
            it.layout(
                videoLeft,
                videoTop + videoHeight - height,
                videoLeft + videoWidth,
                videoTop + videoHeight,
            )
        }
    }

    companion object {
        /** 台面比例，固定横屏；窗口高度与画面适配都以它为准。 */
        const val ASPECT = 16f / 9f
    }
}
