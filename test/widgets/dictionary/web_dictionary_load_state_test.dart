import 'package:loop_back/widgets/dictionary/web_dictionary_load_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WebDictionaryLoadState', () {
    test('首次导航显示加载态', () {
      final state = WebDictionaryLoadState.initial('https://example.com/word');

      expect(state.phase, WebDictionaryLoadPhase.loading);
      expect(state.isLoading, isTrue);
      expect(state.generation, 0);
    });

    test('可见提交先于加载结束，立即进入 ready', () {
      final state = WebDictionaryLoadState.initial(
        'https://example.com/word',
      ).pageCommitted('https://example.com/word');

      expect(state.phase, WebDictionaryLoadPhase.ready);
      expect(state.isLoading, isFalse);
    });

    test('load stop 可兜底结束没有可见提交事件的导航', () {
      final state = WebDictionaryLoadState.initial(
        'https://example.com/word',
      ).loadStopped('https://example.com/word');

      expect(state.phase, WebDictionaryLoadPhase.ready);
    });

    test('主框架失败进入 error', () {
      final state = WebDictionaryLoadState.initial(
        'https://example.com/word',
      ).loadFailed('https://example.com/word');

      expect(state.phase, WebDictionaryLoadPhase.error);
    });

    test('新导航清除错误并增加代际', () {
      final state = WebDictionaryLoadState.initial('https://example.com/old')
          .loadFailed('https://example.com/old')
          .navigationStarted('https://example.com/new');

      expect(state.phase, WebDictionaryLoadPhase.loading);
      expect(state.generation, 1);
      expect(state.activeUrl, 'https://example.com/new');
    });

    test('重试保留当前 URL 并使旧计时器失效', () {
      final state = WebDictionaryLoadState.initial(
        'https://example.com/word',
      ).loadFailed('https://example.com/word').retryStarted();

      expect(state.phase, WebDictionaryLoadPhase.loading);
      expect(state.generation, 1);
      expect(state.activeUrl, 'https://example.com/word');
      expect(state.timedOut(0).phase, WebDictionaryLoadPhase.loading);
    });

    test('旧 URL 的加载结束或错误不覆盖新导航状态', () {
      final state = WebDictionaryLoadState.initial(
        'https://example.com/old',
      ).navigationStarted('https://example.com/new');

      expect(
        identical(state.loadStopped('https://example.com/old'), state),
        isTrue,
      );
      expect(
        identical(state.loadFailed('https://example.com/old'), state),
        isTrue,
      );
    });

    test('超时仅结束对应代际的加载态', () {
      final state = WebDictionaryLoadState.initial(
        'https://example.com/word',
      ).navigationStarted('https://example.com/word');

      expect(state.timedOut(0).phase, WebDictionaryLoadPhase.loading);
      expect(state.timedOut(1).phase, WebDictionaryLoadPhase.error);
    });

    test('内容提交后超时不改变 ready 状态', () {
      final state = WebDictionaryLoadState.initial(
        'https://example.com/word',
      ).pageCommitted('https://example.com/word');

      expect(state.timedOut(0).phase, WebDictionaryLoadPhase.ready);
    });
  });
}
