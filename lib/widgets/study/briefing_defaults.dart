/// 各类学习任务的「简报弹窗」参数适配：设置 → 弹窗显示值，弹窗改动 → 按槽位偏好。
///
/// 这些函数只服务 briefing sheet（速度/停顿/目标段长/可见词比例），被计划页、
/// 首次学习区块与复习区块共用，因此放在 study widget 层，避免组件反过来 import 页面。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/blind_listen_settings.dart';
import '../../models/difficult_practice_settings.dart';
import '../../models/intensive_listen_settings.dart';
import '../../models/retell_settings.dart' show KeywordRatio, RetellSettings;
import '../../models/stage_settings_overrides.dart';
import '../../providers/blind_listen_prefs_provider.dart';
import '../../providers/difficult_practice_prefs_provider.dart';
import '../../providers/intensive_listen_prefs_provider.dart';
import '../../providers/retell_prefs_provider.dart';
import '../common/paragraph_selection_sheet.dart' show paragraphDurationOptions;

/// 逐句精听入口弹窗的「停顿下拉显示值」← 已解析设置。
///
/// 仅作下拉的 UI 显示值,不承担持久化/传输(真相源是 [intensiveListenPrefsProvider])。
BriefingPauseChoice intensivePauseChoiceFromSettings(
  IntensiveListenSettings s,
) => switch (s.pauseMode) {
  PauseMode.smart => const BriefingPauseChoice.smart(),
  PauseMode.fixed => BriefingPauseChoice.fixed(s.fixedPauseSeconds),
  PauseMode.multiplier => BriefingPauseChoice.multiplier(s.pauseMultiplier),
};

/// 生成逐句精听入口弹窗的「改完即记」回调:用户在弹窗改速度/停顿时即时写入
/// [intensiveListenPrefsProvider](与 🔧 面板同一份 store,改完即持久,无需开始练习)。
///
/// 闭包跟踪上次值,仅写**真正变化的那个字段**:既支持来回改,又不会因改一个字段而
/// 把另一个未碰过的字段(智能默认)冻结。两个入口(按计划/自由练习)共用,行为一致。
void Function(double, BriefingPauseChoice) intensivePrefsRecorder(
  IntensiveListenPrefsNotifier notifier,
  String slot,
  IntensiveListenSettings resolved,
) {
  var lastSpeed = resolved.playbackSpeed;
  var lastPause = intensivePauseChoiceFromSettings(resolved);
  return (speed, pause) {
    if (speed != lastSpeed) {
      notifier.setPlaybackSpeed(slot, speed);
      lastSpeed = speed;
    }
    if (pause != lastPause) {
      switch (pause.mode) {
        case PauseMode.smart:
          notifier.setPauseMode(slot, PauseMode.smart);
        case PauseMode.fixed:
          notifier.setPauseMode(slot, PauseMode.fixed);
          notifier.setFixedPauseSeconds(slot, pause.fixedSeconds);
        case PauseMode.multiplier:
          notifier.setPauseMode(slot, PauseMode.multiplier);
          notifier.setPauseMultiplier(slot, pause.multiplier);
      }
      lastPause = pause;
    }
  };
}

/// 盲听入口弹窗的「停顿下拉显示值」← 已解析设置。
BriefingPauseChoice blindPauseChoiceFromSettings(BlindListenSettings s) =>
    switch (s.pauseMode) {
      PauseMode.smart => const BriefingPauseChoice.smart(),
      PauseMode.fixed => BriefingPauseChoice.fixed(s.fixedPauseSeconds),
      PauseMode.multiplier => BriefingPauseChoice.multiplier(s.pauseMultiplier),
    };

/// 难句补练 / 收藏句复习 入口的「停顿下拉显示值」← 已解析设置。
BriefingPauseChoice difficultPauseChoiceFromSettings(
  DifficultPracticeSettings s,
) => switch (s.pauseMode) {
  PauseMode.smart => const BriefingPauseChoice.smart(),
  PauseMode.fixed => BriefingPauseChoice.fixed(s.fixedPauseSeconds),
  PauseMode.multiplier => BriefingPauseChoice.multiplier(s.pauseMultiplier),
};

/// 段落复述 入口的「停顿下拉显示值」← 已解析设置。
BriefingPauseChoice retellPauseChoiceFromSettings(RetellSettings s) =>
    switch (s.pauseMode) {
      PauseMode.smart => const BriefingPauseChoice.smart(),
      PauseMode.fixed => BriefingPauseChoice.fixed(s.fixedPauseSeconds),
      PauseMode.multiplier => BriefingPauseChoice.multiplier(s.pauseMultiplier),
    };

/// 复述段落入口弹窗的预填:从按槽位偏好 resolve 出 速度/停顿/可见词比例/目标段长。
({
  int seconds,
  KeywordRatio ratio,
  double speed,
  BriefingPauseChoice pause,
  RetellSettings settings,
})
retellBriefingDefaults(
  WidgetRef ref,
  String slot, {
  required double smartSpeed,
  required KeywordRatio smartRatio,
  required int smartSeconds,
}) {
  final rp = ref.read(retellPrefsProvider.notifier);
  final settings = rp.resolve(
    slot,
    smartSpeed: smartSpeed,
    smartRatio: smartRatio,
  );
  final rawSeconds = rp.resolveTargetSeconds(slot, smartSeconds: smartSeconds);
  // 目标段长须落在合法档位内,否则下拉 value 不在 items 会断言。
  final seconds = paragraphDurationOptions.contains(rawSeconds)
      ? rawSeconds
      : smartSeconds;
  return (
    seconds: seconds,
    ratio: settings.keywordRatio,
    speed: settings.playbackSpeed,
    pause: retellPauseChoiceFromSettings(settings),
    settings: settings,
  );
}

