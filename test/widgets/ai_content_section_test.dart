import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/widgets/common/ai_content_section.dart';

import '../helpers/test_app.dart';

void main() {
  group('AiContentSection', () {
    const rebuildKey = ValueKey<String>('ai-content-section-test-app');

    testWidgets('初始状态为折叠，只显示标题', (tester) async {
      await tester.pumpWidget(
        createTestApp(
          const AiContentSection(icon: Icons.translate, title: 'Translation'),
        ),
      );

      expect(find.text('Translation'), findsOneWidget);
      expect(find.byIcon(Icons.expand_more), findsOneWidget);
      expect(find.byIcon(Icons.expand_less), findsNothing);
    });

    testWidgets('cachedContent 非空时初始仍折叠，点击后立即显示', (tester) async {
      await tester.pumpWidget(
        createTestApp(
          const AiContentSection(
            icon: Icons.translate,
            title: 'Translation',
            cachedContent: '缓存的翻译内容',
          ),
        ),
      );

      await tester.pumpAndSettle();

      // 初始应折叠，不自动展开
      expect(find.byIcon(Icons.expand_more), findsOneWidget);
      expect(find.text('缓存的翻译内容'), findsNothing);

      // 点击展开 — 立即显示缓存内容，无 loading
      await tester.tap(find.text('Translation'));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.expand_less), findsOneWidget);
      expect(find.text('缓存的翻译内容'), findsOneWidget);
    });

    testWidgets('点击展开触发 onRequest', (tester) async {
      final completer = Completer<String>();

      await tester.pumpWidget(
        createTestApp(
          AiContentSection(
            icon: Icons.translate,
            title: 'Translation',
            onRequest: () => completer.future,
          ),
        ),
      );

      // 点击标题栏展开
      await tester.tap(find.text('Translation'));
      await tester.pump();

      // 应该显示 shimmer loading
      expect(find.byIcon(Icons.expand_less), findsOneWidget);

      // 完成请求
      completer.complete('翻译结果');
      await tester.pumpAndSettle();

      expect(find.text('翻译结果'), findsOneWidget);
    });

    testWidgets('请求失败显示错误和重试按钮', (tester) async {
      var callCount = 0;

      await tester.pumpWidget(
        createTestApp(
          AiContentSection(
            icon: Icons.translate,
            title: 'Translation',
            onRequest: () async {
              callCount++;
              if (callCount == 1) throw Exception('network error');
              return '第二次成功';
            },
          ),
        ),
      );

      // 展开
      await tester.tap(find.text('Translation'));
      await tester.pumpAndSettle();

      // 应显示错误状态
      expect(find.text('Failed to load, tap to retry'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);

      // 点击重试
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(find.text('第二次成功'), findsOneWidget);
    });

    testWidgets('点击折叠已展开的内容', (tester) async {
      await tester.pumpWidget(
        createTestApp(
          const AiContentSection(
            icon: Icons.translate,
            title: 'Translation',
            cachedContent: '内容',
          ),
        ),
      );

      await tester.pumpAndSettle();

      // 先点击展开
      await tester.tap(find.text('Translation'));
      await tester.pumpAndSettle();
      expect(find.text('内容'), findsOneWidget);

      // 点击折叠
      await tester.tap(find.text('Translation'));
      await tester.pumpAndSettle();

      // 标题仍在，箭头变回展开
      expect(find.byIcon(Icons.expand_more), findsOneWidget);
    });

    testWidgets('contentBuilder 自定义渲染', (tester) async {
      await tester.pumpWidget(
        createTestApp(
          AiContentSection(
            icon: Icons.auto_awesome,
            title: 'Analysis',
            cachedContent: 'custom data',
            contentBuilder: (content) => Text('Custom: $content'),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // 点击展开
      await tester.tap(find.text('Analysis'));
      await tester.pumpAndSettle();

      expect(find.text('Custom: custom data'), findsOneWidget);
    });

    testWidgets('cachedContent 从有值变为 null 时回到折叠状态', (tester) async {
      // 初始渲染：有缓存内容
      await tester.pumpWidget(
        createTestApp(
          const AiContentSection(
            icon: Icons.translate,
            title: 'Translation',
            cachedContent: '有内容',
          ),
        ),
      );

      await tester.pumpAndSettle();

      // 手动展开
      await tester.tap(find.text('Translation'));
      await tester.pumpAndSettle();
      expect(find.text('有内容'), findsOneWidget);
      expect(find.byIcon(Icons.expand_less), findsOneWidget);

      // rebuild 传 cachedContent=null
      await tester.pumpWidget(
        createTestApp(
          const AiContentSection(icon: Icons.translate, title: 'Translation'),
        ),
      );

      await tester.pumpAndSettle();

      // 应回到折叠状态
      expect(find.byIcon(Icons.expand_more), findsOneWidget);
      expect(find.text('有内容'), findsNothing);
    });

    testWidgets('已有内容再次展开不重新请求', (tester) async {
      var requestCount = 0;

      await tester.pumpWidget(
        createTestApp(
          AiContentSection(
            icon: Icons.translate,
            title: 'Translation',
            onRequest: () async {
              requestCount++;
              return '加载结果';
            },
          ),
        ),
      );

      // 第一次展开 — 触发 onRequest
      await tester.tap(find.text('Translation'));
      await tester.pumpAndSettle();
      expect(find.text('加载结果'), findsOneWidget);
      expect(requestCount, 1);

      // 折叠
      await tester.tap(find.text('Translation'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.expand_more), findsOneWidget);

      // 再次展开 — 不应重新请求
      await tester.tap(find.text('Translation'));
      await tester.pumpAndSettle();
      expect(find.text('加载结果'), findsOneWidget);
      expect(requestCount, 1);
    });

    testWidgets('cachedContent 变化时更新已展开的内容', (tester) async {
      await tester.pumpWidget(
        createTestApp(
          const AiContentSection(
            icon: Icons.translate,
            title: 'Translation',
            cachedContent: '旧内容',
          ),
          key: rebuildKey,
        ),
      );

      await tester.pumpAndSettle();

      // 手动展开
      await tester.tap(find.text('Translation'));
      await tester.pumpAndSettle();
      expect(find.text('旧内容'), findsOneWidget);

      // 更新 cachedContent — 已展开时应更新显示
      await tester.pumpWidget(
        createTestApp(
          const AiContentSection(
            icon: Icons.translate,
            title: 'Translation',
            cachedContent: '新内容',
          ),
          key: rebuildKey,
        ),
      );

      await tester.pumpAndSettle();
      expect(find.text('新内容'), findsOneWidget);
    });

    testWidgets('loading 状态下收到 cachedContent 自动展开', (tester) async {
      final completer = Completer<String>();

      await tester.pumpWidget(
        createTestApp(
          AiContentSection(
            icon: Icons.translate,
            title: 'Translation',
            onRequest: () => completer.future,
          ),
          key: rebuildKey,
        ),
      );

      // 点击展开 → loading 状态
      await tester.tap(find.text('Translation'));
      await tester.pump();
      expect(find.byIcon(Icons.expand_less), findsOneWidget);

      // 模拟：父组件 rebuild 带上 cachedContent（如 API 返回后缓存同步到父组件）
      await tester.pumpWidget(
        createTestApp(
          AiContentSection(
            icon: Icons.translate,
            title: 'Translation',
            cachedContent: '从缓存加载',
            onRequest: () => completer.future,
          ),
          key: rebuildKey,
        ),
      );

      await tester.pumpAndSettle();

      // loading → loaded，显示缓存内容
      expect(find.text('从缓存加载'), findsOneWidget);
    });
  });
}
