/// 按用途（字幕 / 跟读 / 复述）维护识别方式与模型的单一状态入口。
///
/// 每个用途各自保存方式与模型，设置页、字幕入口与三条业务入口都读这份状态。
/// 各用途的存储位置不同，但语义只有这一份：
/// - 字幕：本机模型沿用旧偏好 `local_transcription_model_id`，由
///   [localTranscriptionModelProvider] 持有；方式在 [subtitleModePrefsKey] 保存，
///   默认本机，在线只在当前配置通过字幕能力验证后可选。
/// - 跟读：本机 / 系统方式与模型沿用离线 ASR 设置（共享本机引擎的档位与后端），
///   由 [offlineAsrSettingsProvider] 持有唯一来源，避免引擎档位出现第二份真相；
///   只有选用在线时额外记一份在线标记，在线模型由语音配置按用途保存。
/// - 复述：独立偏好，首次建立时继承升级前实际字幕模型并快照下来。
///
/// 修改会影响在途任务的选择时，先返回受影响任务让界面告知用户；只有用户接受
/// （[RecognitionChangeResult.applied] 为 true 的第二次调用）才取消这些任务。
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/onboarding_survey/providers/onboarding_survey_provider.dart'
    show sharedPreferencesProvider;
import '../models/recognition_selection.dart';
import '../services/asr/asr_model_manager.dart' show availableModels;
import '../services/asr/offline_asr_engine.dart' show AsrModelInfo;
import 'local_transcription_model_provider.dart';
import 'offline_asr_settings_provider.dart';

/// 复述识别方式偏好 key。
const retellModePrefsKey = 'recognition_retell_mode';

/// 复述本机模型偏好 key。
const retellModelPrefsKey = 'recognition_retell_model_id';

/// 字幕识别方式偏好 key；只持久化「在线」与「本机」（本机为默认）。
const subtitleModePrefsKey = 'recognition_subtitle_mode';

/// 跟读选用在线方式时的偏好 key。
///
/// 只有「在线」需要额外记录：本机与系统方式继续由离线 ASR 设置的唯一档位
/// 决定，避免同一选择存两份。
const shadowingOnlinePrefsKey = 'recognition_shadowing_online';

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

/// 三个用途的识别选择快照。
class RecognitionSettings {
  const RecognitionSettings({
    required this.subtitle,
    required this.shadowing,
    required this.retell,
  });

  final RecognitionSelection subtitle;
  final RecognitionSelection shadowing;
  final RecognitionSelection retell;

  /// 取指定用途的选择。
  RecognitionSelection forPurpose(RecognitionPurpose purpose) =>
      switch (purpose) {
        RecognitionPurpose.subtitle => subtitle,
        RecognitionPurpose.shadowing => shadowing,
        RecognitionPurpose.retell => retell,
      };

  RecognitionSettings withPurpose(
    RecognitionPurpose purpose,
    RecognitionSelection selection,
  ) => switch (purpose) {
    RecognitionPurpose.subtitle => RecognitionSettings(
      subtitle: selection,
      shadowing: shadowing,
      retell: retell,
    ),
    RecognitionPurpose.shadowing => RecognitionSettings(
      subtitle: subtitle,
      shadowing: selection,
      retell: retell,
    ),
    RecognitionPurpose.retell => RecognitionSettings(
      subtitle: subtitle,
      shadowing: shadowing,
      retell: selection,
    ),
  };
}

/// 识别选择变更结果。
class RecognitionChangeResult {
  const RecognitionChangeResult._({required this.applied, this.affectedTasks});

  /// 变更已应用。
  const RecognitionChangeResult.applied()
    : this._(applied: true, affectedTasks: null);

  /// 有受影响的在途任务，需要用户确认后才应用。
  const RecognitionChangeResult.needsConfirmation(
    List<RecognitionInFlightTask> tasks,
  ) : this._(applied: false, affectedTasks: tasks);

  /// 选择是否已生效。
  final bool applied;

  /// 受影响的在途任务；已生效或无需确认时为 null。
  final List<RecognitionInFlightTask>? affectedTasks;
}

// ---------------------------------------------------------------------------
// 在途任务
// ---------------------------------------------------------------------------

/// 一条正在使用识别结果的在途任务。
///
/// 业务入口（字幕转录、跟读录音、复述录音）在真正开始识别时登记、结束时注销；
/// 识别设置据此在变更前告知并取消受影响任务。
class RecognitionInFlightTask {
  RecognitionInFlightTask({
    required this.purpose,
    required this.label,
    required this.onCancel,
  });

  final RecognitionPurpose purpose;

  /// 界面提示用的任务描述（材料 id 等），不含音频内容。
  final String label;

