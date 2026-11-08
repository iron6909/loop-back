/// 跟读录音控制器 provider。
///
/// 独立于复述的 [RetellRecordingController]，专为跟读/难句补练/收藏复习设计。
/// 使用 [RecordingService] 管理录音生命周期，录音结束后自动释放麦克风。
/// 评估仅用覆盖率（[SpeechTranscriptMatcher]），不使用 embedding 相似度。
///
/// 状态机：idle → awaitingSpeech → speaking → [processing →] idle。
/// 有 ASR 时经过 processing（评估转录），无 ASR 时直接 speaking → idle（仅存录音）。
///
/// 自动模式录音流程：
/// 1. startRecording → awaitingSpeech，启动 60s 等待开口计时器
/// 2. 检测到语音 → speaking，取消等待计时器，启动最大录音时长计时器
/// 3. 双通道检测结束：
///    - 通道 1：声学静音（silenceDuration）+ [SpeechPracticeCompletionHeuristic]
///    - 通道 2：转录停滞（liveTranscript 停止更新）
///    - 兜底：绝对静音超时（5s）
///    - 兜底：最大录音时长
/// 4. 自动停止 → processing → 评估 → idle
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/recognition_selection.dart';
import '../../models/speech_practice_models.dart';
import '../../services/app_logger.dart';
import '../../services/recording_service.dart';
import '../../services/speech/practice_chunk_transcriber.dart';
import '../../services/speech/practice_online_transcriber.dart';
import '../../services/speech/speech_capability.dart';
import '../../services/speech_completion_detector.dart';
import '../../services/speech_practice_matcher.dart';
import '../../services/speech_practice_platform.dart';
import '../learning_settings_provider.dart';
import '../local_transcription_task_provider.dart'
    show localTranscriptionTranscodeServiceProvider;
import '../offline_asr_settings_provider.dart';
import '../recognition_settings_provider.dart';
import '../speech_capability_provider.dart';
import '../speech_configuration_provider.dart' show speechConfigStoreProvider;

/// 等待开口最大时长
const _awaitingSpeechTimeout = Duration(seconds: 60);

/// 默认静音兜底阈值（无转录时）
const _defaultSilenceThreshold = Duration(seconds: 5);

/// 默认最大录音时长
const _defaultMaxRecordingDuration = Duration(seconds: 30);

/// 手动模式录音兜底上限（startRecording 时立即启动，检测到语音后按句长/段长重算）
const _manualModeInitialMax = Duration(seconds: 300);

/// 手动模式倍率（检测到语音后：max(300s, 5 × 自动模式时长)）
const _manualModeMultiplier = 5;

/// 跟读回合阶段
enum SpeechRecordingPhase { idle, awaitingSpeech, speaking, processing }

/// 跟读回合状态
class SpeechRecordingState {
  final SpeechRecordingPhase phase;
  final String? promptId;
  final String? referenceText;

  /// 当前录音评估结果
  final SpeechPracticeAttempt? currentAttempt;

  /// 在线跟读的转写状态（服务、模型、进度、费用）；本机与系统方式为 null。
  final PracticeOnlineState? onlineShadowing;

  /// 实时转录
  final String? liveTranscript;

  /// 是否检测到语音
  final bool hasDetectedSpeech;

  /// 当前静音时长
  final Duration silenceDuration;

  /// 权限状态
  final SpeechPracticePermissionState permissions;

  const SpeechRecordingState({
    this.phase = SpeechRecordingPhase.idle,
    this.promptId,
    this.referenceText,
    this.currentAttempt,
    this.onlineShadowing,
    this.liveTranscript,
    this.hasDetectedSpeech = false,
    this.silenceDuration = Duration.zero,
    this.permissions = const SpeechPracticePermissionState(),
  });

  bool get isActive => phase != SpeechRecordingPhase.idle;

  /// 是否正在录制指定 promptId
  bool isRecordingPrompt(String id) =>
      promptId == id &&
      (phase == SpeechRecordingPhase.awaitingSpeech ||
          phase == SpeechRecordingPhase.speaking);

  SpeechRecordingState copyWith({
    SpeechRecordingPhase? phase,
    String? promptId,
    bool clearPromptId = false,
    String? referenceText,
    bool clearReferenceText = false,
    SpeechPracticeAttempt? currentAttempt,
    bool clearCurrentAttempt = false,
    PracticeOnlineState? onlineShadowing,
    bool clearOnlineShadowing = false,
    String? liveTranscript,
    bool clearLiveTranscript = false,
    bool? hasDetectedSpeech,
    Duration? silenceDuration,
    SpeechPracticePermissionState? permissions,
  }) {
    return SpeechRecordingState(
      phase: phase ?? this.phase,
      promptId: clearPromptId ? null : (promptId ?? this.promptId),
      referenceText: clearReferenceText
          ? null
          : (referenceText ?? this.referenceText),
      currentAttempt: clearCurrentAttempt
          ? null
          : (currentAttempt ?? this.currentAttempt),
      onlineShadowing: clearOnlineShadowing
          ? null
          : (onlineShadowing ?? this.onlineShadowing),
      liveTranscript: clearLiveTranscript
          ? null
          : (liveTranscript ?? this.liveTranscript),
      hasDetectedSpeech: hasDetectedSpeech ?? this.hasDetectedSpeech,
      silenceDuration: silenceDuration ?? this.silenceDuration,
      permissions: permissions ?? this.permissions,
    );
  }
}

/// 句子级静音检测启发式。
///
/// 根据实时转录与参考句的匹配程度，计算所需静音等待时长。
class SpeechPracticeCompletionHeuristic {
  const SpeechPracticeCompletionHeuristic();

  /// 根据实时转录与参考句的匹配程度，计算所需静音等待时长。
  ///
  /// 委托给 [speech_completion_detector.dart] 中的独立检测器：
  /// A. [detectTailMatch] — 连续尾部匹配 + 唯一 → 1s
  /// B. [detectOverallMatchRate] — 全句匹配率 → 1-3s
  /// C. [detectTailHitCount] — 末尾 5 词命中数 → 1-5s
  ///
  /// 三条规则取最小值，无规则触发时返回兜底阈值。
  Duration computeSilenceThreshold({
    required String referenceText,
    required String partialTranscript,
    Duration? voicedDuration,
    Duration? referenceDuration,
  }) {
    return computeSilenceThresholdDetailed(
      referenceText: referenceText,
      partialTranscript: partialTranscript,
      voicedDuration: voicedDuration,
      referenceDuration: referenceDuration,
    ).threshold!;
  }

