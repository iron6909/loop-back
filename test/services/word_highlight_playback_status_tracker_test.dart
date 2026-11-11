import 'package:loop_back/models/word_highlight_binding.dart';
import 'package:loop_back/services/word_highlight_playback_status_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late WordHighlightPlaybackStatusTracker tracker;

  setUp(() {
    tracker = WordHighlightPlaybackStatusTracker();
  });

  tearDown(() async {
    await tracker.dispose();
  });

  test('idle、playing、paused 与 completed 控制高亮生命周期', () {
    expect(tracker.status, WordHighlightPlaybackStatus.idle);
    expect(tracker.status.allowsHighlight, isFalse);

    tracker.observePlayerState(isPlaying: true, isCompleted: false);
    expect(tracker.status, WordHighlightPlaybackStatus.playing);
    expect(tracker.status.allowsHighlight, isTrue);

    tracker.observePlayerState(isPlaying: false, isCompleted: false);
    expect(tracker.status, WordHighlightPlaybackStatus.paused);
    expect(tracker.status.allowsHighlight, isTrue);

    tracker.observePlayerState(isPlaying: false, isCompleted: true);
    expect(tracker.status, WordHighlightPlaybackStatus.completed);
    expect(tracker.status.allowsHighlight, isFalse);

    // 播放器随后发出的暂停态不能覆盖已经确认的自然结束。
    tracker.markPaused();
    expect(tracker.status, WordHighlightPlaybackStatus.completed);
  });

  test('自然结束后定位恢复高亮并忽略旧完成态', () {
    tracker.markCompleted();
    tracker.markPositionSelected(ignoreCurrentCompletion: true);
    expect(tracker.status, WordHighlightPlaybackStatus.paused);

    tracker.observePlayerState(isPlaying: false, isCompleted: true);
    expect(tracker.status, WordHighlightPlaybackStatus.paused);

    tracker.reset();
    expect(tracker.status, WordHighlightPlaybackStatus.idle);
  });

  test('播放器仍在播放时忽略滞后的 completed 标记', () {
    tracker.markCompleted();

    tracker.observePlayerState(isPlaying: true, isCompleted: true);

    expect(tracker.status, WordHighlightPlaybackStatus.playing);
  });

  test('配置新播放区间时暂时关闭高亮，取消时恢复暂停高亮', () {
    tracker.markPlaying();

    tracker.prepareForPlayback();
    expect(tracker.status, WordHighlightPlaybackStatus.idle);

    tracker.markPaused();
    expect(tracker.status, WordHighlightPlaybackStatus.paused);
  });
}
