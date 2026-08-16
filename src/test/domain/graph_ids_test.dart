import 'package:flutter_test/flutter_test.dart';

import 'package:ai_knowledge_companion/domain/entities/graph_ids.dart';

void main() {
  group('graph_ids', () {
    test('graphEntityId matches engine uuid5 (deterministic ids)', () {
      expect(graphEntityId('Alice'), '4d551235-1e06-5ff8-930d-5e31697350fd');
      expect(
        graphEntityId('Benchmark Platform'),
        'b5057709-57c0-5d84-bffa-3a156a12884f',
      );
      // Deterministic: the same exact name always yields the same id.
      expect(graphEntityId('Alice'), graphEntityId('Alice'));
    });

    test('graphRelationshipId is per-session', () {
      final a = graphRelationshipId(
        sessionId: 's1',
        sourceId: 'a',
        targetId: 'b',
        type: 'depends_on',
      );
      expect(a, '9c97d5a8-c128-5075-8890-dad2a2dfc375');
      final b = graphRelationshipId(
        sessionId: 's2',
        sourceId: 'a',
        targetId: 'b',
        type: 'depends_on',
      );
      expect(a, isNot(b));
    });
  });
}
