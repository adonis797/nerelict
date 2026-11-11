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
 * 针对 HLS（m3u8 分片合并出来的 TS）常见的「转出来打不开」做了四件事：
 *  1. 时间戳重建：分片拼接后 PTS 可能回退到 0，B 帧也会让 PTS 倒退，
 *     统一做「小回退压平、大回退整体平移」，保证单调递增；
 *  2. AAC 的 csd-0 若是 ADTS 头，转换为 AudioSpecificConfig 再交给 MP4 封装，
 *     否则写出的 esds 非法，播放器无法创建音频解码器；
 *  3. 视频从第一个关键帧开始写，避免开头缺参考帧导致黑屏 / 花屏；
 *  4. 产物用系统解码器校验（时长 + 首帧），不合格就换一种时间线策略重来。
 */
object Mp4Converter {

    private const val TAG = "Mp4Converter"
    private const val AAC = MediaFormat.MIMETYPE_AUDIO_AAC
    private const val VIDEO_AVC = MediaFormat.MIMETYPE_VIDEO_AVC
    private const val VIDEO_HEVC = MediaFormat.MIMETYPE_VIDEO_HEVC
    private const val VIDEO_MPEG4 = MediaFormat.MIMETYPE_VIDEO_MPEG4

    private const val VIDEO_STEP_US = 33_000L
    private const val AUDIO_STEP_US = 21_000L

    fun convert(inputPath: String): String {
        val input = File(inputPath)
        require(input.exists() && input.length() > 0) { "源文件不存在或为空" }
        // 已经是 mp4 就不需要再转一次
        if (input.extension.equals("mp4", true) ||
            input.extension.equals("m4v", true)
        ) {
            return input.absolutePath
        }

        val target = uniqueTarget(input)
        var success = false
        try {
            // 第一遍：保留原始时间线（只做必要修正），画质与音画同步最好
            runCatching { remux(input, target, syntheticTimeline = false) }
            if (probe(target)) {
                success = true
            } else {
                target.delete()
                // 第二遍：完全按解码顺序重建时间线，保证一定能播
                remux(input, target, syntheticTimeline = true)
                success = probe(target)
            }
            if (!success) {
                throw IllegalArgumentException("转换产物无法解码，可能不是标准 TS 流")
            }
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

    private fun remux(input: File, target: File, syntheticTimeline: Boolean) {
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
            val frameDurUs = if (audioSampleRate > 0) {
                (1024L * 1_000_000L) / audioSampleRate
            } else {
                AUDIO_STEP_US
            }

            val selected = listOf(videoTrack, audioTrack).filter { it >= 0 }
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

            // 每条轨道各自的时间线状态
            val basePts = HashMap<Int, Long>()
            val shift = HashMap<Int, Long>()
            val lastPts = HashMap<Int, Long>()
            val written = HashMap<Int, Int>()
            val dropped = HashMap<Int, Int>()
            var videoSynced = videoTrack < 0
            var adtsFramesTotal = 0

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

                if (outTrack == null || size <= 0 || rawPts < 0) {
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

                val step = if (srcTrack == videoTrack) VIDEO_STEP_US else frameDurUs
                val pts: Long
                if (syntheticTimeline) {
                    val prev = lastPts[srcTrack]
                    pts = if (prev == null) 0L else prev + step
                } else {
                    val base = basePts.getOrPut(srcTrack) { rawPts }
                    var value = rawPts - base + (shift[srcTrack] ?: 0L)
                    val prev = lastPts[srcTrack]
                    if (prev != null && value <= prev) {
                        val back = prev - value
                        value = if (back > 1_000_000L) {
                            // 时间轴被重置（分段拼接 / 广告插播）：整体平移，保持连续
                            shift[srcTrack] = (shift[srcTrack] ?: 0L) + back + step
                            prev + step
                        } else {
                            // 同轨样本时间戳相同或轻微倒退：压平到 +1us
                            prev + 1
                        }
                    }
                    if (value < 0) value = 0
                    pts = value
                }

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
                            lastPts[srcTrack] = framePts
                            framePts += frameDurUs
                            p += 2
                        }
                        if (!extractor.advance()) break
                        continue
                    }
                }

                lastPts[srcTrack] = pts
                if (writeSlice(muxer, outTrack, buffer, 0, size, pts, flags, scratch, info)) {
                    written[srcTrack] = (written[srcTrack] ?: 0) + 1
                } else {
                    dropped[srcTrack] = (dropped[srcTrack] ?: 0) + 1
                }

                if (!extractor.advance()) break
            }

            Log.i(
                TAG,
                "remux done: video=${written[videoTrack] ?: 0} audio=${written[audioTrack] ?: 0} " +
                    "audioFrames=$adtsFramesTotal dropped=$dropped synthetic=$syntheticTimeline"
            )
            val total = written.values.sum()
            if (total <= 0) throw IllegalArgumentException("没有可写入的音视频样本")
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

    /** 用系统解码器确认产物真的能播：有时长，且视频能取出首帧。 */
    private fun probe(file: File): Boolean {
        if (!file.exists() || file.length() < 1024) return false
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(file.absolutePath)
            val duration = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull() ?: 0L
            val hasVideo = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_VIDEO) == "yes"
            val frame = if (hasVideo) {
                retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
            } else {
                null
            }
            val ok = duration > 0 && (!hasVideo || frame != null)
            frame?.recycle()
            ok
        } catch (_: Exception) {
            false
        } finally {
            try {
                retriever.release()
            } catch (_: Exception) {
            }
        }
    }
}