  /// 与 [computeSilenceThreshold] 逻辑一致，额外返回触发原因（用于调试日志）。
  ///
  /// 四条规则取最小值：
  /// D. [detectRemainingByPosition] — 剩余词数估算阈值
  /// A. [detectTailMatch] — 连续尾部匹配 + 唯一 → 1s
  /// B. [detectOverallMatchRate] — 全句匹配率 → 1-3s
  /// C. [detectTailHitCount] — 末尾 5 词命中数 → 1-5s
  ///
  /// 无规则触发时，兜底阈值根据有声时长比例动态计算（需传入
  /// [voicedDuration] 和 [referenceDuration]），否则固定 5s。
  DetectionResult computeSilenceThresholdDetailed({
    required String referenceText,
    required String partialTranscript,
    Duration? voicedDuration,
    Duration? referenceDuration,
  }) {
    final ctx = buildMatchContext(
      referenceText: referenceText,
      partialTranscript: partialTranscript,
    );

    // 计算动态兜底阈值
    final fallback = (voicedDuration != null && referenceDuration != null)
        ? computeDynamicFallback(
            voicedDuration: voicedDuration,
            referenceDuration: referenceDuration,
            matchRate: ctx.matchRate,
          )
        : _defaultSilenceThreshold;

    if (!ctx.hasMatch) {
      return DetectionResult(
        threshold: fallback,
        description: '无匹配, 兜底${fallback.inSeconds}s',
      );
    }

    return combineDetections(
      [
        detectRemainingByPosition(ctx), // D
        detectTailMatch(ctx), // A
        detectOverallMatchRate(ctx), // B
        detectTailHitCount(ctx), // C
      ],
      ctx,
      fallback: fallback,
    );
  }
}

final speechPracticeCompletionHeuristicProvider =
    Provider<SpeechPracticeCompletionHeuristic>((ref) {
      return const SpeechPracticeCompletionHeuristic();
    });

// ============================================================
// SpeechRecordingController — 跟读专用录音控制器
// ============================================================

/// 跟读录音控制器 provider
final speechRecordingControllerProvider =
    NotifierProvider<SpeechRecordingController, SpeechRecordingState>(
      SpeechRecordingController.new,
    );

/// 跟读录音控制器。
///
/// 使用 [RecordingService] 管理录音，[SpeechTranscriptMatcher] 做评估。
/// 录音结束后自动释放麦克风，无需调用方管理引擎生命周期。
///
/// 与 [RetellRecordingController] 的区别：
/// - 状态机含 awaitingSpeech / speaking 两个子阶段
/// - 静音检测用 [SpeechPracticeCompletionHeuristic]（句子级启发式）
/// - 评估仅用覆盖率，不使用 embedding 相似度
class SpeechRecordingController extends Notifier<SpeechRecordingState> {
  // ── 服务 ──
  RecordingService? _recordingService;
  void Function(Duration duration)? _recordingCompletionHandler;
  StreamSubscription<SpeechPracticeEvent>? _eventSub;
  int _roundGeneration = 0;
  Future<void> _cleanupTail = Future<void>.value();

  // ── 计时器 ──
  Timer? _awaitingSpeechTimer;
  Timer? _maxDurationTimer;
  Timer? _transcriptStaleTimer;

  // ── 内部状态 ──
  bool _isStopping = false;
  bool _hasDetectedSpeech = false;
  String? _lastKnownTranscript;

  /// 首次检测到语音的时间（用于计算有效说话时长）
  DateTime? _speechStartTime;
  String? _cachedReferenceText;
  String? _lastSilenceLogDesc;

  /// 原句音频时长（用于有声时长比例兜底）
  Duration? _referenceDuration;

  /// 当前回合在识别设置里登记的在途任务。
  RecognitionInFlightTask? _inFlightTask;

  /// 本回合是否使用在线转写；录音期间只有它决定停录后的处理路径。
  bool _roundUsesOnline = false;

  /// 在途的在线转写请求；取消、切换录音或退出时取消它，丢弃过期结果。
  CancelToken? _onlineCancelToken;

  /// 本回合的分块转写会话：绑定录音与语音配置身份，失败后可手动续试。
  PracticeChunkSession? _chunkSession;

  /// 在途的分块转码会话；取消时终止它，停止后续块。
  int? _onlineTranscodeSession;

  /// 登记时持有的注册处：销毁阶段不能再从已释放的容器读 provider。
  RecognitionInFlightRegistry? _inFlightRegistry;

  /// 累计有声时长（silenceMs == 0 区间的加总）
  Duration _voicedDuration = Duration.zero;

  /// 上一次有声事件的时间戳（用于累加有声时长）
  DateTime? _lastVoicedTimestamp;

  // ── 配置 ──
  bool _isManualMode = false;

  /// 自动模式最大录音时长（检测到语音后启动）
  Duration _maxRecordingDuration = _defaultMaxRecordingDuration;

  @override
  SpeechRecordingState build() {
    final lifecycleListener = AppLifecycleListener(
      onStateChange: _handleAppLifecycleChange,
    );
    ref.onDispose(() {
      lifecycleListener.dispose();
      _cancelAllTimers();
      ++_roundGeneration;
      _eventSub?.cancel();
      _unregisterInFlight();
      unawaited(_discardChunkSession());
      final service = _recordingService;
      if (service != null) unawaited(service.dispose());
    });
    return const SpeechRecordingState();
  }

  // ========== 配置方法 ==========

  /// 登记本回合为跟读用途的在途任务，供识别设置与语音配置变更告知与取消。
  void _registerInFlight(String promptId) {
    _unregisterInFlight();
    final task = RecognitionInFlightTask(
      purpose: RecognitionPurpose.shadowing,
      label: promptId,
      usesOnlineSpeech: _roundUsesOnline,
      onCancel: cancelActiveRecording,
    );
    _inFlightTask = task;
    _inFlightRegistry = ref.read(recognitionInFlightTasksProvider);
    _inFlightRegistry?.register(task);
  }

  /// 注销本回合的在途登记。
  void _unregisterInFlight() {
    final task = _inFlightTask;
    final registry = _inFlightRegistry;
    _inFlightTask = null;
    _inFlightRegistry = null;
    if (task != null && registry != null) registry.unregister(task);
  }

  /// 设置录音完成回调，供新学习统计链路接收有效输出时长。
  ///
  /// 回调只会在录音正常停止且有效时长大于零时触发；取消录音不会触发。
  void setRecordingCompletionHandler(
    void Function(Duration duration)? handler,
  ) {
    _recordingCompletionHandler = handler;
  }

  /// 设置手动控制模式
  void setManualMode(bool value) {
    _isManualMode = value;
  }

  /// 设置最大录音时长（默认 30s，仅自动模式；手动模式固定 60s）
  void setMaxRecordingDuration(Duration value) {
    _maxRecordingDuration = value;
  }

  // ========== 录音控制 ==========

