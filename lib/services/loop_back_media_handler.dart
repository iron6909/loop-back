import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show rootBundle;

import '../utils/app_data_dir.dart';
import 'media_player_backend.dart';

/// 视频链路的媒体会话 handler，经 MediaSessionRouter 激活/交还。
class LoopBackMediaHandler extends BaseAudioHandler with SeekHandler {
  LoopBackMediaHandler(this._backend) {
    _playingSub = _backend.playingStream.listen((_) => _broadcastState());
    _bufferingSub = _backend.bufferingStream.listen((buffering) {
      _buffering = buffering;
      _broadcastState();
    });
    _durationSub = _backend.durationStream.listen((duration) {
      if (duration <= Duration.zero) return;
      final item = mediaItem.value;
      if (item != null && item.duration != duration) {
        mediaItem.add(item.copyWith(duration: duration));
      }
      _broadcastState();
    });
    _completedSub = _backend.completedStream.listen((_) => _broadcastState());
  }

  final MediaPlayerBackend _backend;
  MediaPlayerBackend get backend => _backend;

  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<void>? _completedSub;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;
  StreamSubscription<void>? _becomingNoisySub;

  Future<void> Function()? _onPlayCommand;
  Future<void> Function()? _onPauseCommand;
  Future<void> Function()? _onSkipToPrevious;
  Future<void> Function()? _onSkipToNext;
  Future<void> Function()? _onRewind;
  Future<void> Function()? _onFastForward;
  bool? _logicalPlaying;
  bool _progressFrozen = false;
  bool _opened = false;
  bool _disposed = false;
  bool _buffering = false;
  Uri? _artworkUri;

  /// 注册/清空系统播放、暂停命令回调。
  void setTransportHandlers({
    Future<void> Function()? onPlay,
    Future<void> Function()? onPause,
  }) {
    _onPlayCommand = onPlay;
    _onPauseCommand = onPause;
  }

  /// 注册学习任务的上一句、下一句系统媒体控制。
  void setSkipHandlers({
    Future<void> Function()? onPrevious,
    Future<void> Function()? onNext,
  }) {
    _onSkipToPrevious = onPrevious;
    _onSkipToNext = onNext;
    if (onPrevious != null || onNext != null) {
      _onRewind = null;
      _onFastForward = null;
    }
    _broadcastState();
  }

  /// 注册无字幕媒体的后退/前进回调，与切句控制互斥。
  void setSeekHandlers({
    Future<void> Function()? onRewind,
    Future<void> Function()? onFastForward,
  }) {
    _onRewind = onRewind;
    _onFastForward = onFastForward;
    if (onRewind != null || onFastForward != null) {
      _onSkipToPrevious = null;
      _onSkipToNext = null;
    }
    _broadcastState();
  }

  /// 停顿倒计时期间保持锁屏为逻辑播放态。
  void setLogicalPlaying(bool? playing) {
    _logicalPlaying = playing;
    _broadcastState();
  }

  /// 停顿倒计时期间冻结锁屏进度外推。
  void setProgressFrozen(bool frozen) {
    if (_progressFrozen == frozen) return;
    _progressFrozen = frozen;
    _broadcastState();
  }

  Future<void> startKeepAlive() => _backend.startKeepAlive();

  Future<void> stopKeepAlive() => _backend.stopKeepAlive();

  /// 复用启动期写入的锁屏封面文件。失败不阻断视频播放。
  Future<void> prepareArtwork() async {
    if (kIsWeb) return;
    try {
      final dir = await getAppDataDirectory();
      final file = File('${dir.path}/now_playing_artwork.png');
      if (!file.existsSync()) {
        final bytes = await rootBundle.load('assets/icon/app-icon-1024.png');
        await file.writeAsBytes(bytes.buffer.asUint8List());
      }
      _artworkUri = Uri.file(file.path);
    } catch (_) {}
  }