  /// 取消该任务：停止后续识别并清理临时结果。
  final Future<void> Function() onCancel;

  bool _cancelled = false;

  /// 是否已被设置变更取消。
  bool get isCancelled => _cancelled;

  void _cancel() {
    if (_cancelled) return;
    _cancelled = true;
  }
}

/// 在途任务登记处。
class RecognitionInFlightRegistry {
  final List<RecognitionInFlightTask> _tasks = [];

  /// 登记一条在途任务。
  void register(RecognitionInFlightTask task) => _tasks.add(task);

  /// 注销一条在途任务（任务正常结束后调用）。
  void unregister(RecognitionInFlightTask task) => _tasks.remove(task);

  /// 指定用途下仍在进行的任务。
  List<RecognitionInFlightTask> pendingFor(RecognitionPurpose purpose) => [
    for (final task in _tasks)
      if (task.purpose == purpose && !task.isCancelled) task,
  ];
}

/// 在途识别任务登记处（进程内单例）。
final recognitionInFlightTasksProvider = Provider<RecognitionInFlightRegistry>(
  (ref) => RecognitionInFlightRegistry(),
);

// ---------------------------------------------------------------------------
// 平台能力
// ---------------------------------------------------------------------------

/// 当前平台是否提供系统语音识别（Apple 的 SFSpeechRecognizer）。
final systemRecognitionPlatformProvider = Provider<bool>(
  (ref) => !kIsWeb && (Platform.isIOS || Platform.isMacOS),
);