  /// 开始录音
  ///
  /// 自动模式：启动 60s 等待开口计时器。
  /// 手动模式：不启动等待计时器。
  /// 两种模式均不立即启动最大录音时长计时器（等检测到语音后启动）。
  Future<void> startRecording({
    required String promptId,
    required String referenceText,
    Duration? referenceDuration,
  }) async {
    final existingService = _recordingService;
    if (state.isRecordingPrompt(promptId) ||
        (existingService?.isRecording ?? false)) {
      AppLogger.log('SpeechRec', '⏭ startRecording 跳过: 已在录音中 ($promptId)');
      return;
    }

    final generation = ++_roundGeneration;
    _cancelAllTimers();
    _isStopping = false;
    _hasDetectedSpeech = false;
    _lastKnownTranscript = null;
    _lastSilenceLogDesc = null;
    _speechStartTime = null;
    _cachedReferenceText = referenceText;
    _referenceDuration = referenceDuration;
    _voicedDuration = Duration.zero;
    _lastVoicedTimestamp = null;
    // 本回合的识别方式在开始时定下：录音期间不因局部状态变化改走其它后端。
    _roundUsesOnline = ref
        .read(recognitionSettingsProvider)
        .forPurpose(RecognitionPurpose.shadowing)
        .usesOnlineModel;
    // 录音一开始就登记在途任务：识别设置变更需要能告知并取消本回合。
    _registerInFlight(promptId);
    // 新一次录音不复用上一回合的分块进度与临时音频。
    await _discardChunkSession();

    // 先切断旧回合的所有入口，再串行释放其服务；新回合不会与旧服务并存。
    final oldFilePath = state.currentAttempt?.filePath;
    _recordingService = null;
    final cleanup = _enqueueCleanup(() async {
      await _eventSub?.cancel();
      _eventSub = null;
      if (existingService != null) {
        await existingService.cancelRecording();
        await existingService.dispose();
        if (oldFilePath != null && oldFilePath.isNotEmpty) {
          await existingService.deleteRecording(oldFilePath);
        }
      }
    });

    AppLogger.log('SpeechRec', '┌ startRecording (manual=$_isManualMode)');
    AppLogger.log('SpeechRec', '│ promptId=$promptId');
    state = SpeechRecordingState(
      phase: SpeechRecordingPhase.awaitingSpeech,
      promptId: promptId,
      referenceText: referenceText,
      permissions: state.permissions,
    );

    await cleanup;
    if (generation != _roundGeneration) return;

    final backend = _roundUsesOnline
        ? ref.read(speechRecordingOnlyBackendProvider)
        : ref.read(speechPracticeBackendProvider);
    AppLogger.log(
      'SpeechRec',
      '│ backend=${backend.runtimeType} online=$_roundUsesOnline permissions=${state.permissions.microphone.name}/${state.permissions.speech.name}',
    );
    final service = RecordingService(backend);
    _recordingService = service;
    try {
      await service.startRecording(
        promptId: promptId,
        // Apple 实时转录同时服务自动结束检测；关闭评级只跳过最终评分，
        // 不能关闭该检测通道而退化为固定静音兜底。
        // 在线只保留平台已有的实时反馈，最终文本只由在线请求产生。
        recognitionEnabled: _roundUsesOnline
            ? ref.read(systemRecognitionPlatformProvider)
            : ref.read(offlineAsrSettingsProvider).backend ==
                  AsrBackend.platform,
      );
      if (generation != _roundGeneration) {
        await service.cancelRecording();
        return;
      }
      _eventSub = service.events.listen(
        (event) => _handleRecordingEvent(event, generation),
      );

      state = state.copyWith(permissions: service.permissions);
    } on SpeechPracticePlatformException catch (error) {
      if (generation != _roundGeneration || error.code == 'cancelled') return;
      AppLogger.log('SpeechRec', '└ 录音启动失败: ${error.code} → idle');
      state = state.copyWith(
        phase: SpeechRecordingPhase.idle,
        currentAttempt: SpeechPracticeAttempt(promptId: promptId).copyWith(
          status: _statusFromError(error.code),
          errorMessage: error.message,
        ),
        permissions: service.permissions,
      );
      return;
    }

    if (_isManualMode) {
      // 手动模式：立即启动兜底计时器（用户点击停止前的安全上限）
      AppLogger.log(
        'SpeechRec',
        '│ 手动模式兜底 ${_manualModeInitialMax.inSeconds}s',
      );
      _scheduleMaxDurationTimer(
        promptId: promptId,
        generation: generation,
        maxDuration: _manualModeInitialMax,
      );
    } else {
      // 自动模式：启动 60s 等待开口计时器
      AppLogger.log(
        'SpeechRec',
        '│ 启动 ${_awaitingSpeechTimeout.inSeconds}s 等待开口计时器',
      );
      _scheduleAwaitingSpeechTimer(promptId);
    }

    AppLogger.log('SpeechRec', '└ 录音已开始，等待用户开口...');
  }

  /// 手动停止录音并评估
  Future<void> stopAndEvaluate({required String referenceText}) async {
    final promptId = state.promptId;
    if (promptId == null) return;
    final generation = _roundGeneration;

    AppLogger.log('SpeechRec', '● 手动停止录音');
    _isStopping = true;
    _cancelAllTimers();
    await _doStopAndEvaluate(
      promptId: promptId,
      referenceText: referenceText,
      generation: generation,
    );
  }

  /// 取消当前录音
  Future<void> cancelActiveRecording() async {
    final service = _recordingService;
    final generation = ++_roundGeneration;
    _cancelAllTimers();
    _speechStartTime = null;
    _recordingService = null;
    await _cancelOnlineTranscription();
    _unregisterInFlight();
    state = state.copyWith(
      phase: SpeechRecordingPhase.idle,
      clearLiveTranscript: true,
      hasDetectedSpeech: false,
      silenceDuration: Duration.zero,
    );
    await _enqueueCleanup(() async {
      await _eventSub?.cancel();
      _eventSub = null;
      if (service != null) {
        await service.cancelRecording();
        await service.dispose();
      }
    });
    if (generation != _roundGeneration) return;
  }

  // ========== 清理方法 ==========

  /// 清除当前回合状态（保留配置），并删除已完成录音的临时文件。
  Future<void> clearRecording() async {
    AppLogger.log('SpeechRec', '● clearRecording → idle');
    ++_roundGeneration;
    await _cancelOnlineTranscription();
    _unregisterInFlight();
    _cancelAllTimers();
    _isStopping = false;
    _hasDetectedSpeech = false;
    _lastKnownTranscript = null;
    final service = _recordingService;
    _recordingService = null;
    // 先读取文件路径，再立即重置状态（避免 await 延迟状态重置导致自动录音触发失败）
    final filePath = state.currentAttempt?.filePath;
    state = SpeechRecordingState(permissions: state.permissions);
    // 先完成录音服务收尾，再让调用方开始下一次播放。
    await _enqueueCleanup(() async {
      await _eventSub?.cancel();
      _eventSub = null;
      if (service != null) {
        await service.cancelRecording();
        if (filePath != null && filePath.isNotEmpty) {
          await service.deleteRecording(filePath);
        }
        await service.dispose();
      }
    });
  }

  /// 完全重置（页面 dispose 时调用）
  Future<void> fullReset() async {
    await clearRecording();
    await _cleanupTail;
    _isManualMode = false;
    _cachedReferenceText = null;
    _maxRecordingDuration = _defaultMaxRecordingDuration;
  }

  /// 删除指定录音文件
  Future<void> deleteRecording(String filePath) async {
    await _recordingService?.deleteRecording(filePath);
  }

  Future<void> _enqueueCleanup(Future<void> Function() cleanup) async {
    final previous = _cleanupTail;
    final next = () async {
      try {
        await previous;
      } catch (_) {
        // 前一回合的收尾失败不能阻塞后续回合，但必须继续执行本次收尾。
      }
      await cleanup();
    }();
    _cleanupTail = next.catchError((_) {});
    await next;
  }

  // ========== 内部方法 ==========

