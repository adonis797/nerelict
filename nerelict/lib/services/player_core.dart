import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'media_source.dart';

/// 播放内核能力集合。UI 只按能力显示按钮，避免在不存在的平台上
/// 展示点了没反应的入口（例如 DASH 轨道选择、桌面端画中画）。
@immutable
class PlayerCapabilities {
  const PlayerCapabilities({
    required this.speed,
    required this.volume,
    required this.seek,
    required this.videoTracks,
    required this.audioTracks,
    required this.captions,
    required this.looping,
  });

  final bool speed;
  final bool volume;
  final bool seek;
  final bool videoTracks;
  final bool audioTracks;
  final bool captions;
  final bool looping;
}

/// player_core 抽象层。
///
/// 当前实现是 [VideoPlayerCore]（Android 底层仍是 media3 / ExoPlayer，
/// 复用其 HLS / DASH / Progressive 解码与轨道选择能力）。
/// UI 只依赖这个接口，将来若要换成自己的 Texture / PlatformView 内核，
/// 替换实现即可，不需要改动 player_ui。
abstract class PlayerCore {
  ValueListenable<VideoPlayerValue> get values;
  Widget videoWidget();
  Widget progressWidget({bool allowScrubbing});

  bool get ready;
  String? get error;
  PlayerCapabilities get capabilities;

  bool get isPlaying;
  Duration get position;
  Duration get duration;
  double get aspectRatio;

  Future<void> play();
  Future<void> pause();
  Future<void> seekTo(Duration position);
  Future<void> setSpeed(double speed);
  Future<void> setVolume(double volume);
  Future<void> setLooping(bool value);

  Future<List<VideoTrack>> videoTracks();
  Future<void> selectVideoTrack(VideoTrack? track);
  Future<List<VideoAudioTrack>> audioTracks();
  Future<void> selectAudioTrack(String id);
  Future<void> setSubtitle(String content, String name);
  Future<void> clearSubtitle();

  Future<void> dispose();
}

/// 基于 video_player 的适配实现。
class VideoPlayerCore implements PlayerCore {
  VideoPlayerCore._(this._controller, this.capabilities);

  final VideoPlayerController _controller;

  @override
  final PlayerCapabilities capabilities;

