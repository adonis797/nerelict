package com.nerelict.nerelict

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.util.Log
import java.io.File
import java.nio.ByteBuffer

/**
 * TS -> MP4 无重编码转封装（MediaExtractor + MediaMuxer）。
 *
 * 只搬运已编码的 H.264 / HEVC + AAC 样本，不重新编码，速度快、不损失画质。
 * 针对 HLS（m3u8 分片合并出来的 TS）常见的「转出来打不开 / 播放卡顿」做了五件事：
 *  1. 时间轴重建：先试读一段样本判断该轨是否带 B 帧。带 B 帧时解码顺序的 PTS 会周期性回退，
 *     MediaMuxer 实测并不能保住这种回退（它会把时间戳顶成「上一帧 + 最小间隔」，
 *     产物里 46% 的相邻帧显示时长为 0，剩下的帧间隔翻倍，播放就是掉帧、卡顿）。
 *     所以这里按解码顺序重建等间隔网格：帧间隔取源的中位帧间隔，
 *     帧序仍是正确的解码顺序，时间轴均匀，播放才平滑。
 *  2. AAC 的 csd-0 若是 ADTS 头，转换为 AudioSpecificConfig 再交给 MP4 封装，
 *     否则写出的 esds 非法，播放器无法创建音频解码器；
 *  3. 视频从第一个关键帧开始写，避免开头缺参考帧导致黑屏 / 花屏；
 *  4. 产物用系统解码器校验（时长 + 首帧），再抽查时间轴是否塌陷，
 *     不合格直接判失败并删掉产物，不留下「能打开但卡」的坏文件；
 *  5. 分片缺段 / 广告插播造成的 PTS 大跳会被计入网格缺口，避免整段被压缩后音画错位。
 */
object Mp4Converter {

    private const val TAG = "Mp4Converter"
    private const val AAC = MediaFormat.MIMETYPE_AUDIO_AAC
    private const val VIDEO_AVC = MediaFormat.MIMETYPE_VIDEO_AVC
    private const val VIDEO_HEVC = MediaFormat.MIMETYPE_VIDEO_HEVC
    private const val VIDEO_MPEG4 = MediaFormat.MIMETYPE_VIDEO_MPEG4

    /** 拿不到帧率且探测失败时的兜底（约 30fps），正常路径不会用到 */
    private const val FALLBACK_VIDEO_STEP_US = 33_000L
    private const val FALLBACK_AUDIO_STEP_US = 21_000L

    /** 帧间隔的合理范围：0.5fps ~ 125fps */
    private const val MIN_FRAME_DUR_US = 8_000L
    private const val MAX_FRAME_DUR_US = 1_000_000L

    /**
     * TS -> MP4 转封装。
     *
     * [audioPath] 非空表示这是一条「音轨被拆成独立流」的视频：视频轨与音轨
     * 分别落在两个文件里，此时不能按单文件那套逻辑直接返回，必须走双输入归并。
     */
    fun convert(inputPath: String, audioPath: String? = null): String {
        val input = File(inputPath)
        require(input.exists() && input.length() > 0) { "源文件不存在或为空" }
        val audio = audioPath
            ?.takeIf { it.isNotBlank() }
            ?.let { path -> File(path).takeIf { it.exists() && it.length() > 0 } }
        if (audio == null) {
            // 已经是 mp4 就不需要再转一次
            if (input.extension.equals("mp4", true) ||
                input.extension.equals("m4v", true)
            ) {
                return input.absolutePath
            }
        }

        val target = uniqueTarget(input)
        var success = false
        try {
            val expectedMs = if (audio == null) {
                remux(input, target)
            } else {
                remuxTwo(input, audio, target)
            }
            if (!probe(target, expectedMs)) {
                throw IllegalArgumentException("转换产物未通过校验（时长或时间轴异常），可能不是标准流")
            }
            success = true
            return target.absolutePath
        } finally {
            if (!success) target.delete()
        }
    }

    private fun uniqueTarget(input: File): File {
        val dir = input.parentFile ?: File(".")
        var target = File(dir, input.nameWithoutExtension + ".mp4")
        var n = 1
        while (target.exists() && target.absolutePath != input.absolutePath) {
            target = File(dir, "${input.nameWithoutExtension}_$n.mp4")
            n++
            if (n > 999) break
        }
        return target
    }

    /** 一条轨道的探测结果 */
    private data class TrackTiming(
        /** 该轨第一个样本的原始 PTS（µs），用于保留音轨与视频之间的起始偏移 */
        val firstPtsUs: Long,
        /** 相邻帧的典型间隔（µs），取排序后 PTS 正间隔的中位数 */
        val frameDurUs: Long,
        /** 解码顺序里 PTS 是否周期性回退（带 B 帧） */
        val reordered: Boolean,
    )