  /// 停止录音并评估。
  ///
  /// 停止录音 → processing → 等待转录 → 评估 → idle。
  ///
  /// 三个清晰阶段：
  /// 1. stopSession — 立即停止录音
  /// 2. processing — ASR 启用时显示"分析中..."
  /// 3. waitForTranscript + evaluate — 等待转录并评估
  Future<void> _doStopAndEvaluate({
    required String promptId,
    required String referenceText,
    required int generation,
  }) async {
    final service = _recordingService;
    if (service == null) {
      AppLogger.log('SpeechRec', '✗ 停止录音失败: RecordingService 不存在');
      state = state.copyWith(phase: SpeechRecordingPhase.idle);
      return;
    }
    if (!_isCurrentRound(generation, promptId)) return;
    final ratingEnabled = ref
        .read(learningSettingsProvider)
        .listenAndRepeatRatingEnabled;
    _cancelAllTimers();
    await _eventSub?.cancel();
    _eventSub = null;

    // 记录有效说话时长（开口 → 停止 - 尾部静音）
    final speechStart = _speechStartTime;
    _speechStartTime = null;
    final effectiveDurationMs = speechStart == null
        ? null
        : math.max(
            0,
            DateTime.now().difference(speechStart).inMilliseconds -
                state.silenceDuration.inMilliseconds,
          );

    // ── 阶段 1：停止录音（立即返回）──
    final stopResult = await service.stopSession(
      promptId: promptId,
      effectiveDurationMs: effectiveDurationMs,
    );
    if (!_isCurrentRound(generation, promptId)) {
      await service.cancelRecording();
      return;
    }
    final filePath = stopResult.filePath;
    AppLogger.log(
      'SpeechRec',
      '│ stop done online=$_roundUsesOnline file=$filePath',
    );

    if (stopResult.errorCode != null || filePath == null || filePath.isEmpty) {
      AppLogger.log('SpeechRec', '✗ 停止录音失败: ${stopResult.errorCode}');
      state = state.copyWith(
        phase: SpeechRecordingPhase.idle,
        currentAttempt: SpeechPracticeAttempt(promptId: promptId).copyWith(
          filePath: filePath,
          status: SpeechPracticeAttemptStatus.unavailable,
        ),
        clearLiveTranscript: true,
        hasDetectedSpeech: false,
        silenceDuration: Duration.zero,
      );
      return;
    }
    _recordCompletionDuration(stopResult.recordedDuration);

    // ── 跟读评级关闭：直接存录音，不等转录 ──
    if (!ratingEnabled) {
      AppLogger.log('SpeechRec', '● 跟读评级关闭，保留录音，跳过转录与评分');
      await service.shutdown();
      if (!_isCurrentRound(generation, promptId)) return;
      state = state.copyWith(
        phase: SpeechRecordingPhase.idle,
        currentAttempt: SpeechPracticeAttempt(promptId: promptId).copyWith(
          filePath: filePath,
          status: SpeechPracticeAttemptStatus.unavailable,
        ),
        clearLiveTranscript: true,
        hasDetectedSpeech: false,
        silenceDuration: Duration.zero,
      );
      return;
    }

    // ── 阶段 2：进入 processing（显示"分析中..."）──
    _enterProcessing(promptId);

    // ── 阶段 3a：在线方式只在停录后上传一次，不使用平台/本机最终结果 ──
    if (_roundUsesOnline) {
      await _transcribeOnline(
        promptId: promptId,
        referenceText: referenceText,
        filePath: filePath,
        generation: generation,
        service: service,
      );
      return;
    }

    // ── 阶段 3b：等待本机或平台转录结果 ──
    final result = await service.waitForTranscript(filePath: filePath);
    if (!_isCurrentRound(generation, promptId)) return;
    AppLogger.log(
      'SpeechRec',
      '│ transcript filePath=$filePath '
          'finalLen=${result.finalTranscript?.trim().length ?? 0} '
          'errorCode=${result.errorCode ?? '(null)'}',
    );
    AppLogger.log(
      'SpeechRec',
      '📋 final: "${result.finalTranscript ?? '(null)'}"',
    );

    // 判断是否有可用的转录结果（final 或 live）
    final hasTranscript =
        (result.isSuccess &&
            (result.finalTranscript?.trim().isNotEmpty ?? false)) ||
        (_lastKnownTranscript != null &&
            _lastKnownTranscript!.trim().isNotEmpty);

    if (hasTranscript) {
      _evaluateResult(
        promptId: promptId,
        referenceText: referenceText,
        result: result,
      );
    } else {
      AppLogger.log('SpeechRec', '✗ 无转录结果，保留录音');
      state = state.copyWith(
        phase: SpeechRecordingPhase.idle,
        currentAttempt: SpeechPracticeAttempt(promptId: promptId).copyWith(
          filePath: filePath,
          status: SpeechPracticeAttemptStatus.unavailable,
          score: 0,
        ),
        clearLiveTranscript: true,
        hasDetectedSpeech: false,
        silenceDuration: Duration.zero,
      );
    }
  }

  /// 同步评估录音结果并更新状态。
  void _evaluateResult({
    required String promptId,
    required String referenceText,
    required RecordingResult result,
  }) {
    if (!result.isSuccess) {
      // Final transcript 失败但有 live transcript → 用 live transcript 做评估
      final fallbackTranscript = _lastKnownTranscript;
      if (fallbackTranscript != null && fallbackTranscript.isNotEmpty) {
        AppLogger.log(
          'SpeechRec',
          '⚠ final transcript 失败 (${result.errorCode})，'
              '用 live transcript 评估: "$fallbackTranscript"',
        );
      } else {
        final attempt = SpeechPracticeAttempt(promptId: promptId).copyWith(
          filePath: result.filePath,
          status: _statusFromError(result.errorCode),
          errorMessage: result.errorMessage,
        );
        AppLogger.log('SpeechRec', '✗ 识别失败: ${result.errorCode ?? 'unknown'}');
        state = state.copyWith(
          phase: SpeechRecordingPhase.idle,
          currentAttempt: attempt,
          clearLiveTranscript: true,
          hasDetectedSpeech: false,
          silenceDuration: Duration.zero,
        );
        return;
      }
    }

    // 评估：仅覆盖率（优先用 final transcript，fallback 用 live transcript）
    final transcript = result.finalTranscript ?? _lastKnownTranscript ?? '';
    AppLogger.log(
      'SpeechRec',
      '│ evaluate transcriptLen=${transcript.trim().length} '
          'liveLen=${(_lastKnownTranscript ?? '').trim().length}',
    );
    _evaluateTranscript(
      promptId: promptId,
      referenceText: referenceText,
      filePath: result.filePath,
      transcript: transcript,
    );
  }

  /// 用一段最终文本做覆盖率评估；跟读的本机、系统与在线路径共用同一判定。
  void _evaluateTranscript({
    required String promptId,
    required String referenceText,
    required String? filePath,
    required String transcript,
  }) {
    final matcher = ref.read(speechTranscriptMatcherProvider);
    final matchResult = matcher.evaluate(
      referenceText: referenceText,
      transcript: transcript,
    );

    final attempt = SpeechPracticeAttempt(promptId: promptId).copyWith(
      filePath: filePath,
      status: matchResult.status,
      finalTranscript: matchResult.finalTranscript,
      score: matchResult.score,
      matchedTokenCount: matchResult.matchedTokenCount,
      totalTargetTokenCount: matchResult.totalTargetTokenCount,
      transcriptSegments: matchResult.transcriptSegments,
      referenceSegments: matchResult.referenceSegments,
    );

    if (attempt.isRecognitionFailure) {
      AppLogger.log(
        'SpeechRec',
        '✗ 识别失败: status=${attempt.status.name}, final="${attempt.finalTranscript ?? ''}"',
      );
    }

    AppLogger.log(
      'SpeechRec',
      '✓ 评估完成: '
          'status=${attempt.status.name}, '
          'score=${attempt.score?.toStringAsFixed(2)}, '
          'matched=${attempt.matchedTokenCount}/${attempt.totalTargetTokenCount}',
    );

    state = state.copyWith(
      phase: SpeechRecordingPhase.idle,
      currentAttempt: attempt,
      clearLiveTranscript: true,
      hasDetectedSpeech: false,
      silenceDuration: Duration.zero,
    );
  }

