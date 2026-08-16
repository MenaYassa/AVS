import 'dart:io';

import 'package:ai_knowledge_companion/core/document/document_picker.dart';
import 'package:ai_knowledge_companion/data/local/database.dart';
import 'package:ai_knowledge_companion/data/local/local_data_source.dart';
import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:ai_knowledge_companion/features/auth/auth_controller.dart';
import 'package:ai_knowledge_companion/features/capture/document_capture_controller.dart';
import 'package:ai_knowledge_companion/features/recording/recording_controller.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/analysis_fakes.dart';
import '../helpers/recording_fakes.dart';

class _FakeDocumentPicker implements DocumentPicker {
  _FakeDocumentPicker({
    this.imagePath,
    this.pdfPath,
    this.emailPath,
    this.documentPath,
  });

  final String? imagePath;
  final String? pdfPath;
  final String? emailPath;
  final String? documentPath;

  @override
  Future<String?> pickImage() async => imagePath;

  @override
  Future<String?> pickPdf() async => pdfPath;

  @override
  Future<String?> pickEmail() async => emailPath;

  @override
  Future<String?> pickDocument() async => documentPath;
}

class _FakeAppSettings implements AppSettingsRepository {
  @override
  Future<bool> getDeleteAudioAfterProcessing(String userId) async => false;

  @override
  Future<void> setDeleteAudioAfterProcessing(String userId, bool value) async {}

  @override
  Future<bool> getEnableInsights(String userId) async => false;

  @override
  Future<void> setEnableInsights(String userId, bool value) async {}

  @override
  Future<bool> getEnableMemory(String userId) async => false;

  @override
  Future<void> setEnableMemory(String userId, bool value) async {}

  @override
  Future<bool> getMemorySkip(String sessionId) async => false;

  @override
  Future<void> setMemorySkip(String sessionId, bool value) async {}
}