    /**
     * 把一条轨道的原始 PTS 转成可写入 MP4 的时间轴。
     *
     * MediaMuxer 收到回退的 PTS 并不会写 ctts 表达显示顺序，而是把时间戳顶成
     * 「上一帧 + 最小间隔」——实测产物里 46% 的相邻帧显示时长为 0，其余帧间隔翻倍，
     * 播放表现就是卡顿。所以带 B 帧的视频必须自己重建时间轴：
     * [Mode.GRID] 按解码序号 × 帧间隔铺成等间隔网格，帧序仍是正确解码顺序，
     * 时间轴均匀；[Mode.STRICT] 用于音频与本身就单调的轨道，只做必要的防回退。
     */
    private class TrackClock(
        private val mode: Mode,
        val frameDurUs: Long,
        private val basePtsUs: Long,
        private val startUs: Long,
    ) {
        enum class Mode { STRICT, GRID }

        private var count = 0L
        private var shift = 0L
        private var gap = 0L
        private var firstRaw = Long.MIN_VALUE
        private var lastRaw = Long.MIN_VALUE
        private var lastOut = -1L
        private var maxOut = 0L

        fun next(rawPts: Long, stepUs: Long): Long {
            if (mode == Mode.GRID) {
                if (lastRaw != Long.MIN_VALUE) {
                    val jump = rawPts - lastRaw
                    // 分片缺段 / 广告插播：把缺口补回网格，否则整段被压缩、与音频错位
                    if (jump > frameDurUs * 8) gap += jump - frameDurUs
                }
                lastRaw = rawPts
                val out = startUs + gap + count * frameDurUs
                count++
                lastOut = out
                if (out > maxOut) maxOut = out
                return out
            }

            val base = if (basePtsUs >= 0) {
                basePtsUs
            } else {
                if (firstRaw == Long.MIN_VALUE) firstRaw = rawPts
                firstRaw
            }
            var value = rawPts - base + startUs + shift
            if (lastOut >= 0 && value <= lastOut) {
                val back = lastOut - value
                value = if (back > 1_000_000L) {
                    // 时间轴被重置（分段拼接 / 广告插播）：整体平移，保持连续
                    shift += back + stepUs
                    lastOut + stepUs
                } else {
                    // 时间戳相同或轻微回退：只压 1µs，保证严格递增
                    lastOut + 1
                }
            }
            if (value < 0) value = 0
            lastOut = value
            if (value > maxOut) maxOut = value
            return value
        }

        /** ADTS 拆帧后由调用方告知实际写到的最后一个时间戳 */
        fun markWritten(ptsUs: Long) {
            if (ptsUs > lastOut) lastOut = ptsUs
            if (ptsUs > maxOut) maxOut = ptsUs
        }
    }