  /// 停录后的在线转写：单块内一次上传，超出单块范围按有界分块顺序上传。
  ///
  /// 录音期间不发请求；先释放麦克风再上传，结果或失败都只回写本回合；
  /// 取消、换录音或配置变更后旧回调不覆盖新状态，源录音始终保留。
  Future<void> _transcribeOnline({
    required String promptId,
    required String referenceText,
    required String filePath,
    required int generation,
    required RecordingService service,
  }) async {
    await service.shutdown();
    if (!_isCurrentRound(generation, promptId)) return;

    final access = await resolvePracticeOnlineAccess(
      ref,
      RecognitionPurpose.shadowing,
    );
    if (!_isCurrentRound(generation, promptId)) return;
    final granted = access is PracticeOnlineAccessGranted ? access : null;
    // 准入失败也要留下可见状态：服务与模型取自已保存配置，缺失时为空。
    final base = PracticeOnlineState(
      serviceHost: Uri.tryParse(granted?.config.baseUrl ?? '')?.host ?? '',
      modelId: granted?.modelId ?? '',
      phase: PracticeOnlinePhase.preparing,
    );
    state = state.copyWith(onlineShadowing: base);
    if (granted == null) {
      AppLogger.log('SpeechRec', '✗ 在线跟读不具备发请求条件: $access');
      _failOnlineTurn(promptId: promptId, filePath: filePath, error: access);
      return;
    }

    final transcriber = PracticeOnlineTranscriber(
      client: ref.read(speechTranscriptionClientProvider),
    );

    final PracticeRecordingAccess recording;
    try {
      recording = await transcriber.prepare(filePath);
    } on Object catch (error) {
      // 文件缺失或格式不支持：明确拒绝，不截断、不改成本机。
      if (!_isCurrentRound(generation, promptId)) return;
      AppLogger.log('SpeechRec', '✗ 在线跟读请求前拒绝: $error');
      _failOnlineTurn(promptId: promptId, filePath: filePath, error: error);
      return;
    }
    if (!_isCurrentRound(generation, promptId)) return;

    switch (recording) {
      case PracticeRecordingUpload():
        await _transcribeSingleUpload(
          promptId: promptId,
          referenceText: referenceText,
          filePath: filePath,
          generation: generation,
          base: base,
          granted: granted,
          transcriber: transcriber,
          upload: recording,
        );
      case PracticeRecordingNeedsChunking():
        // 超出单块范围：不截断也不只传开头，改走有界分块。
        await _transcribeChunked(
          promptId: promptId,
          referenceText: referenceText,
          filePath: filePath,
          generation: generation,
          base: base,
          granted: granted,
          knownDuration: recording.duration,
        );
    }
  }

  /// 单块范围内的录音：停录后只上传一次，成功后用该文本评估。
  Future<void> _transcribeSingleUpload({
    required String promptId,
    required String referenceText,
    required String filePath,
    required int generation,
    required PracticeOnlineState base,
    required PracticeOnlineAccessGranted granted,
    required PracticeOnlineTranscriber transcriber,
    required PracticeRecordingUpload upload,
  }) async {
    final cancelToken = CancelToken();
    _onlineCancelToken = cancelToken;
    state = state.copyWith(
      onlineShadowing: base.copyWith(
        phase: PracticeOnlinePhase.uploading,
        progress: 0,
      ),
    );
    try {
      final result = await transcriber.transcribe(
        config: granted.config,
        apiKey: granted.apiKey,
        modelId: granted.modelId,
        recording: upload,
        cancelToken: cancelToken,
        onProgress: (progress) {
          if (!_isCurrentRound(generation, promptId) ||
              !identical(_onlineCancelToken, cancelToken)) {
            return;
          }
          state = state.copyWith(
            onlineShadowing: state.onlineShadowing?.copyWith(
              progress: progress,
            ),
          );
        },
      );
      // 旧回合（取消、换录音）的结果不覆盖新状态。
      if (!_isCurrentRound(generation, promptId) ||
          !identical(_onlineCancelToken, cancelToken)) {
        return;
      }
      _onlineCancelToken = null;
      state = state.copyWith(
        onlineShadowing: base.copyWith(
          phase: PracticeOnlinePhase.completed,
          progress: 1,
          reportedCost: result.reportedCost,
        ),
      );
      AppLogger.log(
        'SpeechRec',
        '✓ 在线转写完成: textLen=${result.text.length} '
            'cost=${result.reportedCost ?? 'unknown'}',
      );
      _evaluateTranscript(
        promptId: promptId,
        referenceText: referenceText,
        filePath: filePath,
        transcript: result.text,
      );
    } on Object catch (error) {
      if (!_isCurrentRound(generation, promptId) ||
          !identical(_onlineCancelToken, cancelToken)) {
        return;
      }
      _onlineCancelToken = null;
      AppLogger.log('SpeechRec', '✗ 在线转写失败: $error');
      // 失败只说明原因并等用户操作：不自动重试、不换服务、不改成本机。
      _failOnlineTurn(promptId: promptId, filePath: filePath, error: error);
    }
  }

