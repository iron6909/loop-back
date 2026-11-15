import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/services/cache_cleanup_service.dart';

void main() {
  /// 记录执行顺序与失败注入。
  late List<String> steps;

  CacheCleanupService build({
    int rows = 0,
    Map<String, int> freed = const {},
    Set<String> throwing = const {},
  }) {
    Future<int> step(String name, int bytes) async {
      steps.add(name);
      if (throwing.contains(name)) throw StateError('$name failed');
      return bytes;
    }

    return CacheCleanupService(
      clearAiCacheRows: () => step('aiCacheRows', rows),
      clearAiMemoryCaches: () {
        steps.add('aiMemoryCaches');
        if (throwing.contains('aiMemoryCaches')) {
          throw StateError('aiMemoryCaches failed');
        }
      },
      clearTempFiles: () => step('tempFiles', freed['tempFiles'] ?? 0),
      clearNetworkImages: () =>
          step('networkImages', freed['networkImages'] ?? 0),
      clearUnusedDictionaries: () =>
          step('dictionaries', freed['dictionaries'] ?? 0),
      clearOrphanMediaFiles: () =>
          step('orphanMedia', freed['orphanMedia'] ?? 0),
      clearWaveforms: () => step('waveforms', freed['waveforms'] ?? 0),
      clearTtsCache: () => step('ttsCache', freed['ttsCache'] ?? 0),
    );
  }

  setUp(() => steps = <String>[]);

  test('汇总各步骤释放字节数与索引行数', () async {
    final result = await build(
      rows: 12,
      freed: {
        'tempFiles': 100,
        'networkImages': 200,
        'dictionaries': 300,
        'orphanMedia': 400,
        'waveforms': 500,
        'ttsCache': 600,
      },
    ).run();

    expect(result.deletedIndexRows, 12);
    expect(result.freedBytes, 2100);
    expect(result.isEmpty, isFalse);
  });

  test('先清索引与内存缓存，再清磁盘产物', () async {
    await build(freed: {'tempFiles': 1}).run();

    expect(steps, [
      'aiCacheRows',
      'aiMemoryCaches',
      'tempFiles',
      'networkImages',
      'dictionaries',
      'orphanMedia',
      'waveforms',
      'ttsCache',
    ]);
  });

  test('单步失败不影响后续步骤，失败步骤计 0', () async {
    final result = await build(
      rows: 3,
      freed: {'tempFiles': 100, 'waveforms': 500, 'ttsCache': 600},
      throwing: {'dictionaries', 'aiMemoryCaches'},
    ).run();

    // 词典步骤失败但波形与 TTS 仍然执行。
    expect(steps, contains('waveforms'));
    expect(steps, contains('ttsCache'));
    expect(result.freedBytes, 1200);
    expect(result.deletedIndexRows, 3);
  });

  test('全空时 isEmpty 为 true', () async {
    final result = await build().run();

    expect(result.isEmpty, isTrue);
  });
}