    private fun remux(input: File, target: File): Long {
        val extractor = MediaExtractor()
        var muxer: MediaMuxer? = null
        try {
            extractor.setDataSource(input.absolutePath)

            var videoTrack = -1
            var audioTrack = -1
            var audioMime: String? = null
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                when {
                    videoTrack < 0 && isSupportedVideo(mime) -> videoTrack = i
                    audioTrack < 0 && isSupportedAudio(mime) -> {
                        audioTrack = i
                        audioMime = mime
                    }
                }
            }
            if (videoTrack < 0 && audioTrack < 0) {
                throw IllegalArgumentException("该视频编码不支持直接转封装（仅支持 H.264/HEVC + AAC/MP3）")
            }

            // AAC 在 TS 里是 ADTS 封装：每个样本可能包含多帧、且以 7/9 字节 ADTS 头开头。
            // MP4 的 esds 只声明 AudioSpecificConfig，样本必须是裸 AAC 帧，
            // 否则解码器按 ASC 解析 ADTS 数据必然失败（表现就是「有画面没声音」）。
            val isAdtsAac = audioMime == AAC
            val audioSampleRate = if (audioTrack >= 0) {
                runCatching {
                    extractor.getTrackFormat(audioTrack).getInteger(MediaFormat.KEY_SAMPLE_RATE)
                }.getOrDefault(44100)
            } else {
                44100
            }
            // AAC-LC 每帧 1024 个采样点
            val audioFrameDurUs = if (audioSampleRate > 0) {
                (1024L * 1_000_000L) / audioSampleRate
            } else {
                FALLBACK_AUDIO_STEP_US
            }

            val selected = listOf(videoTrack, audioTrack).filter { it >= 0 }
            val timings = HashMap<Int, TrackTiming>()
            val declaredFps = if (videoTrack >= 0) {
                readFrameRate(extractor.getTrackFormat(videoTrack))
            } else {
                0.0
            }
            for (i in selected) {
                val limit = if (i == videoTrack) 180 else 90
                analyzeTrack(input, i, limit)?.let { timings[i] = it }
            }

            // 起始偏移：统一按最早那条轨道归一，保留音轨与视频的相对起点，
            // 避免各自从 0 开始造成几十毫秒的音画错位。
            val allKnown = selected.all { timings[it] != null }
            val globalMin = if (allKnown) {
                selected.mapNotNull { timings[it]?.firstPtsUs }.minOrNull() ?: 0L
            } else {
                0L
            }

            val clocks = HashMap<Int, TrackClock>()
            for (i in selected) {
                val t = timings[i]
                val start = if (allKnown && t != null) {
                    (t.firstPtsUs - globalMin).coerceAtLeast(0L)
                } else {
                    0L
                }
                val isVideo = i == videoTrack
                // 帧间隔优先用实测中位数：TS 的 PTS 是 90kHz 整数刻度，
                // 29.97fps 实测是 33.366ms；若改用 KEY_FRAME_RATE（常写成整数 30），
                // 长时间视频会以每秒 0.1% 的速度漂移，一小时后音画差出 1~2 秒。
                // 音频不用实测值：音频样本是 PES，一个样本可能含多帧，
                // 实测间隔会是几百毫秒，真正的步长是 1024 个采样点。
                var dur = when {
                    !isVideo -> audioFrameDurUs
                    t != null && t.frameDurUs > 0 -> t.frameDurUs
                    isVideo && declaredFps > 0 -> (1_000_000.0 / declaredFps).toLong()
                    else -> FALLBACK_VIDEO_STEP_US
                }
                dur = dur.coerceIn(MIN_FRAME_DUR_US, MAX_FRAME_DUR_US)
                // 视频带 B 帧时优先保留原始 PTS，让 MediaMuxer 用 ctts 记录显示顺序；
                // 只有兜底那一遍才重建网格。音频 PTS 单调，永远走强制单调。
                // 带 B 帧的视频必须重建网格（MediaMuxer 保不住回退）；
                // 音频和本就单调的轨道走强制单调，保留原始时间轴。
                val mode = if (isVideo && t != null && t.reordered) {
                    TrackClock.Mode.GRID
                } else {
                    TrackClock.Mode.STRICT
                }
                clocks[i] = TrackClock(
                    mode = mode,
                    frameDurUs = dur,
                    basePtsUs = t?.firstPtsUs ?: -1L,
                    startUs = start,
                )
                if (mode != TrackClock.Mode.STRICT) {
                    Log.i(
                        TAG,
                        "timeline: track=$i mode=$mode frameDurUs=$dur " +
                            "reordered=${t?.reordered == true} startUs=$start"
                    )
                }
            }

            val muxIndex = HashMap<Int, Int>()
            var rotation = 0

            muxer = MediaMuxer(target.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            for (i in selected) {
                val format = extractor.getTrackFormat(i)
                if (i == audioTrack && isAdtsAac) fixAacCsd(format)
                if (format.containsKey(MediaFormat.KEY_ROTATION)) {
                    rotation = format.getInteger(MediaFormat.KEY_ROTATION)
                }
                val added = try {
                    muxer.addTrack(format)
                } catch (e: Exception) {
                    // 音频编码不被 MP4 封装支持时，宁可只出画面也不要整体失败
                    if (i == audioTrack) null else throw e
                }
                if (added != null) {
                    muxIndex[i] = added
                    extractor.selectTrack(i)
                }
            }
            if (rotation != 0) muxer.setOrientationHint(rotation)
            muxer.start()

            val buffer = ByteBuffer.allocateDirect(4 * 1024 * 1024)
            val scratch = ByteBuffer.allocateDirect(256 * 1024)
            val info = MediaCodec.BufferInfo()

            val written = HashMap<Int, Int>()
            val dropped = HashMap<Int, Int>()
            var videoSynced = videoTrack < 0
            var adtsFramesTotal = 0
            var maxOutPts = 0L

            while (true) {
                buffer.clear()
                val size = try {
                    extractor.readSampleData(buffer, 0)
                } catch (e: IllegalArgumentException) {
                    // 单个样本超过缓冲区：跳过这个样本而不是中断整个转换
                    -1
                }
                if (size < 0) {
                    if (!extractor.advance()) break
                    continue
                }
                val srcTrack = extractor.sampleTrackIndex
                val flags = extractor.sampleFlags
                val rawPts = extractor.sampleTime
                val outTrack = muxIndex[srcTrack]
                val clock = clocks[srcTrack]

                if (outTrack == null || clock == null || size <= 0 || rawPts < 0) {
                    if (!extractor.advance()) break
                    continue
                }

                // 视频必须从关键帧开始，否则开头会缺参考帧
                if (srcTrack == videoTrack && !videoSynced) {
                    if (flags and MediaExtractor.SAMPLE_FLAG_SYNC == 0) {
                        if (!extractor.advance()) break
                        continue
                    }
                    videoSynced = true
                }

                val step = if (srcTrack == videoTrack) {
                    clock.frameDurUs
                } else {
                    audioFrameDurUs
                }
                val pts = clock.next(rawPts, step)

                // AAC(ADTS)：把样本拆成单个 ADTS 帧，去头后逐帧写入。
                // 拆帧后每帧一个样本，时间戳按帧长累加，音画同步也更准。
                if (srcTrack == audioTrack && isAdtsAac) {
                    val frames = adtsFrames(buffer, size)
                    if (frames != null) {
                        var framePts = pts
                        var p = 0
                        while (p + 1 < frames.size) {
                            val off = frames[p]
                            val len = frames[p + 1]
                            if (writeSlice(muxer, outTrack, buffer, off, len, framePts,
                                    /* flags = */ 0, scratch, info)) {
                                written[srcTrack] = (written[srcTrack] ?: 0) + 1
                                adtsFramesTotal++
                            } else {
                                dropped[srcTrack] = (dropped[srcTrack] ?: 0) + 1
                            }
                            clock.markWritten(framePts)
                            if (framePts > maxOutPts) maxOutPts = framePts
                            framePts += audioFrameDurUs
                            p += 2
                        }
                        if (!extractor.advance()) break
                        continue
                    }
                }

                if (writeSlice(muxer, outTrack, buffer, 0, size, pts, flags, scratch, info)) {
                    written[srcTrack] = (written[srcTrack] ?: 0) + 1
                    if (pts > maxOutPts) maxOutPts = pts
                } else {
                    dropped[srcTrack] = (dropped[srcTrack] ?: 0) + 1
                }

                if (!extractor.advance()) break
            }

            Log.i(
                TAG,
                "remux done: video=${written[videoTrack] ?: 0} audio=${written[audioTrack] ?: 0} " +
                    "audioFrames=$adtsFramesTotal dropped=$dropped " +
                    "lastPtsUs=$maxOutPts"
            )
            val total = written.values.sum()
            if (total <= 0) throw IllegalArgumentException("没有可写入的音视频样本")

            // 保留原始 PTS 时若系统对回退时间戳不买账，会被判为写失败而丢帧；
            // 丢得太多说明这条路走不通，抛出去让上层改用网格时间线重来。
            val droppedVideo = dropped[videoTrack] ?: 0
            val writtenVideo = written[videoTrack] ?: 0
            if (writtenVideo > 0 && droppedVideo > writtenVideo / 10) {
                throw IllegalArgumentException(
                    "丢弃样本过多（$droppedVideo/$writtenVideo），改用重建时间线"
                )
            }

            val tail = if (videoTrack >= 0) {
                clocks[videoTrack]?.frameDurUs ?: FALLBACK_VIDEO_STEP_US
            } else {
                audioFrameDurUs
            }
            return (maxOutPts + tail) / 1000
        } finally {
            try {
                muxer?.stop()
            } catch (_: Exception) {
            }
            try {
                muxer?.release()
            } catch (_: Exception) {
            }
            extractor.release()
        }
    }

