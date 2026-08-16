import 'dart:convert';

import 'package:ai_knowledge_companion/data/local/database.dart';
import 'package:ai_knowledge_companion/data/local/local_data_source.dart';
import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:ai_knowledge_companion/features/analysis/analysis_controller.dart';
import 'package:ai_knowledge_companion/features/sync/sync_controller.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/analysis_fakes.dart';

const _canonicalResult = {
  'schema_version': 1,
  'session': {
    'id': 's1',
    'title': 'Q3 Budget',
    'alternative_titles': ['Budget Review'],
    'summary': 'We need to finalize the budget by Friday.',
    'language': 'en',
    'status': 'ready',
    'duration_sec': 30.0,
    'word_count': 12,
    'prompt_versions': {'cleanup': 1, 'segmentation': 1},
    'topics': [
      {
        'id': 't1',
        'position': 0,
        'title': 'Budget',
        'description': '',
        'items': [
          {
            'id': 'i1',
            'type': 'task',
            'position': 0,
            'title': 'Finalize the budget',
            'description': '',
            'priority': 'high',
            'confidence': 0.9,
          },
        ],
      },
    ],
  },
};

class _SignedInAuth implements AuthRepository {
  @override
  String? get currentUserId => 'u1';

  @override
  Stream<String?> watchUserId() => const Stream.empty();

  @override
  Future<void> signInWithGoogle() async {}

  @override
  Future<void> signOut() async {}
}

class _FakeSync extends NoopSyncRepository {
  final uploads = <({String sessionId, String localPath})>[];
  Object? uploadFailure;

  @override
  Future<void> uploadAudio(String sessionId, String localPath) async {
    if (uploadFailure != null) throw uploadFailure!;
    uploads.add((sessionId: sessionId, localPath: localPath));
  }
}

class _FakeAppSettings implements AppSettingsRepository {
  final Map<String, bool> deleteAudio = {};
  final Map<String, bool> insights = {};
  final Map<String, bool> memory = {};

  @override
  Future<bool> getDeleteAudioAfterProcessing(String userId) async =>
      deleteAudio[userId] ?? false;

  @override
  Future<void> setDeleteAudioAfterProcessing(String userId, bool value) async {
    deleteAudio[userId] = value;
  }

  @override
  Future<bool> getEnableInsights(String userId) async => insights[userId] ?? false;

  @override
  Future<void> setEnableInsights(String userId, bool value) async {
    insights[userId] = value;
  }

  @override
  Future<bool> getEnableMemory(String userId) async => memory[userId] ?? false;

  @override
  Future<void> setEnableMemory(String userId, bool value) async {
    memory[userId] = value;
  }

  @override
  Future<bool> getMemorySkip(String sessionId) async => false;

  @override
  Future<void> setMemorySkip(String sessionId, bool value) async {}
}

