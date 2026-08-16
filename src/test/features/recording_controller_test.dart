import 'dart:io';

import 'package:ai_knowledge_companion/core/audio/voice_recorder.dart';
import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/job.dart';
import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:ai_knowledge_companion/features/analysis/analysis_controller.dart';
import 'package:ai_knowledge_companion/features/auth/auth_controller.dart';
import 'package:ai_knowledge_companion/features/recording/recording_controller.dart';
import 'package:ai_knowledge_companion/features/sync/sync_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/analysis_fakes.dart';
import '../helpers/recording_fakes.dart';

/// In-memory [JobRepository] for the auto-submit controller test.
class _JobRepo implements JobRepository {
  final Map<String, Job> jobs = {};

  @override
  Future<Job?> getJob(String id) async => jobs[id];

  @override
  Future<Job> insertJob(Job job) async {
    jobs[job.id] = job;
    return job;
  }

  @override
  Future<void> updateJob(Job job) async => jobs[job.id] = job;

  @override
  Stream<Job?> watchJob(String id) async* {
    yield jobs[id];
  }
}

void main() {
  group('RecordingController (architecture §4.12)', () {
    test('start creates a draft and pause/resume flip the phase', () async {
      final recorder = FakeVoiceRecorder();
      final repo = RecordingTestRepo();
      final container = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(repo),
        authRepositoryProvider.overrideWithValue(const NoopAuthRepository()),
        voiceRecorderProvider.overrideWithValue(recorder),
        recordingOutputDirectoryProvider.overrideWithValue(
            Future.value(Directory('/tmp/ai_voice_test'))),
        syncProvider.overrideWithValue(const NoopSyncRepository()),
      ]);
      addTearDown(container.dispose);

      final controller = container.read(recordingControllerProvider.notifier);
      expect(container.read(recordingControllerProvider).isRecording, isFalse);

      await controller.start();
      expect(recorder.startCalls, 1);
      expect(recorder.startedPath, endsWith('.m4a'));
      expect(repo.sessions, hasLength(1));
      expect(repo.sessions.single.userId, 'local');
      expect(repo.sessions.single.status, SessionStatus.recording);
      expect(container.read(recordingControllerProvider).isRecording, isTrue);

      recorder.pushAmplitude(0.1);
      recorder.pushAmplitude(0.5);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(recordingControllerProvider).waveform, [0.1, 0.5]);

      await controller.pause();
      expect(recorder.pauseCalls, 1);
      expect(container.read(recordingControllerProvider).phase,
          RecordingPhase.paused);

      await controller.resume();
      expect(recorder.resumeCalls, 1);
      expect(container.read(recordingControllerProvider).phase,
          RecordingPhase.recording);

      await controller.cancel();
      expect(recorder.cancelCalls, 1);
      expect(container.read(recordingControllerProvider).phase,
          RecordingPhase.idle);
      expect(repo.sessions, isEmpty);
    });

    test('stop advances the draft to ready with path and duration', () async {
      final recorder = FakeVoiceRecorder();
      final repo = RecordingTestRepo();
      final container = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(repo),
        authRepositoryProvider.overrideWithValue(const NoopAuthRepository()),
        voiceRecorderProvider.overrideWithValue(recorder),
        recordingOutputDirectoryProvider.overrideWithValue(
            Future.value(Directory('/tmp/ai_voice_test'))),
        syncProvider.overrideWithValue(const NoopSyncRepository()),
      ]);
      addTearDown(container.dispose);

      final controller = container.read(recordingControllerProvider.notifier);
      await controller.start();
      container.read(recordingControllerProvider);

      await controller.stop();
      expect(recorder.stopCalls, 1);
      final session = repo.sessions.single;
      expect(session.status, SessionStatus.ready);
      expect(session.audioPath, recorder.startedPath);
      expect(container.read(recordingControllerProvider).isRecording, isFalse);
    });

    test('waveform buffer is capped at capacity and clears on stop', () async {
      final recorder = FakeVoiceRecorder();
      final repo = RecordingTestRepo();
      final container = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(repo),
        authRepositoryProvider.overrideWithValue(const NoopAuthRepository()),
        voiceRecorderProvider.overrideWithValue(recorder),
        recordingOutputDirectoryProvider.overrideWithValue(
            Future.value(Directory('/tmp/ai_voice_test'))),
        syncProvider.overrideWithValue(const NoopSyncRepository()),
      ]);
      addTearDown(container.dispose);

      final controller = container.read(recordingControllerProvider.notifier);
      await controller.start();
      for (var i = 0; i < 60; i++) {
        recorder.pushAmplitude(i / 100.0);
      }
      await Future<void>.delayed(Duration.zero);
      final buffer = container.read(recordingControllerProvider).waveform;
      expect(buffer.length, RecordingController.waveformCapacity);
      expect(buffer.first, closeTo(12 / 100.0, 1e-9));
      expect(buffer.last, closeTo(59 / 100.0, 1e-9));

      await controller.stop();
      expect(container.read(recordingControllerProvider).waveform, isEmpty);
    });

    test('stop auto-submits the recording for analysis', () async {
      final recorder = FakeVoiceRecorder();
      final repo = RecordingTestRepo();
      final engine = FakeEngineGateway();
      final container = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(repo),
        authRepositoryProvider.overrideWithValue(const NoopAuthRepository()),
        voiceRecorderProvider.overrideWithValue(recorder),
        recordingOutputDirectoryProvider.overrideWithValue(
            Future.value(Directory('/tmp/ai_voice_test'))),
        engineGatewayProvider.overrideWithValue(engine),
        jobProvider.overrideWithValue(_JobRepo()),
        syncProvider.overrideWithValue(const NoopSyncRepository()),
      ]);
      addTearDown(container.dispose);

      final controller = container.read(recordingControllerProvider.notifier);
      await controller.start();
      await controller.stop();

      // The new recording is auto-submitted as an analyze job with the audio
      // as input_ref, and the SSE stream is subscribed (§2.4).
      await pumpEventQueue();
      expect(engine.createCount, 1);
      final job = engine.created!;
      final sessionId = repo.sessions.single.id;
      expect(job.kind, JobKind.analyze);
      expect(job.inputRef, 'sessions/local/$sessionId.m4a');
      expect(engine.lastOptions?['input_meta'], {
        'mime_type': 'audio/mp4',
        'duration_sec': 0.0,
      });
      expect(
        container.read(analysisControllerProvider(sessionId)).isProcessing,
        isTrue,
      );
    });

    test('permission denial surfaces a friendly error and no draft',
        () async {
      final recorder = FakeVoiceRecorder()..permissionGranted = false;
      final repo = RecordingTestRepo();
      final container = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(repo),
        authRepositoryProvider.overrideWithValue(const NoopAuthRepository()),
        voiceRecorderProvider.overrideWithValue(recorder),
        recordingOutputDirectoryProvider.overrideWithValue(
            Future.value(Directory('/tmp/ai_voice_test'))),
        syncProvider.overrideWithValue(const NoopSyncRepository()),
      ]);
      addTearDown(container.dispose);

      final controller = container.read(recordingControllerProvider.notifier);
      await controller.start();
      expect(container.read(recordingControllerProvider).error,
          'Microphone permission denied.');
      expect(container.read(recordingControllerProvider).isRecording, isFalse);
      expect(repo.sessions, isEmpty);
    });
  });
}