    /**
     * 双输入转封装：视频轨与独立音轨来自两个文件，按 PTS 归并写进同一个 MP4。
     *
     * 为什么不能各转各的再拼：MediaMuxer 只能从 0 开始顺序写样本，两个文件
     * 各自转出来的 mp4 再合并需要 container 级别的重写，代价远大于一次归并。
     *
     * 时间轴：以两条轨里较早的起点为基准整体平移，保留原始相对偏移；
     * 视频沿用 B 帧网格重建，音轨只做防回退（音频 PTS 本身单调）。
     */
    private fun remuxTwo(video: File, audio: File, target: File): Long {
        val vEx = MediaExtractor()
        val aEx = MediaExtractor()
        var muxer: MediaMuxer? = null
        try {
            vEx.setDataSource(video.absolutePath)
            aEx.setDataSource(audio.absolutePath)

            var vTrack = -1
            for (i in 0 until vEx.trackCount) {
                val mime = vEx.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
                if (isSupportedVideo(mime)) {
                    vTrack = i
                    break
                }
            }
            var aTrack = -1
            var audioMime: String? = null
            for (i in 0 until aEx.trackCount) {
                val mime = aEx.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
                if (isSupportedAudio(mime)) {
                    aTrack = i
                    audioMime = mime
                    break
                }
            }
            if (vTrack < 0) {
                throw IllegalArgumentException("音轨已下载，但画面编码不支持直接转封装（仅支持 H.264/HEVC）")
            }
            if (aTrack < 0) {
                throw IllegalArgumentException("独立音轨的编码不支持直接转封装（仅支持 AAC/MP3）")
            }

            vEx.selectTrack(vTrack)
            aEx.selectTrack(aTrack)

            // fMP4 音轨本身就是 mp4 封装，样本是裸 AAC；只有 TS 里的音轨才是
            // ADTS 封装，需要拆帧并把 csd-0 从 ADTS 头换成 AudioSpecificConfig。
            val audioIsMp4 = audio.extension.lowercase() in
                setOf("mp4", "m4a", "m4v")
            val isAdtsAac = audioMime == AAC && !audioIsMp4
            val audioSampleRate = runCatching {
                aEx.getTrackFormat(aTrack).getInteger(MediaFormat.KEY_SAMPLE_RATE)
            }.getOrDefault(44100)
            val audioFrameDurUs = if (audioSampleRate > 0) {
                (1024L * 1_000_000L) / audioSampleRate
            } else {
                FALLBACK_AUDIO_STEP_US
            }

            val vTiming = analyzeTrack(video, vTrack, 180)
            val aTiming = analyzeTrack(audio, aTrack, 90)
            val vFirst = vTiming?.firstPtsUs ?: 0L
            val aFirst = aTiming?.firstPtsUs ?: 0L
            // 分轨后两条流各自从 0 起算；统一按较早的一条归零，
            // 保留它们原本的相对起点，避免几十毫秒到几秒的口型偏移。
            val globalMin = minOf(vFirst, aFirst)

            var vDur = vTiming?.frameDurUs ?: 0L
            if (vDur <= 0) {
                val declared = readFrameRate(vEx.getTrackFormat(vTrack))
                vDur = if (declared > 0) {
                    (1_000_000.0 / declared).toLong()
                } else {
                    FALLBACK_VIDEO_STEP_US
                }
            }
            vDur = vDur.coerceIn(MIN_FRAME_DUR_US, MAX_FRAME_DUR_US)

            val vClock = TrackClock(
                mode = if (vTiming?.reordered == true) {
                    TrackClock.Mode.GRID
                } else {
                    TrackClock.Mode.STRICT
                },
                frameDurUs = vDur,
                basePtsUs = vTiming?.firstPtsUs ?: -1L,
                startUs = (vFirst - globalMin).coerceAtLeast(0L),
            )
            val aClock = TrackClock(
                mode = TrackClock.Mode.STRICT,
                frameDurUs = audioFrameDurUs,
                basePtsUs = aTiming?.firstPtsUs ?: -1L,
                startUs = (aFirst - globalMin).coerceAtLeast(0L),
            )

            val vFormat = vEx.getTrackFormat(vTrack)
            val aFormat = aEx.getTrackFormat(aTrack)
            val mx = MediaMuxer(
                target.absolutePath,
                MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4
            )
            muxer = mx
            val muxV = mx.addTrack(vFormat)
            if (isAdtsAac) fixAacCsd(aFormat)
            val muxA = mx.addTrack(aFormat)
            val rotation = if (vFormat.containsKey(MediaFormat.KEY_ROTATION)) {
                vFormat.getInteger(MediaFormat.KEY_ROTATION)
            } else {
                0
            }
            if (rotation != 0) mx.setOrientationHint(rotation)
            mx.start()

            val vBuf = ByteBuffer.allocateDirect(4 * 1024 * 1024)
            val aBuf = ByteBuffer.allocateDirect(1024 * 1024)
            val scratch = ByteBuffer.allocateDirect(256 * 1024)
            val info = MediaCodec.BufferInfo()

            var vSize = -1
            var vPts = -1L
            var vFlags = 0
            var vDone = false
            var aSize = -1
            var aPts = -1L
            var aFlags = 0
            var aDone = false
            var vWritten = 0
            var aWritten = 0
            var maxOutPts = 0L
            var videoSynced = false

            fun pullVideo() {
                while (true) {
                    vBuf.clear()
                    val size = try {
                        vEx.readSampleData(vBuf, 0)
                    } catch (_: Exception) {
                        -1
                    }
                    if (size < 0) {
                        vDone = true
                        return
                    }
                    val pts = vEx.sampleTime
                    if (pts < 0 || size <= 0) {
                        if (!vEx.advance()) {
                            vDone = true
                            return
                        }
                        continue
                    }
                    // 视频必须从关键帧开始，否则开头会缺参考帧
                    if (!videoSynced &&
                        (vEx.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC) == 0
                    ) {
                        if (!vEx.advance()) {
                            vDone = true
                            return
                        }
                        continue
                    }
                    videoSynced = true
                    vSize = size
                    vPts = pts
                    vFlags = vEx.sampleFlags
                    return
                }
            }

            fun pullAudio() {
                while (true) {
                    aBuf.clear()
                    val size = try {
                        aEx.readSampleData(aBuf, 0)
                    } catch (_: Exception) {
                        -1
                    }
                    if (size < 0) {
                        aDone = true
                        return
                    }
                    val pts = aEx.sampleTime
                    if (pts < 0 || size <= 0) {
                        if (!aEx.advance()) {
                            aDone = true
                            return
                        }
                        continue
                    }
                    aSize = size
                    aPts = pts
                    aFlags = aEx.sampleFlags
                    return
                }
            }

            fun advanceVideo() {
                if (!vEx.advance()) vDone = true else pullVideo()
            }

            fun advanceAudio() {
                if (!aEx.advance()) aDone = true else pullAudio()
            }

            pullVideo()
            pullAudio()
            while (!vDone || !aDone) {
                val takeVideo = !vDone && (aDone || vPts <= aPts)
                if (takeVideo) {
                    val pts = vClock.next(vPts, vDur)
                    if (writeSlice(mx, muxV, vBuf, 0, vSize, pts, vFlags, scratch, info)) {
                        vWritten++
                        if (pts > maxOutPts) maxOutPts = pts
                    }
                    advanceVideo()
                } else {
                    val pts = aClock.next(aPts, audioFrameDurUs)
                    val frames = if (isAdtsAac) adtsFrames(aBuf, aSize) else null
                    if (frames != null) {
                        var framePts = pts
                        var p = 0
                        while (p + 1 < frames.size) {
                            val off = frames[p]
                            val len = frames[p + 1]
                            if (writeSlice(mx, muxA, aBuf, off, len, framePts, 0, scratch, info)) {
                                aWritten++
                            }
                            aClock.markWritten(framePts)
                            if (framePts > maxOutPts) maxOutPts = framePts
                            framePts += audioFrameDurUs
                            p += 2
                        }
                    } else if (writeSlice(mx, muxA, aBuf, 0, aSize, pts, aFlags, scratch, info)) {
                        aWritten++
                        if (pts > maxOutPts) maxOutPts = pts
                    }
                    advanceAudio()
                }
            }

            Log.i(
                TAG,
                "remuxTwo done: video=$vWritten audio=$aWritten adts=$isAdtsAac " +
                    "lastPtsUs=$maxOutPts vStart=${vFirst - globalMin} aStart=${aFirst - globalMin}"
            )
            if (vWritten <= 0) throw IllegalArgumentException("没有可写入的视频样本")
            if (aWritten <= 0) throw IllegalArgumentException("音轨里没有可写入的音频样本")
            return (maxOutPts + vDur) / 1000
        } finally {
            try {
                muxer?.stop()
            } catch (_: Exception) {
            }
            try {
                muxer?.release()
            } catch (_: Exception) {
            }
            try {
                vEx.release()
            } catch (_: Exception) {
            }
            try {
                aEx.release()
            } catch (_: Exception) {
            }
        }
    }

