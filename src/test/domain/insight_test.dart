import 'package:ai_knowledge_companion/domain/entities/insight.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Insight round-trips through canonical JSON', () {
    const insight = Insight(
      kind: InsightKind.entity,
      label: 'Benchmark Platform',
      sessionCount: 3,
      mentionCount: 4,
      confidence: 0.65,
      statement: "You've discussed Benchmark Platform in 3 sessions.",
      sources: [
        InsightSource(
          sessionId: 's1',
          title: 'Benchmark planning',
          snippet: 'Run Benchmark Platform nightly.',
        ),
      ],
    );

    final json = insight.toJson();
    expect(json['kind'], 'entity');
    expect(json['session_count'], 3);

    final back = Insight.fromJson(json);
    expect(back.kind, InsightKind.entity);
    expect(back.label, 'Benchmark Platform');
    expect(back.sessionCount, 3);
    expect(back.confidence, 0.65);
    expect(back.sources.single.sessionId, 's1');
    expect(back.sources.single.snippet, 'Run Benchmark Platform nightly.');
  });

  test('InsightResult.fromJson matches the engine contract shape', () {
    final result = InsightResult.fromJson({
      'insights': [
        {
          'kind': 'entity',
          'label': 'Benchmark Platform',
          'session_count': 2,
          'mention_count': 2,
          'confidence': 0.5,
          'statement': "You've discussed Benchmark Platform in 2 sessions.",
          'sources': [
            {'session_id': 's1', 'title': 'Benchmark planning', 'snippet': null},
            {'session_id': 's2', 'title': 'Deep dive', 'snippet': '…Benchmark Platform…'},
          ],
        },
      ],
      'generated_at': '2026-08-10T05:20:03+00:00',
      'total_sessions': 2,
    });

    expect(result.totalSessions, 2);
    expect(result.generatedAt, isNotNull);
    expect(result.insights, hasLength(1));
    expect(result.insights.single.sources, hasLength(2));
    expect(result.insights.single.sources[1].snippet, '…Benchmark Platform…');
  });

  test('Insight tolerates malformed fields', () {
    final result = InsightResult.fromJson(const {'insights': []});
    expect(result.insights, isEmpty);
    expect(result.totalSessions, 0);

    final insight = Insight.fromJson(const {'label': 'x'});
    expect(insight.kind, InsightKind.entity);
    expect(insight.label, 'x');
    expect(insight.sessionCount, 0);
    expect(insight.sources, isEmpty);
  });

  test('tag kind parses from the wire name', () {
    final insight = Insight.fromJson(const {
      'kind': 'tag',
      'label': 'planning',
      'session_count': 2,
      'mention_count': 2,
      'confidence': 0.5,
      'statement': "You've used the tag 'planning' in 2 sessions.",
      'sources': [],
    });
    expect(insight.kind, InsightKind.tag);
  });
}