/// 某用途当前可选的识别方式。
///
/// 字幕需要片段时间戳：系统识别不提供，只有当前配置通过字幕能力验证后
/// （[onlineSubtitleAvailable]）才出现在线方式。跟读与复述在受支持的平台同时
/// 开放系统识别；两者的在线方式各自需要自己用途的文本能力验证
/// （[onlineAvailable]），互不借用。
List<RecognitionMode> availableRecognitionModes(
  RecognitionPurpose purpose, {
  required bool systemSupported,
  bool onlineSubtitleAvailable = false,
  bool onlineAvailable = false,
}) {
  if (purpose == RecognitionPurpose.subtitle) {
    return [
      RecognitionMode.local,
      if (onlineSubtitleAvailable) RecognitionMode.online,
    ];
  }
  return [
    RecognitionMode.local,
    if (systemSupported) RecognitionMode.system,
    if (onlineAvailable) RecognitionMode.online,
  ];
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

/// 某用途当前使用的本机档位。
///
/// 本机方式的唯一解析入口：字幕与跟读直接复用各自偏好的档位对象，复述按已存
/// 档位 id 解析。id 不可识别时回退到首个可用档位，不静默当成已下载模型使用。
final recognitionLocalModelProvider =
    Provider.family<AsrModelInfo, RecognitionPurpose>((ref, purpose) {
      return switch (purpose) {
        RecognitionPurpose.subtitle => ref.watch(
          localTranscriptionModelProvider,
        ),
        RecognitionPurpose.shadowing => ref.watch(
          offlineAsrSettingsProvider.select((state) => state.selectedModel),
        ),
        RecognitionPurpose.retell => modelById(
          ref.watch(
            recognitionSettingsProvider.select((s) => s.retell.localModelId),
          ),
        ),
      };
    });

/// 按档位 id 取模型信息；id 不可识别时回退到首个可用档位。
AsrModelInfo modelById(String modelId) => availableModels.firstWhere(
  (model) => model.id == modelId,
  orElse: () => availableModels.first,
);

/// 三用途识别选择（keepAlive 全局单例）。
final recognitionSettingsProvider =
    NotifierProvider<RecognitionSettingsNotifier, RecognitionSettings>(
      RecognitionSettingsNotifier.new,
    );

/// 按用途维护识别选择。
class RecognitionSettingsNotifier extends Notifier<RecognitionSettings> {
  @override
  RecognitionSettings build() {
    final prefs = ref.read(sharedPreferencesProvider);
    final subtitleModelId = ref.watch(
      localTranscriptionModelProvider.select((model) => model.id),
    );
    final shadowingMode = ref.watch(
      offlineAsrSettingsProvider.select((state) => state.backend),
    );
    final shadowingModelId = ref.watch(
      offlineAsrSettingsProvider.select((state) => state.selectedModel.id),
    );

    final retellModelId = _resolveRetellModelId(prefs, subtitleModelId);
    final retellMode = _modeFromPrefs(prefs.getString(retellModePrefsKey));
    final subtitleMode =
        prefs.getString(subtitleModePrefsKey) == RecognitionMode.online.name
        ? RecognitionMode.online
        : RecognitionMode.local;
    // 跟读在线是一个显式的额外选择；未选在线时继续由离线 ASR 档位决定。
    final shadowingOnline =
        prefs.getString(shadowingOnlinePrefsKey) ==
        RecognitionMode.online.name;
    return RecognitionSettings(
      subtitle: RecognitionSelection(
        mode: subtitleMode,
        localModelId: subtitleModelId,
      ),
      shadowing: shadowingOnline
          ? RecognitionSelection.online(localModelId: shadowingModelId)
          : shadowingMode == AsrBackend.offline
          ? RecognitionSelection.local(shadowingModelId)
          : RecognitionSelection(
              mode: RecognitionMode.system,
              localModelId: shadowingModelId,
            ),
      retell: RecognitionSelection(
        mode: retellMode,
        localModelId: retellModelId,
      ),
    );
  }

  /// 复述本机模型：已建立偏好则沿用；首次建立时继承升级前实际字幕模型并快照。
  String _resolveRetellModelId(
    SharedPreferences prefs,
    String subtitleModelId,
  ) {
    final persisted = prefs.getString(retellModelPrefsKey);
    if (persisted != null) return persisted;
    // 快照写入本机偏好，避免之后修改字幕模型把复述一起带走。
    unawaited(prefs.setString(retellModelPrefsKey, subtitleModelId));
    return subtitleModelId;
  }

  /// 重启后恢复复述方式；未知值回退到本机，不把旧偏好当成在线。
  static RecognitionMode _modeFromPrefs(String? raw) => switch (raw) {
    'system' => RecognitionMode.system,
    'online' => RecognitionMode.online,
    _ => RecognitionMode.local,
  };

  /// 修改某用途的识别选择。
  ///
  /// 有受该用途影响的在途任务且 [cancelInFlight] 为 false 时，返回
  /// [RecognitionChangeResult.needsConfirmation]，配置与任务都保持不变，由界面
  /// 告知用户；用户接受后带 [cancelInFlight] 重新调用，才取消受影响任务并应用
  /// 变更。其它用途的任务不受影响。
  Future<RecognitionChangeResult> change({
    required RecognitionPurpose purpose,
    required RecognitionSelection selection,
    bool cancelInFlight = false,
  }) async {
    if (state.forPurpose(purpose) == selection) {
      return const RecognitionChangeResult.applied();
    }

    final registry = ref.read(recognitionInFlightTasksProvider);
    final affected = registry.pendingFor(purpose);
    if (affected.isNotEmpty && !cancelInFlight) {
      return RecognitionChangeResult.needsConfirmation(affected);
    }
    for (final task in affected) {
      task._cancel();
      await task.onCancel();
      registry.unregister(task);
    }

    switch (purpose) {
      case RecognitionPurpose.subtitle:
        final prefs = ref.read(sharedPreferencesProvider);
        state = state.withPurpose(purpose, selection);
        await prefs.setString(subtitleModePrefsKey, selection.mode.name);
        if (selection.usesLocalModel) {
          await ref
              .read(localTranscriptionModelProvider.notifier)
              .select(modelById(selection.localModelId));
        }
      case RecognitionPurpose.shadowing:
        final prefs = ref.read(sharedPreferencesProvider);
        if (selection.usesOnlineModel) {
          // 在线不改变离线 ASR 档位：用户切回本机时沿用原选择。
          state = state.withPurpose(purpose, selection);
          await prefs.setString(
            shadowingOnlinePrefsKey,
            RecognitionMode.online.name,
          );
        } else {
          await prefs.remove(shadowingOnlinePrefsKey);
          final backend = selection.usesLocalModel
              ? AsrBackend.offline
              : AsrBackend.platform;
          // 档位没变时不重复触发下载/引擎初始化。
          final modelChanged =
              selection.usesLocalModel &&
              selection.localModelId != state.shadowing.localModelId;
          await ref
              .read(offlineAsrSettingsProvider.notifier)
              .setBackend(backend);
          if (modelChanged) {
            await ref
                .read(offlineAsrSettingsProvider.notifier)
                .selectModel(modelById(selection.localModelId));
          }
        }
        state = state.withPurpose(purpose, selection);
      case RecognitionPurpose.retell:
        final prefs = ref.read(sharedPreferencesProvider);
        state = state.withPurpose(purpose, selection);
        await prefs.setString(retellModePrefsKey, selection.mode.name);
        // 系统方式保留已存的本机档位，切回本机时不用重选。
        if (selection.usesLocalModel) {
          await prefs.setString(retellModelPrefsKey, selection.localModelId);
        }
    }
    return const RecognitionChangeResult.applied();
  }

}