    /**
     * 用一个独立的 extractor 试读前 [limit] 个样本，判断该轨时间戳特征。
     * 独立实例是为了不打乱主流程的读取位置（部分 extractor 的 seekTo 不可靠）。
     */
    private fun analyzeTrack(input: File, track: Int, limit: Int): TrackTiming? {
        val reader = MediaExtractor()
        val pts = ArrayList<Long>(limit)
        try {
            reader.setDataSource(input.absolutePath)
            reader.selectTrack(track)
            val buf = ByteBuffer.allocateDirect(2 * 1024 * 1024)
            while (pts.size < limit) {
                buf.clear()
                val size = try {
                    reader.readSampleData(buf, 0)
                } catch (_: Exception) {
                    -1
                }
                if (size < 0) {
                    if (!reader.advance()) break
                    continue
                }
                val t = reader.sampleTime
                if (t >= 0) pts.add(t)
                if (!reader.advance()) break
            }
        } catch (e: Exception) {
            Log.w(TAG, "analyzeTrack failed: track=$track ${e.message}")
        } finally {
            try {
                reader.release()
            } catch (_: Exception) {
            }
        }
        if (pts.isEmpty()) return null

        // 帧间隔：排序后再取正间隔中位数。解码顺序的间隔会被 B 帧打乱，
        // 排序后的间隔才是真实帧间隔。
        val sorted = pts.sorted()
        val deltas = ArrayList<Long>(sorted.size)
        for (i in 1 until sorted.size) {
            val d = sorted[i] - sorted[i - 1]
            if (d in 500L..2_000_000L) deltas.add(d)
        }
        deltas.sort()
        val frameDur = if (deltas.isEmpty()) 0L else deltas[deltas.size / 2]

        // 解码顺序里 PTS 往回走、且回退幅度不到 4 帧，就是 B 帧重排；
        // 幅度超过 4 帧的回退属于时间轴重置，交给平移逻辑处理。
        var lags = 0
        val window = (frameDur.takeIf { it > 0 } ?: FALLBACK_VIDEO_STEP_US) * 4
        for (i in 1 until pts.size) {
            val d = pts[i] - pts[i - 1]
            if (d < 0 && -d <= window) lags++
        }
        return TrackTiming(pts[0], frameDur, lags >= 2)
    }