  /// 建立会话：playbackUrl 可指向本地边下边播代理，source.url 仍是原始地址。
  ///
  /// 稳定性处理：初始化整体限时 30s，失败后重建一次控制器再试
  /// （部分流首次握手失败与连接复用有关，重建通常即可恢复）。
  static Future<VideoPlayerCore> create({
    required MediaSource source,
    String? playbackUrl,
    Map<String, String>? extraHeaders,
    double initialSpeed = 1.0,
    Duration? resumeAt,
  }) async {
    final uri = Uri.tryParse(playbackUrl ?? source.url);
    if (uri == null) {
      throw StateError('播放地址无效');
    }
    final headers = <String, String>{
      ...source.headers,
      ...?extraHeaders,
    };

    VideoPlayerController build() => source.local
        ? VideoPlayerController.file(File(source.raw))
        : VideoPlayerController.networkUrl(
            uri,
            httpHeaders: headers,
            videoPlayerOptions: VideoPlayerOptions(
              mixWithOthers: false,
              allowBackgroundPlayback: false,
            ),
          );

    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      final controller = build();
      final core = VideoPlayerCore._(
        controller,
        PlayerCapabilities(
          speed: true,
          volume: true,
          seek: true,
          videoTracks: controller.isVideoTrackSupportAvailable(),
          audioTracks: controller.isAudioTrackSupportAvailable(),
          captions: true,
          looping: true,
        ),
      );
      try {
        await controller
            .initialize()
            .timeout(const Duration(seconds: 30));
        if (initialSpeed != 1.0) {
          await controller.setPlaybackSpeed(initialSpeed);
        }
        if (resumeAt != null && resumeAt > Duration.zero) {
          await controller.seekTo(resumeAt);
        }
        await controller.play();
        return core;
      } catch (e) {
        lastError = e;
        try {
          await controller.dispose();
        } catch (_) {}
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 350));
        }
      }
    }
    throw lastError is Exception
        ? lastError
        : StateError('播放器初始化失败：${lastError ?? '未知错误'}');
  }

  @override
  ValueListenable<VideoPlayerValue> get values => _controller;

  @override
  Widget videoWidget() => VideoPlayer(_controller);

  @override
  Widget progressWidget({bool allowScrubbing = true}) => VideoProgressIndicator(
        _controller,
        allowScrubbing: allowScrubbing,
        colors: const VideoProgressColors(
          playedColor: Color(0xFF4C8DFF),
          bufferedColor: Colors.white38,
          backgroundColor: Colors.white24,
        ),
      );

  @override
  bool get ready => _controller.value.isInitialized;

  @override
  String? get error => _controller.value.errorDescription;

  @override
  bool get isPlaying => _controller.value.isPlaying;

  @override
  Duration get position => _controller.value.position;

  @override
  Duration get duration => _controller.value.duration;

  @override
  double get aspectRatio {
    final ar = _controller.value.aspectRatio;
    return ar > 0 ? ar : 16 / 9;
  }

  @override
  Future<void> play() => _controller.play();

  @override
  Future<void> pause() => _controller.pause();

  /// 拖动进度后可能落在末尾之外，这里夹紧再交给内核，避免部分解码器报错
  @override
  Future<void> seekTo(Duration position) {
    final total = _controller.value.duration;
    var target = position;
    if (target < Duration.zero) target = Duration.zero;
    if (total > Duration.zero && target > total) target = total;
    if (target == _controller.value.position) return Future<void>.value();
    return _controller.seekTo(target);
  }

  @override
  Future<void> setSpeed(double speed) =>
      _controller.setPlaybackSpeed(speed.clamp(0.25, 4.0));

  @override
  Future<void> setVolume(double volume) =>
      _controller.setVolume(volume.clamp(0.0, 1.0));

  @override
  Future<void> setLooping(bool value) => _controller.setLooping(value);

  @override
  Future<List<VideoTrack>> videoTracks() async {
    if (!capabilities.videoTracks) return <VideoTrack>[];
    try {
      return await _controller.getVideoTracks();
    } catch (_) {
      return <VideoTrack>[];
    }
  }

  @override
  Future<void> selectVideoTrack(VideoTrack? track) async {
    if (!capabilities.videoTracks) return;
    try {
      await _controller.selectVideoTrack(track);
    } catch (_) {}
  }

  @override
  Future<List<VideoAudioTrack>> audioTracks() async {
    if (!capabilities.audioTracks) return <VideoAudioTrack>[];
    try {
      return await _controller.getAudioTracks();
    } catch (_) {
      return <VideoAudioTrack>[];
    }
  }

  @override
  Future<void> selectAudioTrack(String id) async {
    if (!capabilities.audioTracks) return;
    try {
      await _controller.selectAudioTrack(id);
    } catch (_) {}
  }

  /// 外挂字幕：SRT / WebVTT 文本，交给 video_player 的 caption 渲染。
  @override
  Future<void> setSubtitle(String content, String name) async {
    final lower = name.toLowerCase();
    final ClosedCaptionFile file = lower.endsWith('.vtt')
        ? WebVTTCaptionFile(content)
        : SubRipCaptionFile(content);
    await _controller.setClosedCaptionFile(Future<ClosedCaptionFile>.value(file));
  }

  @override
  Future<void> clearSubtitle() => _controller.setClosedCaptionFile(null);

  @override
  Future<void> dispose() => _controller.dispose();
}

/// 播放器内可选的倍速档位。
const List<double> kPlaybackSpeeds = <double>[
  0.5,
  0.75,
  1.0,
  1.25,
  1.5,
  2.0,
  3.0,
];

String formatSpeed(double speed) =>
    speed == speed.roundToDouble() ? '${speed.toInt()}x' : '${speed}x';

String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

String videoTrackLabel(VideoTrack t) {
  if (t.width != null && t.height != null && t.height! > 0) {
    return '${t.height}p';
  }
  if (t.label != null && t.label!.trim().isNotEmpty) return t.label!.trim();
  if (t.bitrate != null && t.bitrate! > 0) {
    return '${(t.bitrate! / 1000).round()} kbps';
  }
  return '画质 ${t.id}';
}

String audioTrackLabel(VideoAudioTrack t) {
  final parts = <String>[
    if (t.label != null && t.label!.trim().isNotEmpty) t.label!.trim(),
    if (t.language != null && t.language!.trim().isNotEmpty) t.language!.trim(),
    if (t.channelCount != null) '${t.channelCount}ch',
    if (t.codec != null && t.codec!.trim().isNotEmpty) t.codec!.trim(),
  ];
  return parts.isEmpty ? '音轨 ${t.id}' : parts.join(' · ');
}
