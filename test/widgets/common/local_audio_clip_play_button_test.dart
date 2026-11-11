import 'dart:async';

import 'package:loop_back/services/pronunciation/local_audio_clip_player.dart';
import 'package:loop_back/widgets/common/local_audio_clip_play_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeBackend implements AudioClipPlayerBackend {
  final completedController = StreamController<void>.broadcast();
  final errorsController = StreamController<String>.broadcast();
  final positionsController = StreamController<Duration>.broadcast();
  final opened = <String>[];
  Duration current = Duration.zero;
  @override
  Stream<void> get completed => completedController.stream;
  @override
  Stream<String> get errors => errorsController.stream;
  @override
  Stream<Duration> get positions => positionsController.stream;
  @override
  Duration get position => current;
  @override
  Future<void> open(String path, {Duration start = Duration.zero}) async {
    opened.add(path);
    current = start;
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {
    await completedController.close();
    await errorsController.close();
    await positionsController.close();
  }
}

Widget _app(LocalAudioClipPlayer player, {String path = '/a.opus'}) =>
    MaterialApp(
      home: LocalAudioClipPlayButton(filePath: path, player: player),
    );

void main() {
  testWidgets('空闲、播放中、完成状态切换图标和颜色', (tester) async {
    final backend = _FakeBackend();
    final player = LocalAudioClipPlayer(backend: backend);
    await tester.pumpWidget(_app(player));
    final context = tester.element(find.byType(LocalAudioClipPlayButton));
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(
      tester.widget<Icon>(find.byIcon(Icons.play_arrow_rounded)).color,
      Theme.of(context).colorScheme.primary,
    );
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNull,
    );
    await tester.pump(const Duration(milliseconds: 11));
    expect(find.byIcon(Icons.stop_rounded), findsOneWidget);
    expect(
      tester.widget<Icon>(find.byIcon(Icons.stop_rounded)).color,
      Theme.of(context).colorScheme.error,
    );
    backend.completedController.add(null);
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    await player.dispose();
  });

  testWidgets('加载中显示进度并禁用按钮', (tester) async {
    final backend = _FakeBackend();
    final player = LocalAudioClipPlayer(backend: backend);
    await tester.pumpWidget(_app(player));
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 11));
    expect(find.byIcon(Icons.stop_rounded), findsOneWidget);
    await player.dispose();
  });

  testWidgets('点击播放中按钮停止', (tester) async {
    final backend = _FakeBackend();
    final player = LocalAudioClipPlayer(backend: backend);
    await tester.pumpWidget(_app(player));
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pump(const Duration(milliseconds: 11));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.stop_rounded));
    await tester.pump();
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    await player.dispose();
  });

  testWidgets('支持自定义播放和停止图标', (tester) async {
    final backend = _FakeBackend();
    final player = LocalAudioClipPlayer(backend: backend);
    await tester.pumpWidget(
      MaterialApp(
        home: LocalAudioClipPlayButton(
          filePath: '/a.opus',
          player: player,
          playIcon: Icons.volume_up,
          stopIcon: Icons.pause,
        ),
      ),
    );
    expect(find.byIcon(Icons.volume_up), findsOneWidget);
    await tester.tap(find.byIcon(Icons.volume_up));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 11));
    expect(find.byIcon(Icons.pause), findsOneWidget);
    await player.stop();
    await player.dispose();
  });

  testWidgets('隐藏停止状态时播放中保持播放图标并禁用按钮', (tester) async {
    final backend = _FakeBackend();
    final player = LocalAudioClipPlayer(backend: backend);
    await tester.pumpWidget(
      MaterialApp(
        home: LocalAudioClipPlayButton(
          filePath: '/a.opus',
          player: player,
          playIcon: Icons.volume_up,
          showStopButton: false,
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.volume_up));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 11));
    expect(find.byIcon(Icons.volume_up), findsOneWidget);
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNull,
    );
    backend.completedController.add(null);
    await tester.pump();
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNotNull,
    );
    await player.dispose();
  });

  testWidgets('空路径禁用按钮', (tester) async {
    final player = LocalAudioClipPlayer(backend: _FakeBackend());
    await tester.pumpWidget(_app(player, path: '  '));
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNull,
    );
    await player.dispose();
  });
}