    private fun readFrameRate(format: MediaFormat): Double {
        if (format.containsKey(MediaFormat.KEY_FRAME_RATE)) {
            val fps = runCatching {
                format.getInteger(MediaFormat.KEY_FRAME_RATE).toDouble()
            }.getOrDefault(0.0)
            if (fps > 0) return fps
        }
        if (format.containsKey("frame-rate")) {
            val fps = runCatching { format.getFloat("frame-rate").toDouble() }
                .getOrDefault(0.0)
            if (fps > 0) return fps
        }
        return 0.0
    }

    /** 把 [src] 的一段写入封装器（先拷进直接缓冲，避免 position/limit 影响调用方）。
     *  [scratch] 是复用的小缓冲；单个样本超过它时按需分配，避免大视频帧被静默丢弃。 */
    private var writeFailures = 0

    private fun writeSlice(
        muxer: MediaMuxer,
        track: Int,
        src: ByteBuffer,
        offset: Int,
        length: Int,
        ptsUs: Long,
        flags: Int,
        scratch: ByteBuffer,
        info: MediaCodec.BufferInfo,
    ): Boolean {
        return try {
            // 用 duplicate 做只读视图：直接改 src 的 position/limit 会让同一
            // 样本的后续帧越界（newPosition > limit），导致除首帧外全部写失败。
            // 视频样本可达数 MB，而复用缓冲只有 256KB；超限必须换一块，
            // 否则 scratch.limit(length) 抛异常被 catch 吞掉，帧会静默丢失。
            val work = if (length > scratch.capacity()) {
                ByteBuffer.allocateDirect(length)
            } else {
                scratch
            }
            val view = src.duplicate()
            view.position(offset)
            view.limit(offset + length)
            work.clear()
            work.limit(length)
            work.put(view)
            work.flip()
            info.set(0, length, ptsUs, flags)
            muxer.writeSampleData(track, work, info)
            true
        } catch (e: Exception) {
            if (writeFailures < 3) {
                writeFailures++
                Log.e(TAG, "writeSampleData failed: track=$track pts=$ptsUs len=$length -> ${e.message}")
            }
            false
        }
    }

