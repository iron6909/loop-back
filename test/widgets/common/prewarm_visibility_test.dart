import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:loop_back/widgets/common/prewarm_visibility.dart';

void main() {
  testWidgets('root route 被覆盖时停止，返回后恢复预热', (tester) async {
    final rootVisible = ValueNotifier<bool>(true);
    final events = <bool>[];

    await tester.pumpWidget(
      ValueListenableBuilder<bool>(
        valueListenable: rootVisible,
        builder: (context, isRootVisible, _) => MainTabVisibilityScope(
          currentIndex: 0,
          rootRouteVisible: isRootVisible,
          child: MaterialApp(
            home: PrewarmVisibility(
              mainTabIndex: 0,
              onChanged: events.add,
              child: const SizedBox(),
            ),
          ),
        ),
      ),
    );
    expect(events, [true]);

    rootVisible.value = false;
    await tester.pump();
    expect(events, [true, false]);

    rootVisible.value = true;
    await tester.pump();
    expect(events, [true, false, true]);

    rootVisible.dispose();
  });

  testWidgets('缺少主 tab scope 时不放行指定 tab 预热', (tester) async {
    final events = <bool>[];

    await tester.pumpWidget(
      MaterialApp(
        home: PrewarmVisibility(
          mainTabIndex: 0,
          onChanged: events.add,
          child: const SizedBox(),
        ),
      ),
    );

    expect(events, [false]);
  });
}
