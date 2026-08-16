import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_knowledge_companion/data/engine/engine_client.dart';
import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal fake [HttpClientAdapter] returning canned engine responses.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.respond);

  final Map<String, dynamic> Function(RequestOptions options) respond;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final body = respond(options);
    return ResponseBody.fromString(jsonEncode(body), 200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        });
  }
}

void main() {
  test('createJob POSTs to /api/v1/jobs and maps the envelope', () async {
    final adapter = _FakeAdapter((options) {
      expect(options.method, 'POST');
      expect(options.path, '/api/v1/jobs');
      expect(options.headers['Authorization'], 'Bearer tok');
      expect(options.headers[Headers.contentTypeHeader], contains('application/json'));
      final payload = options.data is String
          ? jsonDecode(options.data as String) as Map<String, dynamic>
          : (options.data as Map<String, dynamic>);
      expect(payload['kind'], 'analyze');
      return {
        'status': 'ok',
        'data': {
          'id': 'j1',
          'user_id': 'u1',
          'kind': 'analyze',
          'status': 'queued',
          'created_at': '2026-01-01T00:00:00Z',
          'updated_at': '2026-01-01T00:00:00Z',
        },
      };
    });

    final client = EngineClient(
      baseUrl: 'https://engine.test',
      dio: Dio()..httpClientAdapter = adapter,
    )..setAuthToken('tok');

    final job = await client.createJob(
        userId: 'u1', kind: JobKind.analyze, inputRef: 'audio-ref');

    expect(job.id, 'j1');
    expect(job.kind, JobKind.analyze);
    expect(job.status, JobStatus.queued);
  });

  test('throws EngineFailure with message on error envelope', () async {
    final adapter = _FakeAdapter((_) => {
          'status': 'error',
          'error': {'code': 'JOB_FAILED', 'message': 'boom'},
        });
    final client = EngineClient(
      baseUrl: 'https://engine.test',
      dio: Dio()..httpClientAdapter = adapter,
    );

    expect(
      () => client.createJob(userId: 'u1', kind: JobKind.transcribe),
      throwsA(isA<EngineFailure>().having((e) => e.message, 'message', 'boom')),
    );
  });

  test('UnavailableEngineGateway reports configuration problem', () async {
    const gateway = UnavailableEngineGateway();
    expect(
      () => gateway.getJob('u1', 'j1'),
      throwsA(isA<EngineFailure>()),
    );
  });

  test('streamJob parses SSE frames and emits live jobs in order', () async {
    final frames = [
      'event: job\ndata: {"id":"j1","user_id":"u1","kind":"analyze",'
          '"status":"queued","stage":null,"session_status":"uploading",'
          '"stage_label":"Transcribing","created_at":"2026-01-01T00:00:00Z",'
          '"updated_at":"2026-01-01T00:00:00Z"}\n\n',
      'event: progress\ndata: {"session_status":"cleaning","stage":"cleanup",'
          '"stage_label":"Cleaning up","job_status":"running"}\n\n',
      'event: progress\ndata: {"session_status":"analyzing","stage":"classification",'
          '"stage_label":"Classifying","job_status":"running"}\n\n',
      'event: done\ndata: {"id":"j1","user_id":"u1","kind":"analyze",'
          '"status":"succeeded","stage":null,"session_status":"ready",'
          '"stage_label":"Validating","created_at":"2026-01-01T00:00:00Z",'
          '"updated_at":"2026-01-01T00:00:00Z"}\n\n',
    ].join();

    final adapter = _StreamAdapter(Stream.value(utf8.encode(frames)));
    final client = EngineClient(
      baseUrl: 'https://engine.test',
      dio: Dio()..httpClientAdapter = adapter,
    )..setAuthToken('tok');

    final jobs = await client.streamJob('u1', 'j1').toList();

    expect(jobs, hasLength(4));
    expect(jobs[0].status, JobStatus.queued);
    expect(jobs[0].sessionStatus, 'uploading');
    expect(jobs[1].status, JobStatus.running);
    expect(jobs[1].stage, 'cleanup');
    expect(jobs[1].sessionStatus, 'cleaning');
    expect(jobs[1].stageLabel, 'Cleaning up');
    expect(jobs[2].stage, 'classification');
    expect(jobs[2].sessionStatus, 'analyzing');
    expect(jobs[3].status, JobStatus.succeeded);
    expect(jobs[3].sessionStatus, 'ready');
  });

  test('streamJob handles frames split across network chunks', () async {
    final chunks = Stream.fromIterable([
      utf8.encode('event: job\ndata: {"id":"j1","user_id":"u1","kind":"analy'),
      utf8.encode(
          'ze","status":"queued","stage":null,"session_status":"uploading",'
          '"stage_label":"Transcribing","created_at":"2026-01-01T00:00:00Z",'
          '"updated_at":"2026-01-01T00:00:00Z"}\n\n'),
      utf8.encode('event: failed\ndata: {"id":"j1","user_id":"u1","kind":"analyze",'
          '"status":"failed","stage":"cleanup","session_status":"failed",'
          '"stage_label":"Cleaning up","created_at":"2026-01-01T00:00:00Z",'
          '"updated_at":"2026-01-01T00:00:00Z","error":{"code":"JOB_FAILED",'
          '"message":"boom"}}\n\n'),
    ]);

    final client = EngineClient(
      baseUrl: 'https://engine.test',
      dio: Dio()..httpClientAdapter = _StreamAdapter(chunks),
    )..setAuthToken('tok');

    final jobs = await client.streamJob('u1', 'j1').toList();

    expect(jobs, hasLength(2));
    expect(jobs.first.status, JobStatus.queued);
    expect(jobs.last.status, JobStatus.failed);
    expect(jobs.last.errorJson, contains('boom'));
  });
}

class _StreamAdapter implements HttpClientAdapter {
  _StreamAdapter(this.bytes);

  final Stream<List<int>> bytes;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    expect(options.method, 'GET');
    expect(options.path, '/api/v1/jobs/j1/stream');
    expect(options.responseType, ResponseType.stream);
    return ResponseBody(
      bytes.map(Uint8List.fromList),
      200,
      headers: {
        Headers.contentTypeHeader: ['text/event-stream'],
      },
    );
  }
}