  /// 只订阅中断与 becoming noisy；AudioSession 全局配置仍由默认音频 handler 完成。
  Future<void> configureInterruptions() async {
    if (kIsWeb || _disposed) return;
    try {
      final session = await AudioSession.instance;
      if (_disposed) return;
      final interruptionSub = session.interruptionEventStream.listen((
        event,
      ) async {
        if (event.begin && _backend.playing) {
          await pause();
          return;
        }
        if (!event.begin && event.type == AudioInterruptionType.pause) {
          _broadcastState();
        }
      });
      if (_disposed) {
        await interruptionSub.cancel();
        return;
      }
      await _interruptionSub?.cancel();
      if (_disposed) {
        await interruptionSub.cancel();
        return;
      }
      _interruptionSub = interruptionSub;

      final becomingNoisySub = session.becomingNoisyEventStream.listen((
        _,
      ) async {
        if (_backend.playing) await pause();
      });
      if (_disposed) {
        await becomingNoisySub.cancel();
        return;
      }
      await _becomingNoisySub?.cancel();
      if (_disposed) {
        await becomingNoisySub.cancel();
        return;
      }
      _becomingNoisySub = becomingNoisySub;
    } catch (_) {
      // 测试环境或平台通道不可用时跳过中断监听；播放主链路不依赖它。
    }
  }

  void setNowPlaying({
    required String id,
    required String title,
    String? subtitle,
  }) {
    _opened = true;
    mediaItem.add(
      MediaItem(
        id: id,
        title: title,
        artist: subtitle ?? 'LoopBack',
        artUri: _artworkUri,
      ),
    );
    _broadcastState();
  }

  /// 引擎内部协程直接驱动 backend，避免系统命令回调形成业务回环。
  Future<void> playBackend() async {
    await _backend.play();
    _broadcastState();
  }

  Future<void> pauseBackend() async {
    await _backend.pause();
    _broadcastState();
  }

  @override
  Future<void> play() async {
    if (_onPlayCommand != null) {
      await _onPlayCommand!();
      return;
    }
    await playBackend();
  }

  @override
  Future<void> pause() async {
    if (_onPauseCommand != null) {
      await _onPauseCommand!();
      return;
    }
    await pauseBackend();
  }

  @override
  Future<void> stop() async {
    await pauseBackend();
    _broadcastState();
    return super.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    await _backend.seek(position);
    _broadcastState();
  }

  @override
  Future<void> setSpeed(double speed) async {
    await _backend.setRate(speed);
    _broadcastState();
  }

  @override
  Future<void> skipToNext() async {
    final callback = _onSkipToNext ?? _onFastForward;
    await callback?.call();
  }

  @override
  Future<void> skipToPrevious() async {
    final callback = _onSkipToPrevious ?? _onRewind;
    await callback?.call();
  }

  @override
  Future<void> rewind() async => _onRewind?.call();

  @override
  Future<void> fastForward() async => _onFastForward?.call();

  Future<void> dispose() async {
    _disposed = true;
    await _playingSub?.cancel();
    await _bufferingSub?.cancel();
    await _durationSub?.cancel();
    await _completedSub?.cancel();
    await _interruptionSub?.cancel();
    await _becomingNoisySub?.cancel();
  }

  /// 按统一的上一项、播放/暂停、下一项顺序发布系统媒体卡片 controls。
  void _broadcastState() {
    final playing = _logicalPlaying ?? _backend.playing;
    final canNavigate =
        _onSkipToPrevious != null ||
        _onSkipToNext != null ||
        _onRewind != null ||
        _onFastForward != null;
    final controls = <MediaControl>[
      if (canNavigate) MediaControl.skipToPrevious,
      playing ? MediaControl.pause : MediaControl.play,
      if (canNavigate) MediaControl.skipToNext,
    ];
    final compactActions = canNavigate ? const [0, 1, 2] : const [0];
    playbackState.add(
      PlaybackState(
        controls: controls,
        systemActions: {
          MediaAction.play,
          MediaAction.pause,
          MediaAction.seek,
          if (canNavigate) ...{
            MediaAction.skipToNext,
            MediaAction.skipToPrevious,
          },
        },
        androidCompactActionIndices: compactActions,
        processingState: _mapState(),
        playing: playing,
        updatePosition: _backend.position,
        bufferedPosition: _backend.position,
        speed: playing && !_progressFrozen ? _backend.rate : 0.0,
      ),
    );
  }

  AudioProcessingState _mapState() {
    if (!_opened) return AudioProcessingState.idle;
    if (_buffering) return AudioProcessingState.buffering;
    return AudioProcessingState.ready;
  }
}