/// 盲听入口「改完即记」回调:改速度/停顿即时写按槽位偏好(跟踪上次值,仅写变化字段,
/// 支持回退到默认)。供按计划/自由练习各入口共用。
void Function(Duration, BriefingPauseChoice, double) blindPrefsRecorder(
  WidgetRef ref,
  String slot,
  BlindListenSettings defaults,
  int defaultSeconds,
) {
  final n = ref.read(blindListenPrefsProvider.notifier);
  var lastPause = blindPauseChoiceFromSettings(defaults);
  var lastSpeed = defaults.playbackSpeed;
  var lastSeconds = defaultSeconds;
  return (duration, pause, speed) {
    if (speed != lastSpeed) {
      n.setPlaybackSpeed(slot, speed);
      lastSpeed = speed;
    }
    if (pause != lastPause) {
      switch (pause.mode) {
        case PauseMode.smart:
          n.setPauseMode(slot, PauseMode.smart);
        case PauseMode.fixed:
          n.setPauseMode(slot, PauseMode.fixed);
          n.setFixedPauseSeconds(slot, pause.fixedSeconds);
        case PauseMode.multiplier:
          n.setPauseMode(slot, PauseMode.multiplier);
          n.setPauseMultiplier(slot, pause.multiplier);
      }
      lastPause = pause;
    }
    final seconds = duration.inHours >= 24 ? -1 : duration.inSeconds;
    if (seconds != lastSeconds && paragraphDurationOptions.contains(seconds)) {
      n.setTargetSeconds(slot, seconds);
      lastSeconds = seconds;
    }
  };
}

/// 难句补练入口「改完即记」回调(速度/停顿)。
void Function(double, BriefingPauseChoice) difficultPrefsRecorder(
  WidgetRef ref,
  String slot,
  DifficultPracticeSettings defaults,
) {
  final n = ref.read(difficultPracticePrefsProvider.notifier);
  var lastPause = difficultPauseChoiceFromSettings(defaults);
  var lastSpeed = defaults.playbackSpeed;
  return (speed, pause) {
    if (speed != lastSpeed) {
      n.setPlaybackSpeed(slot, speed);
      lastSpeed = speed;
    }
    if (pause != lastPause) {
      switch (pause.mode) {
        case PauseMode.smart:
          n.setPauseMode(slot, PauseMode.smart);
        case PauseMode.fixed:
          n.setPauseMode(slot, PauseMode.fixed);
          n.setFixedPauseSeconds(slot, pause.fixedSeconds);
        case PauseMode.multiplier:
          n.setPauseMode(slot, PauseMode.multiplier);
          n.setPauseMultiplier(slot, pause.multiplier);
      }
      lastPause = pause;
    }
  };
}

/// 全文复述(复习简报)「改完即记」回调(仅速度/停顿)。
void Function(double, BriefingPauseChoice) retellPauseSpeedRecorder(
  WidgetRef ref,
  String slot,
  RetellSettings defaults,
) {
  final n = ref.read(retellPrefsProvider.notifier);
  var lastPause = retellPauseChoiceFromSettings(defaults);
  var lastSpeed = defaults.playbackSpeed;
  return (speed, pause) {
    if (speed != lastSpeed) {
      n.setPlaybackSpeed(slot, speed);
      lastSpeed = speed;
    }
    if (pause != lastPause) {
      switch (pause.mode) {
        case PauseMode.smart:
          n.setPauseMode(slot, PauseMode.smart);
        case PauseMode.fixed:
          n.setPauseMode(slot, PauseMode.fixed);
          n.setFixedPauseSeconds(slot, pause.fixedSeconds);
        case PauseMode.multiplier:
          n.setPauseMode(slot, PauseMode.multiplier);
          n.setPauseMultiplier(slot, pause.multiplier);
      }
      lastPause = pause;
    }
  };
}

/// 复述入口「改完即记」回调(目标段长/停顿/可见词比例/速度)。
void Function(Duration, BriefingPauseChoice, KeywordRatio?, double)
retellPrefsRecorder(WidgetRef ref, String slot, RetellSettings defaults) {
  final n = ref.read(retellPrefsProvider.notifier);
  var lastPause = retellPauseChoiceFromSettings(defaults);
  var lastSpeed = defaults.playbackSpeed;
  var lastRatio = defaults.keywordRatio;
  int? lastSeconds;
  return (duration, pause, ratio, speed) {
    if (speed != lastSpeed) {
      n.setPlaybackSpeed(slot, speed);
      lastSpeed = speed;
    }
    if (pause != lastPause) {
      switch (pause.mode) {
        case PauseMode.smart:
          n.setPauseMode(slot, PauseMode.smart);
        case PauseMode.fixed:
          n.setPauseMode(slot, PauseMode.fixed);
          n.setFixedPauseSeconds(slot, pause.fixedSeconds);
        case PauseMode.multiplier:
          n.setPauseMode(slot, PauseMode.multiplier);
          n.setPauseMultiplier(slot, pause.multiplier);
      }
      lastPause = pause;
    }
    if (ratio != null && ratio != lastRatio) {
      n.setKeywordRatio(slot, ratio);
      lastRatio = ratio;
    }
    final seconds = duration.inHours >= 24 ? -1 : duration.inSeconds;
    if (seconds != lastSeconds && paragraphDurationOptions.contains(seconds)) {
      n.setTargetSeconds(slot, seconds);
      lastSeconds = seconds;
    }
  };
}