void main() {
  late AppDatabase db;
  late RecordingTestRepo sessions;
  late FakeEngineGateway engine;
  late Directory dir;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    sessions = RecordingTestRepo();
    engine = FakeEngineGateway();
    dir = await Directory.systemTemp.createTemp('doc_capture_test');
  });

  tearDown(() async {
    engine.closeStream();
    await db.close();
    await dir.delete(recursive: true);
  });

  ProviderContainer makeContainer(_FakeDocumentPicker picker) =>
      ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(sessions),
        jobProvider.overrideWithValue(JobLocalDataSource(db)),
        engineGatewayProvider.overrideWithValue(engine),
        authRepositoryProvider.overrideWithValue(const NoopAuthRepository()),
        appSettingsRepositoryProvider.overrideWithValue(_FakeAppSettings()),
        documentPickerProvider.overrideWithValue(picker),
        recordingOutputDirectoryProvider.overrideWithValue(Future.value(dir)),
      ]);

  test('importing an image copies the file, creates a session, and analyzes',
      () async {
    final source = File('${dir.path}/shot.png');
    await source.writeAsString('fake image bytes');
    final container =
        makeContainer(_FakeDocumentPicker(imagePath: source.path));
    addTearDown(container.dispose);

    final session = await container
        .read(documentCaptureControllerProvider.notifier)
        .capture(DocumentKind.image);
    await pumpEventQueue();

    expect(session, isNotNull);
    expect(sessions.sessions, hasLength(1));
    final stored = sessions.sessions.single;
    expect(stored.id, session!.id);
    expect(stored.status, SessionStatus.uploading);
    final copied = stored.audioPath;
    expect(copied, endsWith('${stored.id}.png'));
    expect(File(copied!).existsSync(), isTrue);

    expect(engine.createCount, 1);
    expect(engine.created!.kind, JobKind.analyze);
    expect(engine.created!.inputRef, copied);
    expect(engine.lastOptions!['input_kind'], 'image');
    expect(engine.lastOptions!['input_meta'], {'mime_type': 'image/png'});
  });

  test('importing a screenshot rides the image/OCR path with its own kind',
      () async {
    final source = File('${dir.path}/shot.png');
    await source.writeAsString('fake screenshot bytes');
    final container =
        makeContainer(_FakeDocumentPicker(imagePath: source.path));
    addTearDown(container.dispose);

    final session = await container
        .read(documentCaptureControllerProvider.notifier)
        .capture(DocumentKind.screenshot);
    await pumpEventQueue();

    expect(session, isNotNull);
    final stored = sessions.sessions.single;
    expect(stored.audioPath, endsWith('${stored.id}.png'));
    expect(engine.lastOptions!['input_kind'], 'screenshot');
    expect(engine.lastOptions!['input_meta'], {'mime_type': 'image/png'});
  });

  test('importing a pdf maps mime and copies with the pdf extension',
      () async {
    final source = File('${dir.path}/doc.pdf');
    await source.writeAsString('fake pdf bytes');
    final container = makeContainer(_FakeDocumentPicker(pdfPath: source.path));
    addTearDown(container.dispose);

    final session = await container
        .read(documentCaptureControllerProvider.notifier)
        .capture(DocumentKind.pdf);
    await pumpEventQueue();

    expect(session, isNotNull);
    final stored = sessions.sessions.single;
    expect(stored.audioPath, endsWith('${stored.id}.pdf'));
    expect(engine.lastOptions!['input_kind'], 'pdf');
    expect(engine.lastOptions!['input_meta'], {'mime_type': 'application/pdf'});
  });

  test('cancelling the picker imports nothing', () async {
    final container =
        makeContainer(_FakeDocumentPicker(imagePath: null, pdfPath: null));
    addTearDown(container.dispose);

    final session = await container
        .read(documentCaptureControllerProvider.notifier)
        .capture(DocumentKind.image);
    await pumpEventQueue();

    expect(session, isNull);
    expect(sessions.sessions, isEmpty);
    expect(engine.createCount, 0);
  });

  test('importing an email maps rfc822 mime and analyzes', () async {
    final source = File('${dir.path}/inbox.eml');
    await source.writeAsString('From: a@b.c\nSubject: Hi\n\nBody');
    final container =
        makeContainer(_FakeDocumentPicker(emailPath: source.path));
    addTearDown(container.dispose);

    final session = await container
        .read(documentCaptureControllerProvider.notifier)
        .capture(DocumentKind.email);
    await pumpEventQueue();

    expect(session, isNotNull);
    final stored = sessions.sessions.single;
    expect(stored.audioPath, endsWith('${stored.id}.eml'));
    expect(engine.lastOptions!['input_kind'], 'email');
    expect(
      engine.lastOptions!['input_meta'],
      {'mime_type': 'message/rfc822'},
    );
  });

  test('importing a document maps its mime and analyzes', () async {
    final source = File('${dir.path}/notes.md');
    await source.writeAsString('# Notes');
    final container =
        makeContainer(_FakeDocumentPicker(documentPath: source.path));
    addTearDown(container.dispose);

    final session = await container
        .read(documentCaptureControllerProvider.notifier)
        .capture(DocumentKind.document);
    await pumpEventQueue();

    expect(session, isNotNull);
    final stored = sessions.sessions.single;
    expect(stored.audioPath, endsWith('${stored.id}.md'));
    expect(engine.lastOptions!['input_kind'], 'document');
    expect(engine.lastOptions!['input_meta'], {'mime_type': 'text/markdown'});
  });

  test('an unsupported document extension creates no session', () async {
    final source = File('${dir.path}/notes.exe');
    await source.writeAsString('nope');
    final container =
        makeContainer(_FakeDocumentPicker(documentPath: source.path));
    addTearDown(container.dispose);

    final session = await container
        .read(documentCaptureControllerProvider.notifier)
        .capture(DocumentKind.document);
    await pumpEventQueue();

    expect(session, isNull);
    expect(sessions.sessions, isEmpty);
    expect(engine.createCount, 0);
  });
}