void main() {
  late AppDatabase db;
  late SessionLocalDataSource sessions;
  late JobLocalDataSource jobs;
  late VersionLocalDataSource versions;
  late FakeEngineGateway engine;
  late _FakeAppSettings settings;
  late _FakeSync sync;

  Session draft() => Session(
        id: 's1',
        userId: 'u1',
        status: SessionStatus.ready,
        audioPath: '/tmp/s1.m4a',
        durationSec: 12.5,
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      );

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    sessions = SessionLocalDataSource(db);
    jobs = JobLocalDataSource(db);
    versions = VersionLocalDataSource(db);
    engine = FakeEngineGateway();
    settings = _FakeAppSettings();
    sync = _FakeSync();
  });

  tearDown(() async {
    engine.closeStream();
    await db.close();
  });

  ProviderContainer makeContainer() => ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(sessions),
        jobProvider.overrideWithValue(jobs),
        engineGatewayProvider.overrideWithValue(engine),
        versionRepositoryProvider.overrideWithValue(versions),
        tagRepositoryProvider.overrideWithValue(TagLocalDataSource(db)),
        embeddingRepositoryProvider.overrideWithValue(EmbeddingLocalDataSource(db)),
        authRepositoryProvider.overrideWithValue(_SignedInAuth()),
        appSettingsRepositoryProvider.overrideWithValue(settings),
        syncProvider.overrideWithValue(sync),
      ]);

  Future<void> flush() => pumpEventQueue();

  test('submits a job, streams progress, and applies the canonical session',
      () async {
    await sessions.insertSession(draft());
    final container = makeContainer();
    addTearDown(container.dispose);

    await container.read(analysisControllerProvider('s1').notifier).analyze();
    await flush();

    expect(engine.createCount, 1);
    expect(engine.created!.kind, JobKind.analyze);
    expect(sync.uploads, [
      (sessionId: 's1', localPath: '/tmp/s1.m4a'),
    ]);
    expect(engine.created!.inputRef, 'sessions/u1/s1.m4a');
    expect(engine.lastOptions!['input_meta'], {
      'mime_type': 'audio/mp4',
      'duration_sec': 12.5,
    });
    final uploaded = (await sessions.getSession('s1'))!;
    expect(uploaded.audioPath, '/tmp/s1.m4a');
    expect(uploaded.audioRemoteUrl, 'sessions/u1/s1.m4a');
    expect(
      uploaded.status,
      SessionStatus.uploading,
    );
    expect(
      container.read(analysisControllerProvider('s1')).phase,
      AnalysisPhase.processing,
    );

    final base = engine.created!;
    engine.emit(runningJob(base, 'cleanup', 'cleaning', 'Cleaning up'));
    engine.emit(runningJob(base, 'classification', 'analyzing', 'Classifying'));
    await flush();

    var session = (await sessions.getSession('s1'))!;
    expect(session.status, SessionStatus.analyzing);

    engine.emit(succeededJob(
      base,
      jsonEncode(_canonicalResult),
      intermediatesJson: jsonEncode({
        'cleanup': {
          'cleaned_text': 'We need to finalize the budget by Friday.',
          'original_text': 'um we need to uh finalize the budget by Friday',
        },
      }),
    ));
    await flush();

    session = (await sessions.getSession('s1'))!;
    expect(session.status, SessionStatus.ready);
    expect(session.title, 'Q3 Budget');
    expect(session.summary, 'We need to finalize the budget by Friday.');
    expect(session.promptVersions, {'cleanup': 1, 'segmentation': 1});
    expect(session.topics, hasLength(1));
    expect(session.topics.single.items.single.title, 'Finalize the budget');
    expect(session.cleanedTranscript, 'We need to finalize the budget by Friday.');
    expect(
      session.originalTranscript,
      'um we need to uh finalize the budget by Friday',
    );

    final state = container.read(analysisControllerProvider('s1'));
    expect(state.phase, AnalysisPhase.succeeded);
    expect(state.status, SessionStatus.ready);
  });

  test('the embedding stage output is persisted for semantic search (§6.1)',
      () async {
    await sessions.insertSession(draft());
    final container = makeContainer();
    addTearDown(container.dispose);

    await container.read(analysisControllerProvider('s1').notifier).analyze();
    await flush();

    final base = engine.created!;
    engine.emit(succeededJob(
      base,
      jsonEncode(_canonicalResult),
      intermediatesJson: jsonEncode({
        'cleanup': {
          'cleaned_text': 'We need to finalize the budget by Friday.',
        },
        'embedding': {
          'embedding': [0.1, 0.2, 0.3, 0.4],
          'dimension': 4,
          'text_length': 38,
        },
      }),
    ));
    await flush();

    final embeddings = EmbeddingLocalDataSource(db);
    final vector = await embeddings.embeddingForSession('s1');
    expect(vector, hasLength(4));
    for (var i = 0; i < 4; i++) {
      expect(vector![i], closeTo([0.1, 0.2, 0.3, 0.4][i], 1e-6));
    }
  });

  test('the tags stage output is attached as auto-tags (§4.2)', () async {
    await sessions.insertSession(draft());
    final container = makeContainer();
    addTearDown(container.dispose);

    await container.read(analysisControllerProvider('s1').notifier).analyze();
    await flush();

    final base = engine.created!;
    engine.emit(succeededJob(
      base,
      jsonEncode({
        ..._canonicalResult,
        'session': {
          ..._canonicalResult['session'] as Map<String, dynamic>,
          'tags': [
            {'name': 'Budget', 'confidence': 0.9},
            {'name': 'Planning'},
          ],
        },
      }),
    ));
    await flush();

    final tags = await TagLocalDataSource(db).getTagsForSession('s1');
    expect(tags.map((t) => t.name).toSet(), {'Budget', 'Planning'});
  });

  test('malformed tags output is ignored, analysis still succeeds', () async {
    await sessions.insertSession(draft());
    final container = makeContainer();
    addTearDown(container.dispose);

    await container.read(analysisControllerProvider('s1').notifier).analyze();
    await flush();

    engine.emit(succeededJob(
      engine.created!,
      jsonEncode({
        ..._canonicalResult,
        'session': {
          ..._canonicalResult['session'] as Map<String, dynamic>,
          'tags': 'not-a-list',
        },
      }),
    ));
    await flush();

    final session = (await sessions.getSession('s1'))!;
    expect(session.status, SessionStatus.ready);
    expect(await TagLocalDataSource(db).getTagsForSession('s1'), isEmpty);
  });

  test('reuses the existing remote audio reference without re-uploading',
      () async {
    await sessions.insertSession(
      draft().copyWith(audioRemoteUrl: 'sessions/u1/s1.m4a'),
    );
    final container = makeContainer();
    addTearDown(container.dispose);

    await container.read(analysisControllerProvider('s1').notifier).analyze();
    await flush();

    expect(sync.uploads, isEmpty);
    expect(engine.created!.inputRef, 'sessions/u1/s1.m4a');
  });

  test('upload failure does not create an engine job or discard local audio',
      () async {
    sync.uploadFailure = Exception('storage unavailable');
    await sessions.insertSession(draft());
    final container = makeContainer();
    addTearDown(container.dispose);

    await container.read(analysisControllerProvider('s1').notifier).analyze();
    await flush();

    expect(engine.createCount, 0);
    expect(container.read(analysisControllerProvider('s1')).phase,
        AnalysisPhase.failed);
    final session = (await sessions.getSession('s1'))!;
    expect(session.audioPath, '/tmp/s1.m4a');
    expect(session.audioRemoteUrl, isNull);
  });

  test('failure marks the session failed with the engine message; retry works',
      () async {
    await sessions.insertSession(draft());
    final container = makeContainer();
    addTearDown(container.dispose);

    final notifier = container.read(analysisControllerProvider('s1').notifier);
    await notifier.analyze();
    await flush();

    engine.emit(failedJob(engine.created!, 'boom'));
    await flush();

    var session = (await sessions.getSession('s1'))!;
    expect(session.status, SessionStatus.failed);
    expect(session.lastError, 'boom');
    var state = container.read(analysisControllerProvider('s1'));
    expect(state.phase, AnalysisPhase.failed);
    expect(state.error, 'boom');

    await notifier.analyze();
    await flush();

    expect(engine.createCount, 2);
    session = (await sessions.getSession('s1'))!;
    expect(session.status, SessionStatus.uploading);
    expect(
      container.read(analysisControllerProvider('s1')).phase,
      AnalysisPhase.processing,
    );
  });

  test('cancel transitions the session to cancelled', () async {
    await sessions.insertSession(draft());
    final container = makeContainer();
    addTearDown(container.dispose);

    final notifier = container.read(analysisControllerProvider('s1').notifier);
    await notifier.analyze();
    await flush();
    engine.emit(runningJob(engine.created!, 'cleanup', 'cleaning', 'Cleaning up'));
    await flush();

    await notifier.cancel();
    await flush();

    expect((await sessions.getSession('s1'))!.status, SessionStatus.cancelled);
    final state = container.read(analysisControllerProvider('s1'));
    expect(state.phase, AnalysisPhase.cancelled);
  });

  test('analyze without a recording fails fast', () async {
    await sessions.insertSession(draft().copyWith(clearAudioPath: true));
    final container = makeContainer();
    addTearDown(container.dispose);

    await container.read(analysisControllerProvider('s1').notifier).analyze();
    await flush();

    expect(engine.createCount, 0);
    final state = container.read(analysisControllerProvider('s1'));
    expect(state.phase, AnalysisPhase.failed);
    expect(state.error, contains('No recording'));
  });

  test('analyzeTranscript re-runs from text without audio and reaches ready',
      () async {
    await sessions.insertSession(draft());
    final container = makeContainer();
    addTearDown(container.dispose);

    await container
        .read(analysisControllerProvider('s1').notifier)
        .analyzeTranscript('We need to finalize the budget by Friday.');
    await flush();

    expect(engine.createCount, 1);
    expect(engine.created!.kind, JobKind.analyze);
    expect(engine.created!.inputRef, isNull);
    expect(engine.lastOptions!['input_kind'], 'transcript');
    expect(engine.lastOptions!['input_meta'],
        {'text': 'We need to finalize the budget by Friday.'});
    expect(engine.lastOptions!['memory'], isA<List>());
    expect(
      (await sessions.getSession('s1'))!.status,
      SessionStatus.cleaning,
    );
    expect(
      container.read(analysisControllerProvider('s1')).phase,
      AnalysisPhase.processing,
    );

    final base = engine.created!;
    engine.emit(runningJob(base, 'cleanup', 'cleaning', 'Cleaning up'));
    engine.emit(runningJob(base, 'validation', 'validating', 'Validating'));
    await flush();

    engine.emit(succeededJob(base, jsonEncode(_canonicalResult)));
    await flush();

    final session = (await sessions.getSession('s1'))!;
    expect(session.status, SessionStatus.ready);
    expect(session.title, 'Q3 Budget');
    expect(session.topics, hasLength(1));
    final state = container.read(analysisControllerProvider('s1'));
    expect(state.phase, AnalysisPhase.succeeded);
    expect(state.status, SessionStatus.ready);
  });

  test('analyzeTranscript rejects an empty transcript', () async {
    await sessions.insertSession(draft());
    final container = makeContainer();
    addTearDown(container.dispose);

    await container.read(analysisControllerProvider('s1').notifier)
        .analyzeTranscript('   ');
    await flush();

    expect(engine.createCount, 0);
    final state = container.read(analysisControllerProvider('s1'));
    expect(state.phase, AnalysisPhase.failed);
    expect(state.error, contains('empty'));
  });

  test('analyzeNote submits a note job from text and reaches ready',
      () async {
    await sessions.insertSession(draft());
    final container = makeContainer();
    addTearDown(container.dispose);

    await container
        .read(analysisControllerProvider('s1').notifier)
        .analyzeNote('We need to finalize the budget by Friday.',
            title: '  Budget  ');
    await flush();

    expect(engine.createCount, 1);
    expect(engine.created!.kind, JobKind.analyze);
    expect(engine.created!.inputRef, isNull);
    expect(engine.lastOptions!['input_kind'], 'note');
    expect(engine.lastOptions!['input_meta'],
        {'text': 'We need to finalize the budget by Friday.', 'title': 'Budget'});
    expect(engine.lastOptions!['memory'], isA<List>());
    expect(
      (await sessions.getSession('s1'))!.status,
      SessionStatus.cleaning,
    );
    expect(
      container.read(analysisControllerProvider('s1')).phase,
      AnalysisPhase.processing,
    );

    final base = engine.created!;
    engine.emit(runningJob(base, 'cleanup', 'cleaning', 'Cleaning up'));
    engine.emit(runningJob(base, 'validation', 'validating', 'Validating'));
    await flush();

    engine.emit(succeededJob(base, jsonEncode(_canonicalResult)));
    await flush();

    final session = (await sessions.getSession('s1'))!;
    expect(session.status, SessionStatus.ready);
    expect(session.title, 'Q3 Budget');
    expect(session.topics, hasLength(1));
    final state = container.read(analysisControllerProvider('s1'));
    expect(state.phase, AnalysisPhase.succeeded);
    expect(state.status, SessionStatus.ready);
  });

  test('analyzeNote omits an empty title', () async {
    await sessions.insertSession(draft());
    final container = makeContainer();
    addTearDown(container.dispose);

    await container.read(analysisControllerProvider('s1').notifier)
        .analyzeNote('Some note text.', title: '   ');
    await flush();

    expect(engine.lastOptions!['input_meta'], {'text': 'Some note text.'});
  });

  test('analyzeNote rejects an empty note', () async {
    await sessions.insertSession(draft());
    final container = makeContainer();
    addTearDown(container.dispose);

    await container.read(analysisControllerProvider('s1').notifier)
        .analyzeNote('   ');
    await flush();

    expect(engine.createCount, 0);
    final state = container.read(analysisControllerProvider('s1'));
    expect(state.phase, AnalysisPhase.failed);
    expect(state.error, contains('empty'));
  });

  test('analyzeDocument submits an OCR job for an image and reaches ready',
      () async {
    await sessions.insertSession(draft());
    final container = makeContainer();
    addTearDown(container.dispose);

    await container.read(analysisControllerProvider('s1').notifier)
        .analyzeDocument('/tmp/s1.png',
            inputKind: 'image', mimeType: 'image/png');
    await flush();

    expect(engine.createCount, 1);
    expect(engine.created!.kind, JobKind.analyze);
    expect(engine.created!.inputRef, '/tmp/s1.png');
    expect(engine.lastOptions!['input_kind'], 'image');
    expect(engine.lastOptions!['input_meta'], {'mime_type': 'image/png'});
    expect(
      (await sessions.getSession('s1'))!.status,
      SessionStatus.uploading,
    );
    expect(
      container.read(analysisControllerProvider('s1')).phase,
      AnalysisPhase.processing,
    );

    final base = engine.created!;
    engine.emit(runningJob(base, 'cleanup', 'cleaning', 'Cleaning up'));
    engine.emit(runningJob(base, 'validation', 'validating', 'Validating'));
    await flush();

    engine.emit(succeededJob(base, jsonEncode(_canonicalResult)));
    await flush();

    final session = (await sessions.getSession('s1'))!;
    expect(session.status, SessionStatus.ready);
    expect(session.title, 'Q3 Budget');
    expect(session.topics, hasLength(1));
    final state = container.read(analysisControllerProvider('s1'));
    expect(state.phase, AnalysisPhase.succeeded);
    expect(state.status, SessionStatus.ready);
  });

  test('analyzeDocument submits a pdf job with the pdf mime type', () async {
    await sessions.insertSession(draft());
    final container = makeContainer();
    addTearDown(container.dispose);

    await container.read(analysisControllerProvider('s1').notifier)
        .analyzeDocument('/tmp/doc.pdf',
            inputKind: 'pdf', mimeType: 'application/pdf');
    await flush();

    expect(engine.createCount, 1);
    expect(engine.created!.inputRef, '/tmp/doc.pdf');
    expect(engine.lastOptions!['input_kind'], 'pdf');
    expect(engine.lastOptions!['input_meta'],
        {'mime_type': 'application/pdf'});
    expect(
      (await sessions.getSession('s1'))!.status,
      SessionStatus.uploading,
    );
  });

  test('duplicate submissions while processing are ignored', () async {
    await sessions.insertSession(draft());
    final container = makeContainer();
    addTearDown(container.dispose);

    final notifier = container.read(analysisControllerProvider('s1').notifier);
    await notifier.analyze();
    await flush();
    await notifier.analyze();
    await flush();

    expect(engine.createCount, 1);
  });

  test('audio is kept after processing by default (privacy off)', () async {
    await sessions.insertSession(draft());
    final container = makeContainer();
    addTearDown(container.dispose);

    await container.read(analysisControllerProvider('s1').notifier).analyze();
    await flush();
    engine.emit(succeededJob(engine.created!, jsonEncode(_canonicalResult)));
    await flush();

    final session = (await sessions.getSession('s1'))!;
    expect(session.status, SessionStatus.ready);
    expect(session.audioPath, '/tmp/s1.m4a');
  });

  test('delete-audio-after-processing removes the recording on success',
      () async {
    settings.deleteAudio['u1'] = true;
    await sessions.insertSession(draft());
    final container = makeContainer();
    addTearDown(container.dispose);

    await container.read(analysisControllerProvider('s1').notifier).analyze();
    await flush();
    engine.emit(succeededJob(
      engine.created!,
      jsonEncode(_canonicalResult),
      intermediatesJson: jsonEncode({
        'cleanup': {
          'cleaned_text': 'We need to finalize the budget by Friday.',
          'original_text': 'um we need to uh finalize the budget by Friday',
        },
      }),
    ));
    await flush();

    final session = (await sessions.getSession('s1'))!;
    expect(session.status, SessionStatus.ready);
    expect(session.audioPath, isNull);
    expect(session.cleanedTranscript, isNotNull);
  });
}
