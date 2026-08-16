import 'dart:io';

import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:ai_knowledge_companion/features/auth/auth_controller.dart';
import 'package:ai_knowledge_companion/features/home/home_screen.dart';
import 'package:ai_knowledge_companion/features/recording/recording_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/recording_fakes.dart';

void main() {
  List<Override> overrides({
    required FakeVoiceRecorder recorder,
    required RecordingTestRepo repo,
  }) => [
        databaseProvider.overrideWithValue(repo),
        authRepositoryProvider.overrideWithValue(const NoopAuthRepository()),
        voiceRecorderProvider.overrideWithValue(recorder),
        recordingOutputDirectoryProvider.overrideWithValue(
          Future.value(Directory('/tmp/ai_voice_test')),
        ),
      ];

  testWidgets('record flow: mic starts a draft, ticks, stop marks it ready',
      (tester) async {
    final recorder = FakeVoiceRecorder();
    final repo = RecordingTestRepo();
    await tester.pumpWidget(ProviderScope(
      overrides: overrides(recorder: recorder, repo: repo),
      child: const MaterialApp(home: HomeScreen()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.mic));
    await tester.pump();
    await tester.pump();

    expect(recorder.startCalls, 1);
    expect(recorder.startedPath, endsWith('.m4a'));
    expect(repo.sessions, hasLength(1));
    expect(repo.sessions.single.status, SessionStatus.recording);
    expect(repo.sessions.single.userId, 'local');
    expect(find.text('Start Recording'), findsNothing);
    expect(find.textContaining('Recording…'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    expect(find.textContaining('00:03'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.stop_circle_outlined));
    await tester.pump();
    await tester.pump();

    expect(recorder.stopCalls, 1);
    expect(repo.sessions.single.status, SessionStatus.ready);
    expect(repo.sessions.single.audioPath, recorder.startedPath);
    expect(repo.sessions.single.durationSec, closeTo(3, 0.001));
    expect(find.text('Start Recording'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('permission denial shows the error and stays idle',
      (tester) async {
    final recorder = FakeVoiceRecorder()..permissionGranted = false;
    final repo = RecordingTestRepo();
    await tester.pumpWidget(ProviderScope(
      overrides: overrides(recorder: recorder, repo: repo),
      child: const MaterialApp(home: HomeScreen()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.mic));
    await tester.pump();
    await tester.pump();

    expect(find.text('Microphone permission denied.'), findsOneWidget);
    expect(find.text('Start Recording'), findsOneWidget);
    expect(repo.sessions, isEmpty);
  });

  testWidgets('pause/resume toggle and live waveform render while recording',
      (tester) async {
    final recorder = FakeVoiceRecorder();
    final repo = RecordingTestRepo();
    await tester.pumpWidget(ProviderScope(
      overrides: overrides(recorder: recorder, repo: repo),
      child: const MaterialApp(home: HomeScreen()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.mic));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('record-waveform')), findsOneWidget);
    expect(find.byIcon(Icons.pause_circle_outline), findsOneWidget);

    recorder.pushAmplitude(0.3);
    recorder.pushAmplitude(0.8);
    await tester.pump();

    await tester.tap(find.byIcon(Icons.pause_circle_outline));
    await tester.pump();
    await tester.pump();
    expect(recorder.pauseCalls, 1);
    expect(find.textContaining('Paused'), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);

    await tester.tap(find.byIcon(Icons.play_circle_outline));
    await tester.pump();
    await tester.pump();
    expect(recorder.resumeCalls, 1);
    expect(find.textContaining('Recording…'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.stop_circle_outlined));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('record-waveform')), findsNothing);
    expect(find.text('Start Recording'), findsOneWidget);
  });
}