  /// 超出单块范围：按有界分块顺序上传，全部成功后用完整文本评估。
  ///
  /// 分块会话绑定本次尝试、录音与语音配置身份：[resume] 为真时只重发未完成块，
  /// 否则丢弃旧会话重新规划。失败停在当前块并保留未完成块供用户手动续试。
  Future<void> _transcribeChunked({
    required String promptId,
    required String referenceText,
    required String filePath,
    required int generation,
    required PracticeOnlineState base,
    required PracticeOnlineAccessGranted granted,
    Duration? knownDuration,
    bool resume = false,
  }) async {
    final transcriber = PracticeChunkTranscriber(
      client: ref.read(speechTranscriptionClientProvider),
      transcode: ref.read(localTranscriptionTranscodeServiceProvider),
    );
    var session = resume ? _chunkSession : null;
    // 录音或配置身份不同时不能把旧块拼进新结果。
    if (session != null &&
        (session.recordingPath != filePath ||
            session.identity != granted.identity)) {
      await _discardChunkSession();
      session = null;
    }
    if (!resume) await _discardChunkSession();

    final cancelToken = CancelToken();
    _onlineCancelToken = cancelToken;
    state = state.copyWith(
      onlineShadowing: base.copyWith(
        phase: PracticeOnlinePhase.uploading,
        progress: 0,
        completedChunks: session?.completedCount ?? 0,
        totalChunks: session?.chunks.length ?? 0,
      ),
    );
    try {
      session ??= await transcriber.plan(
        recordingPath: filePath,
        identity: granted.identity,
        audioDuration: knownDuration,
        isSessionValid: () => _isCurrentRound(generation, promptId),
        onSessionStarted: (id) => _onlineTranscodeSession = id,
      );
      _chunkSession = session;
      if (!_isCurrentRound(generation, promptId) ||
          !identical(_onlineCancelToken, cancelToken)) {
        return;
      }
      await transcriber.run(
        session: session,
        config: granted.config,
        apiKey: granted.apiKey,
        modelId: granted.modelId,
        cancelToken: cancelToken,
        isSessionValid: () => _isCurrentRound(generation, promptId),
        readCurrentIdentity: _currentOnlineIdentity,
        onSessionStarted: (id) => _onlineTranscodeSession = id,
        onProgress: (completed, total, current) {
          if (!_isCurrentRound(generation, promptId) ||
              !identical(_onlineCancelToken, cancelToken)) {
            return;
          }
          state = state.copyWith(
            onlineShadowing: base.copyWith(
              phase: PracticeOnlinePhase.uploading,
              progress: total == 0 ? 0 : completed / total,
              completedChunks: completed,
              totalChunks: total,
            ),
          );
        },
      );
      if (!_isCurrentRound(generation, promptId) ||
          !identical(_onlineCancelToken, cancelToken)) {
        return;
      }
      _onlineCancelToken = null;
      _onlineTranscodeSession = null;
      final text = session.text;
      state = state.copyWith(
        onlineShadowing: base.copyWith(
          phase: PracticeOnlinePhase.completed,
          progress: 1,
          reportedCost: session.reportedCost,
          completedChunks: session.completedCount,
          totalChunks: session.chunks.length,
        ),
      );
      AppLogger.log(
        'SpeechRec',
        '✓ 在线分块转写完成: chunks=${session.chunks.length} '
            'textLen=${text.length} cost=${session.reportedCost ?? 'unknown'}',
      );
      // 全部块成功：临时音频用完即删，评估只用完整文本。
      await _discardChunkSession();
      if (!_isCurrentRound(generation, promptId)) return;
      _evaluateTranscript(
        promptId: promptId,
        referenceText: referenceText,
        filePath: filePath,
        transcript: text,
      );
    } on PracticeChunkFailure catch (error) {
      if (!_isCurrentRound(generation, promptId) ||
          !identical(_onlineCancelToken, cancelToken)) {
        return;
      }
      _onlineCancelToken = null;
      _onlineTranscodeSession = null;
      if (error.reason == PracticeChunkFailureReason.cancelled) return;
      AppLogger.log('SpeechRec', '✗ 在线分块转写失败: $error');
      // 只有供应商请求失败才值得续试：无语音、解码失败与配置失效都不重发。
      final retryable =
          session != null &&
          error.reason == PracticeChunkFailureReason.requestFailed;
      if (!retryable) await _discardChunkSession();
      _failOnlineTurn(
        promptId: promptId,
        filePath: filePath,
        error: error,
        retryable: retryable,
        mayHaveBeenCharged: error.mayHaveBeenCharged,
        completedChunks: session?.completedCount ?? 0,
        totalChunks: session?.chunks.length ?? 0,
      );
    } on Object catch (error) {
      if (!_isCurrentRound(generation, promptId) ||
          !identical(_onlineCancelToken, cancelToken)) {
        return;
      }
      _onlineCancelToken = null;
      _onlineTranscodeSession = null;
      AppLogger.log('SpeechRec', '✗ 在线分块转写异常: $error');
      _failOnlineTurn(
        promptId: promptId,
        filePath: filePath,
        error: error,
        retryable: session != null,
        completedChunks: session?.completedCount ?? 0,
        totalChunks: session?.chunks.length ?? 0,
      );
    }
  }

  /// 手动续试本回合的分块转写：只重发未成功块，不自动重试也不跨尝试复用。
  ///
  /// 没有可续试的会话、录音已换或仍有在途回合时什么也不做；配置或验证失效
  /// 会清掉临时结果并只报告原因，换了服务/模型/凭据则重新规划而不是拼旧块。
  Future<void> retryOnlineTranscription({required String referenceText}) async {
    final session = _chunkSession;
    final promptId = state.promptId;
    final filePath = state.currentAttempt?.filePath;
    if (session == null ||
        promptId == null ||
        filePath == null ||
        filePath.isEmpty ||
        session.recordingPath != filePath ||
        state.phase != SpeechRecordingPhase.idle) {
      return;
    }
    final generation = _roundGeneration;
    final access = await resolvePracticeOnlineAccess(
      ref,
      RecognitionPurpose.shadowing,
    );
    if (!_isCurrentRound(generation, promptId)) return;
    final granted = access is PracticeOnlineAccessGranted ? access : null;
    final base = PracticeOnlineState(
      serviceHost: Uri.tryParse(granted?.config.baseUrl ?? '')?.host ?? '',
      modelId: granted?.modelId ?? '',
      phase: PracticeOnlinePhase.preparing,
    );
    if (granted == null) {
      await _discardChunkSession();
      _failOnlineTurn(promptId: promptId, filePath: filePath, error: access);
      return;
    }
    if (granted.identity != session.identity) {
      // 换了服务/模型/凭据：旧块不属于新配置，丢弃后重新规划。
      await _discardChunkSession();
    }
    state = state.copyWith(phase: SpeechRecordingPhase.processing);
    await _transcribeChunked(
      promptId: promptId,
      referenceText: referenceText,
      filePath: filePath,
      generation: generation,
      base: base,
      granted: granted,
      resume: true,
    );
  }

  /// 在线转写失败或拒绝：保留录音与原因，回到 idle 等用户决定。
  ///
  /// [retryable] 为真时保留未完成块，界面提供手动续试；[mayHaveBeenCharged]
  /// 为真时要如实提示失败块可能已被计费。
  void _failOnlineTurn({
    required String promptId,
    required String filePath,
    required Object error,
    bool retryable = false,
    bool mayHaveBeenCharged = false,
    int completedChunks = 0,
    int totalChunks = 0,
  }) {
    state = state.copyWith(
      phase: SpeechRecordingPhase.idle,
      currentAttempt: SpeechPracticeAttempt(promptId: promptId).copyWith(
        filePath: filePath,
        // 整段没有语音是识别结果的一种，不当作技术错误。
        status:
            error is PracticeChunkFailure &&
                error.reason == PracticeChunkFailureReason.noSpeech
            ? SpeechPracticeAttemptStatus.noEnglishDetected
            : SpeechPracticeAttemptStatus.error,
      ),
      onlineShadowing: state.onlineShadowing?.copyWith(
        phase: PracticeOnlinePhase.failed,
        error: error,
        retryable: retryable,
        mayHaveBeenCharged: mayHaveBeenCharged,
        completedChunks: completedChunks,
        totalChunks: totalChunks,
      ),
      clearLiveTranscript: true,
      hasDetectedSpeech: false,
      silenceDuration: Duration.zero,
    );
  }

