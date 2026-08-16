import 'dart:convert';

import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/job.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fromJson normalizes nested engine payloads to JSON strings', () {
    final job = Job.fromJson({
      'id': 'j1',
      'user_id': 'u1',
      'kind': 'analyze',
      'status': 'succeeded',
      'session_status': 'ready',
      'stage_label': 'Validating',
      'intermediates': {
        'cleanup': {
          'cleaned_text': 'cleaned',
          'original_text': 'original',
        },
      },
      'result': {'schema_version': 1, 'session': {'id': 's1'}},
      'error': {'code': 'X', 'message': 'boom'},
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    });

    expect(job.sessionStatus, 'ready');
    expect(job.resultJson, isNotNull);
    expect(
      (jsonDecode(job.resultJson!) as Map)['schema_version'],
      1,
    );
    final cleanup =
        (jsonDecode(job.intermediatesJson!) as Map<String, dynamic>)['cleanup']
            as Map<String, dynamic>;
    expect(cleanup['cleaned_text'], 'cleaned');
    expect(job.errorJson, contains('boom'));
  });

  test('fromJson passes string payloads through unchanged', () {
    final job = Job.fromJson({
      'id': 'j1',
      'user_id': 'u1',
      'kind': 'analyze',
      'status': 'failed',
      'error': '{"code":"X","message":"boom"}',
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    });
    expect(job.errorJson, '{"code":"X","message":"boom"}');
  });

  test('copyWith overrides lifecycle fields and preserves ids', () {
    final job = Job(
      id: 'j1',
      userId: 'u1',
      kind: JobKind.analyze,
      status: JobStatus.queued,
    );
    final next = job.copyWith(
      status: JobStatus.running,
      stage: 'cleanup',
      sessionStatus: 'cleaning',
      stageLabel: 'Cleaning up',
    );
    expect(next.id, 'j1');
    expect(next.status, JobStatus.running);
    expect(next.stage, 'cleanup');
    expect(next.sessionStatus, 'cleaning');
    expect(next.stageLabel, 'Cleaning up');
    expect(next.kind, JobKind.analyze);
  });
}