    /**
     * 解析 ADTS 帧边界，返回 [off0,len0,off1,len1,...]（不含 ADTS 头）。
     * 样本不是 ADTS 封装时返回 null，交由调用方按普通样本写出。
     */
    private fun adtsFrames(buffer: ByteBuffer, size: Int): IntArray? {
        if (size < 7) return null
        buffer.position(0)
        buffer.limit(size)
        val b0 = buffer.get(0).toInt() and 0xFF
        val b1 = buffer.get(1).toInt() and 0xFF
        if (b0 != 0xFF || (b1 and 0xF0) != 0xF0) return null

        val out = ArrayList<Int>(64)
        var i = 0
        while (i + 7 <= size) {
            val h0 = buffer.get(i).toInt() and 0xFF
            val h1 = buffer.get(i + 1).toInt() and 0xFF
            if (h0 != 0xFF || (h1 and 0xF0) != 0xF0) break
            val protectionAbsent = h1 and 0x01
            val headerLen = if (protectionAbsent == 1) 7 else 9
            val h3 = buffer.get(i + 3).toInt() and 0xFF
            val h4 = buffer.get(i + 4).toInt() and 0xFF
            val h5 = buffer.get(i + 5).toInt() and 0xFF
            val frameLen = ((h3 and 0x03) shl 11) or (h4 shl 3) or ((h5 and 0xE0) shr 5)
            if (frameLen < headerLen || i + frameLen > size) break
            out.add(i + headerLen)
            out.add(frameLen - headerLen)
            i += frameLen
        }
        return if (out.isEmpty()) null else out.toIntArray()
    }

    private fun isSupportedVideo(mime: String): Boolean =
        mime == VIDEO_AVC || mime == VIDEO_HEVC || mime == VIDEO_MPEG4

    /** MP4 可直接承载、且 MediaMuxer 能封装的音频编码 */
    private fun isSupportedAudio(mime: String): Boolean =
        mime == AAC || mime == MediaFormat.MIMETYPE_AUDIO_MPEG