  /// 取消在途的在线请求与分块转码，并丢弃本回合的分块临时结果。
  Future<void> _cancelOnlineTranscription() async {
    _onlineCancelToken?.cancel();
    _onlineCancelToken = null;
    final sessionId = _onlineTranscodeSession;
    _onlineTranscodeSession = null;
    if (sessionId != null) {
      ref
          .read(localTranscriptionTranscodeServiceProvider)
          .cancelSession(sessionId);
    }
    await _discardChunkSession();
  }

  /// 丢弃分块会话与临时音频：取消、换尝试与全部成功后都调用。
  Future<void> _discardChunkSession() async {
    final session = _chunkSession;
    _chunkSession = null;
    _onlineTranscodeSession = null;
    if (session == null) return;
    await session.discardTemp();
  }

  /// 当前跟读在线的配置身份；与分块会话身份不一致即表示配置已变化。
  Future<String?> _currentOnlineIdentity() async {
    final store = ref.read(speechConfigStoreProvider);
    final config = await store.read();
    if (config == null) return null;
    final modelId = config.onlineModelFor(RecognitionPurpose.shadowing);
    if (modelId.isEmpty) return null;
    return SpeechCapability.identityFor(
      kind: config.kind,
      baseUrl: config.baseUrl,
      modelId: modelId,
      credentialVersion: await store.readCredentialVersion(),
    );
  }

  void _recordCompletionDuration(Duration duration) {
    if (duration > Duration.zero) {
      _recordingCompletionHandler?.call(duration);
    }
  }

  bool _isCurrentRound(int generation, String promptId) =>
      generation == _roundGeneration && state.promptId == promptId;

  void _enterProcessing(String promptId) {
    if (state.promptId != promptId) return;
    _cancelAllTimers();
    state = state.copyWith(phase: SpeechRecordingPhase.processing);
  }

  // ── 事件处理 ──

  void _handleRecordingEvent(SpeechPracticeEvent event, int generation) {
    final promptId = state.promptId;
    if (promptId == null ||
        event.promptId != promptId ||
        !_isCurrentRound(generation, promptId)) {
      return;
    }
    if (_isStopping) return;
    if (state.phase != SpeechRecordingPhase.awaitingSpeech &&
        state.phase != SpeechRecordingPhase.speaking) {
      return;
    }

    switch (event.type) {
      case SpeechPracticeEventType.partialTranscriptUpdated:
        _handlePartialTranscript(event, generation);
      case SpeechPracticeEventType.speechStarted:
        _handleSpeechStarted(event, generation);
      case SpeechPracticeEventType.silenceProgress:
        _handleSilenceProgress(event, generation);
      case SpeechPracticeEventType.finalTranscriptReady ||
          SpeechPracticeEventType.error:
        break; // RecordingService 内部处理
    }
  }

  void _handlePartialTranscript(SpeechPracticeEvent event, int generation) {
    if (!_isCurrentRound(generation, event.promptId)) return;
    final text = (event.transcript ?? '').trim();
    final prevText = state.liveTranscript?.trim() ?? '';
    if (text.isNotEmpty && text != prevText) {
      AppLogger.log('SpeechRec', '📝 live: "$text"');
    }
    state = state.copyWith(
      liveTranscript: text,
      silenceDuration: Duration.zero,
    );

    _checkSpeechAndAutoStop(text, generation);
  }

  void _handleSpeechStarted(SpeechPracticeEvent event, int generation) {
    if (!_isCurrentRound(generation, event.promptId)) return;
    _speechStartTime ??= DateTime.now();
    _lastVoicedTimestamp ??= DateTime.now();
    state = state.copyWith(
      hasDetectedSpeech: true,
      silenceDuration: Duration.zero,
    );

    if (!_hasDetectedSpeech) {
      _handleSpeechDetected(state.promptId!, generation);
    }
  }

  void _handleSilenceProgress(SpeechPracticeEvent event, int generation) {
    if (!_isCurrentRound(generation, event.promptId)) return;
    final silence = event.silenceDuration ?? Duration.zero;
    state = state.copyWith(silenceDuration: silence);

    // 累加有声时长
    _updateVoicedDuration(silence);

    _checkAutoStopOnSilence(silence, generation);
  }

  /// 根据 silenceProgress 事件累加有声时长。
  ///
  /// 短静音（< [_voicedGapThreshold]）被视为语音的一部分，不结算有声段。
  /// 这是因为 VAD 基于 RMS 阈值，说话中的低音段可能被误判为静音。
  ///
  /// - silenceMs == 0：有声，累加时间差。
  /// - silenceMs > 0 但 < 阈值：不操作，等待恢复。
  /// - silenceMs >= 阈值：真正的静音，结算有声段（结束点 = now - silence）。
  static const _voicedGapThreshold = Duration(milliseconds: 500);

  void _updateVoicedDuration(Duration silence) {
    final now = DateTime.now();
    final lastVoiced = _lastVoicedTimestamp;

    if (silence == Duration.zero) {
      // 有声：累加自上次有声时间戳的差值
      if (lastVoiced != null) {
        _voicedDuration += now.difference(lastVoiced);
      }
      _lastVoicedTimestamp = now;
    } else if (silence >= _voicedGapThreshold && lastVoiced != null) {
      // 静音超过阈值：有声段结束于静音开始时刻
      final voicedEnd = now.subtract(silence);
      final diff = voicedEnd.difference(lastVoiced);
      if (diff > Duration.zero) {
        _voicedDuration += diff;
      }
      _lastVoicedTimestamp = null;
    }
    // silence > 0 但 < 阈值：VAD 抖动，不结算，等恢复
  }

  /// 检查语音检测 + 自动停止
  void _checkSpeechAndAutoStop(String liveText, int generation) {
    final promptId = state.promptId;
    if (promptId == null || !_isCurrentRound(generation, promptId)) return;

    final hasVoiceInput = state.hasDetectedSpeech || liveText.isNotEmpty;

    // 首次检测到语音
    if (!_hasDetectedSpeech && hasVoiceInput) {
      _handleSpeechDetected(promptId, generation);
    }

    if (_isManualMode || !_hasDetectedSpeech) return;

    // 转录停滞检测（通道 2）
    if (liveText.isNotEmpty && liveText != _lastKnownTranscript) {
      _lastKnownTranscript = liveText;
      _resetTranscriptStaleTimer(
        promptId: promptId,
        generation: generation,
        referenceText: _cachedReferenceText!,
        transcript: liveText,
      );
    }
  }

