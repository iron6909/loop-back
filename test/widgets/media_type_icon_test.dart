import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/widgets/media_type_icon.dart';

void main() {
  testWidgets('音频媒体显示波形图标', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: MediaTypeIcon(isVideo: false)),
    );

    expect(find.byIcon(Icons.graphic_eq), findsOneWidget);
    expect(find.byType(SvgPicture), findsNothing);
  });

  testWidgets('视频媒体显示视频 SVG', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: MediaTypeIcon(isVideo: true)),
    );

    expect(find.byType(SvgPicture), findsOneWidget);
    expect(find.byIcon(Icons.graphic_eq), findsNothing);
  });
}