    /**
     * TS 里的 AAC 轨道 csd-0 常带 ADTS 头（0xFF 0xF1 ...）。
     * MP4 的 esds 需要的是 2 字节 AudioSpecificConfig，混入 ADTS 头会让
     * 播放器无法解析音频配置，表现为「有画面没声音」或直接打不开。
     */
    private fun fixAacCsd(format: MediaFormat) {
        val csd = format.getByteBuffer("csd-0") ?: return
        val bytes = ByteArray(csd.remaining())
        csd.get(bytes)
        csd.rewind()
        if (bytes.size < 7) return
        val b0 = bytes[0].toInt() and 0xFF
        val b1 = bytes[1].toInt() and 0xFF
        if (b0 != 0xFF || (b1 and 0xF0) != 0xF0) return // 已经是 ASC

        val profile = (bytes[2].toInt() shr 6) and 0x03
        val freqIndex = (bytes[2].toInt() shr 2) and 0x0F
        val channels =
            ((bytes[2].toInt() and 0x01) shl 2) or ((bytes[3].toInt() shr 6) and 0x03)
        val asc = byteArrayOf(
            (((profile + 1) shl 3) or (freqIndex shr 1)).toByte(),
            (((freqIndex and 0x01) shl 7) or ((channels and 0x0F) shl 3)).toByte()
        )
        format.setByteBuffer("csd-0", ByteBuffer.wrap(asc))
    }

    /** 用系统解码器确认产物真的能播：时长对得上、视频能取出首帧、时间轴没有塌陷。 */
    private fun probe(file: File, expectedMs: Long): Boolean {
        if (!file.exists() || file.length() < 1024) return false
        val retriever = MediaMetadataRetriever()
        var duration = 0L
        var hasVideo = false
        var frameOk = true
        try {
            retriever.setDataSource(file.absolutePath)
            duration = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull() ?: 0L
            hasVideo = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_VIDEO) == "yes"
            if (hasVideo) {
                val frame = retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                frameOk = frame != null
                frame?.recycle()
            }
        } catch (_: Exception) {
            return false
        } finally {
            try {
                retriever.release()
            } catch (_: Exception) {
            }
        }
        if (duration <= 0 || !frameOk) return false
        if (expectedMs > 1500) {
            val diff = kotlin.math.abs(duration - expectedMs)
            if (diff > maxOf(1500L, expectedMs / 10)) return false
        }
        return if (hasVideo) probeTimeline(file) else true
    }

    /**
     * 抽查前 120 个视频样本的时间轴是否「塌陷」。
     *
     * 注意不能要求 PTS 严格递增：合规的带 B 帧 MP4 里，解码顺序的 PTS 本来就会
     * 回退（显示顺序由 ctts 表达）。旧实现把回退压平后，会出现大量**相同**的
     * 时间戳（每两帧挤在同一毫秒），那才是掉帧卡顿的形态。所以这里检查
     * 排序后相邻值是否有过多重复、帧间隔中位数是否被压到 0。
     */
    private fun probeTimeline(file: File): Boolean {
        val reader = MediaExtractor()
        return try {
            reader.setDataSource(file.absolutePath)
            var track = -1
            for (i in 0 until reader.trackCount) {
                val mime = reader.getTrackFormat(i)
                    .getString(MediaFormat.KEY_MIME) ?: continue
                if (isSupportedVideo(mime)) {
                    track = i
                    break
                }
            }
            if (track < 0) {
                true
            } else {
                reader.selectTrack(track)
                val buf = ByteBuffer.allocateDirect(256 * 1024)
                val pts = ArrayList<Long>(120)
                while (pts.size < 120) {
                    buf.clear()
                    val size = try {
                        reader.readSampleData(buf, 0)
                    } catch (_: Exception) {
                        -1
                    }
                    if (size < 0) {
                        if (!reader.advance()) break
                        continue
                    }
                    val t = reader.sampleTime
                    if (t >= 0) pts.add(t)
                    if (!reader.advance()) break
                }
                if (pts.size < 8) {
                    true
                } else {
                    val sorted = pts.sorted()
                    var duplicates = 0
                    val deltas = ArrayList<Long>(sorted.size)
                    for (i in 1 until sorted.size) {
                        val d = sorted[i] - sorted[i - 1]
                        if (d == 0L) duplicates++ else deltas.add(d)
                    }
                    if (duplicates > sorted.size / 20) {
                        Log.w(TAG, "probeTimeline: ${duplicates}/${sorted.size} 个重复时间戳")
                        false
                    } else if (deltas.isEmpty()) {
                        false
                    } else {
                        deltas.sort()
                        val median = deltas[deltas.size / 2]
                        if (median < 1_000L) {
                            Log.w(TAG, "probeTimeline: 帧间隔中位数仅 ${median}µs")
                        }
                        median >= 1_000L
                    }
                }
            }
        } catch (_: Exception) {
            false
        } finally {
            try {
                reader.release()
            } catch (_: Exception) {
            }
        }
    }
}