  /// 静音时的自动停止检测
  void _checkAutoStopOnSilence(Duration currentSilence, int generation) {
    final promptId = state.promptId;
    if (promptId == null ||
        !_isCurrentRound(generation, promptId) ||
        _isManualMode ||
        !_hasDetectedSpeech) {
      return;
    }

    final liveTranscript = state.liveTranscript?.trim() ?? '';
    final referenceText = _cachedReferenceText;
    if (referenceText == null) return;

    // ── 通道 1：声学静音 + 启发式 ──
    if (currentSilence > Duration.zero && liveTranscript.isNotEmpty) {
      final heuristic = ref.read(speechPracticeCompletionHeuristicProvider);
      final detailed = heuristic.computeSilenceThresholdDetailed(
        referenceText: referenceText,
        partialTranscript: liveTranscript,
        voicedDuration: _voicedDuration,
        referenceDuration: _referenceDuration,
      );
      final required = detailed.threshold!;
      if (detailed.description != _lastSilenceLogDesc) {
        _lastSilenceLogDesc = detailed.description;
        AppLogger.log(
          'SpeechRec',
          '静音阈值 ${required.inMilliseconds}ms | '
              '${detailed.description}',
        );
      }
      if (currentSilence >= required) {
        _stopForEvaluation(
          promptId: promptId,
          generation: generation,
          reason: '用户读完，静音${currentSilence.inMilliseconds}ms',
        );
        return;
      }
    }

    // 静音兜底（无转录时，含无 ASR 场景）
    final refDur = _referenceDuration;
    final fallback = (refDur != null)
        ? computeDynamicFallback(
            voicedDuration: _voicedDuration,
            referenceDuration: refDur,
          )
        : _defaultSilenceThreshold;
    if (currentSilence >= fallback) {
      final ratioDesc = (refDur != null && refDur > Duration.zero)
          ? ', ratio=${(_voicedDuration.inMilliseconds / (refDur.inMilliseconds * 1.1) * 100).toStringAsFixed(0)}%'
          : '';
      _stopForEvaluation(
        promptId: promptId,
        generation: generation,
        reason:
            '静音兜底 ${fallback.inSeconds}s '
            '(有声${_voicedDuration.inMilliseconds}ms, '
            'ref=${refDur?.inMilliseconds ?? 0}ms$ratioDesc)',
      );
    }
  }

  // ── 等待开口计时器 ──

  /// 60s 内未检测到语音 → 取消录音，回到 idle。
  void _scheduleAwaitingSpeechTimer(String promptId) {
    final generation = _roundGeneration;
    _awaitingSpeechTimer?.cancel();
    _awaitingSpeechTimer = Timer(_awaitingSpeechTimeout, () async {
      if (!_isCurrentRound(generation, promptId) ||
          state.phase != SpeechRecordingPhase.awaitingSpeech) {
        return;
      }
      AppLogger.log(
        'SpeechRec',
        '⏰ ${_awaitingSpeechTimeout.inSeconds}s 未检测到语音 → idle',
      );
      await cancelActiveRecording();
    });
  }

  /// 首次检测到语音的处理
  void _handleSpeechDetected(String promptId, int generation) {
    if (!_isCurrentRound(generation, promptId)) return;
    _hasDetectedSpeech = true;
    _awaitingSpeechTimer?.cancel();
    _awaitingSpeechTimer = null;

    // awaitingSpeech → speaking
    if (state.phase == SpeechRecordingPhase.awaitingSpeech) {
      AppLogger.log('SpeechRec', '🎤 检测到语音 → speaking');
      state = state.copyWith(phase: SpeechRecordingPhase.speaking);
    }

    final effectiveMaxDuration = _isManualMode
        ? _computeManualMaxDuration(_maxRecordingDuration)
        : _maxRecordingDuration;

    AppLogger.log(
      'SpeechRec',
      '│ 启动最大录音时长计时器: ${effectiveMaxDuration.inSeconds}s',
    );
    _scheduleMaxDurationTimer(
      promptId: promptId,
      generation: generation,
      maxDuration: effectiveMaxDuration,
    );
  }

  /// 转录停滞定时器：使用 [SpeechPracticeCompletionHeuristic] 计算阈值。
  void _resetTranscriptStaleTimer({
    required String promptId,
    required int generation,
    required String referenceText,
    required String transcript,
  }) {
    _transcriptStaleTimer?.cancel();

    final heuristic = ref.read(speechPracticeCompletionHeuristicProvider);
    final detailed = heuristic.computeSilenceThresholdDetailed(
      referenceText: referenceText,
      partialTranscript: transcript,
      voicedDuration: _voicedDuration,
      referenceDuration: _referenceDuration,
    );
    final threshold = detailed.threshold!;
    AppLogger.log(
      'SpeechRec',
      '转录停滞阈值 ${threshold.inMilliseconds}ms | '
          '${detailed.description}',
    );
    _transcriptStaleTimer = Timer(threshold, () {
      if (!_isCurrentRound(generation, promptId) || _isStopping) return;
      if (state.phase != SpeechRecordingPhase.speaking) return;
      _stopForEvaluation(
        promptId: promptId,
        generation: generation,
        reason: '转录停滞 ${threshold.inMilliseconds}ms',
      );
    });
  }

  // ── 最大录音时长 ──

  /// 手动模式最大录音时长：max(300s, 5 × 自动模式时长)
  static Duration _computeManualMaxDuration(Duration autoMaxDuration) {
    final computed = autoMaxDuration * _manualModeMultiplier;
    return computed > _manualModeInitialMax ? computed : _manualModeInitialMax;
  }

  void _scheduleMaxDurationTimer({
    required String promptId,
    required int generation,
    required Duration maxDuration,
  }) {
    _maxDurationTimer?.cancel();
    _maxDurationTimer = Timer(maxDuration, () {
      if (!_isCurrentRound(generation, promptId)) return;
      if (state.phase == SpeechRecordingPhase.awaitingSpeech ||
          state.phase == SpeechRecordingPhase.speaking) {
        AppLogger.log('SpeechRec', '⏰ 最大录音时长 ${maxDuration.inSeconds}s');
        _stopForEvaluation(
          promptId: promptId,
          generation: generation,
          reason: '最大录音时长',
        );
      }
    });
  }

  // ── 自动停止 ──

  void _stopForEvaluation({
    required String promptId,
    required int generation,
    String reason = '',
  }) {
    if (!_isCurrentRound(generation, promptId)) return;
    AppLogger.log('SpeechRec', '⏹ 自动停止录音 ($reason)');
    _isStopping = true;
    _cancelAllTimers();

    final referenceText = _cachedReferenceText;
    if (referenceText == null) {
      AppLogger.log('SpeechRec', '⚠ 无法获取 referenceText');
      return;
    }

    unawaited(
      _doStopAndEvaluate(
        promptId: promptId,
        referenceText: referenceText,
        generation: generation,
      ),
    );
  }

  // ── 生命周期 ──

  void _handleAppLifecycleChange(AppLifecycleState appState) {
    if (appState == AppLifecycleState.paused ||
        appState == AppLifecycleState.hidden) {
      AppLogger.log('SpeechRec', 'App 进入后台 → idle');
      _cancelAllTimers();
      unawaited(cancelActiveRecording());
      // 保留 currentAttempt（评级 badge）和 permissions
      state = SpeechRecordingState(
        phase: SpeechRecordingPhase.idle,
        permissions: state.permissions,
        currentAttempt: state.currentAttempt,
      );
    }
  }

  void _cancelAllTimers() {
    _awaitingSpeechTimer?.cancel();
    _awaitingSpeechTimer = null;
    _maxDurationTimer?.cancel();
    _maxDurationTimer = null;
    _transcriptStaleTimer?.cancel();
    _transcriptStaleTimer = null;
  }

  /// 判断错误码对应的 attempt 状态。
  SpeechPracticeAttemptStatus _statusFromError(String? code) {
    return switch (code) {
      'permissionDenied' => SpeechPracticeAttemptStatus.permissionDenied,
      'notAvailable' => SpeechPracticeAttemptStatus.unavailable,
      'noSpeech' => SpeechPracticeAttemptStatus.noEnglishDetected,
      _ => SpeechPracticeAttemptStatus.error,
    };
  }
}
