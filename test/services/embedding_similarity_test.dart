import 'dart:math' as math;

import 'package:loop_back/services/embedding_similarity.dart';
import 'package:loop_back/services/text_embedding_platform.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockTextEmbeddingBackend extends Mock implements TextEmbeddingBackend {}

void main() {
  group('EmbeddingSimilarity.cosineSimilarity', () {
    test('相同向量返回 1.0', () {
      final v = [1.0, 2.0, 3.0];
      expect(EmbeddingSimilarity.cosineSimilarity(v, v), closeTo(1.0, 1e-10));
    });

    test('正交向量返回 0.0', () {
      final a = [1.0, 0.0];
      final b = [0.0, 1.0];
      expect(EmbeddingSimilarity.cosineSimilarity(a, b), closeTo(0.0, 1e-10));
    });

    test('反向向量返回 -1.0', () {
      final a = [1.0, 2.0, 3.0];
      final b = [-1.0, -2.0, -3.0];
      expect(EmbeddingSimilarity.cosineSimilarity(a, b), closeTo(-1.0, 1e-10));
    });

    test('空向量返回 0.0', () {
      expect(EmbeddingSimilarity.cosineSimilarity([], []), 0.0);
      expect(EmbeddingSimilarity.cosineSimilarity([], [1.0]), 0.0);
      expect(EmbeddingSimilarity.cosineSimilarity([1.0], []), 0.0);
    });

    test('维度不匹配返回 0.0', () {
      expect(
        EmbeddingSimilarity.cosineSimilarity([1.0, 2.0], [1.0, 2.0, 3.0]),
        0.0,
      );
    });

    test('零向量返回 0.0', () {
      expect(EmbeddingSimilarity.cosineSimilarity([0.0, 0.0], [1.0, 2.0]), 0.0);
    });

    test('已知向量对返回预期值', () {
      final a = [1.0, 0.0, 1.0];
      final b = [0.0, 1.0, 1.0];
      // dot = 1, normA = sqrt(2), normB = sqrt(2), similarity = 1/2 = 0.5
      expect(EmbeddingSimilarity.cosineSimilarity(a, b), closeTo(0.5, 1e-10));
    });

    test('45 度角向量返回 cos(45°)', () {
      final a = [1.0, 0.0];
      final b = [1.0, 1.0];
      // cos(45°) = 1/sqrt(2) ≈ 0.7071
      expect(
        EmbeddingSimilarity.cosineSimilarity(a, b),
        closeTo(1.0 / math.sqrt(2), 1e-10),
      );
    });
  });

  group('EmbeddingSimilarity.computeSimilarity', () {
    late MockTextEmbeddingBackend mockBackend;
    late EmbeddingSimilarity similarity;

    setUp(() {
      mockBackend = MockTextEmbeddingBackend();
      similarity = EmbeddingSimilarity(backend: mockBackend);
    });

    test('平台不支持时返回 0.0', () async {
      when(() => mockBackend.isSupported).thenReturn(false);

      final result = await similarity.computeSimilarity('hello', 'world');
      expect(result, 0.0);
      verifyNever(() => mockBackend.embed(any()));
    });

    test('正常流程：mock 返回已知向量并验证相似度', () async {
      when(() => mockBackend.isSupported).thenReturn(true);
      when(
        () => mockBackend.embed('hello'),
      ).thenAnswer((_) async => [1.0, 0.0, 1.0]);
      when(
        () => mockBackend.embed('world'),
      ).thenAnswer((_) async => [0.0, 1.0, 1.0]);

      final result = await similarity.computeSimilarity('hello', 'world');
      expect(result, closeTo(0.5, 1e-10));
    });

    test('相同文本 embed 结果相同时返回 1.0', () async {
      when(() => mockBackend.isSupported).thenReturn(true);
      when(
        () => mockBackend.embed('same'),
      ).thenAnswer((_) async => [1.0, 2.0, 3.0]);

      final result = await similarity.computeSimilarity('same', 'same');
      expect(result, closeTo(1.0, 1e-10));
    });

    test('isSupported 委托给 backend', () {
      when(() => mockBackend.isSupported).thenReturn(true);
      expect(similarity.isSupported, true);

      when(() => mockBackend.isSupported).thenReturn(false);
      expect(similarity.isSupported, false);
    });
  });
}
