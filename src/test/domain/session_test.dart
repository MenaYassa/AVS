import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Item', () {
    test('JSON round-trip preserves fields and confidence', () {
      const item = Item(
        id: 'i1',
        type: ItemType.task,
        title: 'Add caching',
        description: 'To the benchmark platform',
        position: 2,
        priority: Priority.high,
        timestampSec: 12.5,
        confidence: 0.95,
      );
      final decoded = Item.fromJson(item.toJson());
      expect(decoded.id, item.id);
      expect(decoded.type, ItemType.task);
      expect(decoded.title, item.title);
      expect(decoded.position, 2);
      expect(decoded.priority, Priority.high);
      expect(decoded.timestampSec, 12.5);
      expect(decoded.confidence, 0.95);
    });

    test('unknown type falls back to idea', () {
      final item = Item.fromJson({'id': 'x', 'type': 'banana'});
      expect(item.type, ItemType.idea);
    });

    test('copyWith can clear optional fields', () {
      const item = Item(
        id: 'i1',
        type: ItemType.task,
        title: 't',
        priority: Priority.high,
        confidence: 0.5,
      );
      final cleared = item.copyWith(clearPriority: true, clearConfidence: true);
      expect(cleared.priority, isNull);
      expect(cleared.confidence, isNull);
    });
  });

  group('Session', () {
    test('canonical JSON round-trip preserves the knowledge tree', () {
      const session = Session(
        id: 's1',
        userId: 'u1',
        title: 'Planning',
        summary: 'A one paragraph summary',
        status: SessionStatus.ready,
        promptVersions: {'cleanup': 9, 'knowledge_extraction': 5},
        topics: [
          Topic(
            id: 't1',
            title: 'Benchmark',
            position: 0,
            confidence: 0.92,
            items: [
              Item(
                id: 'i1',
                type: ItemType.decision,
                title: 'Use Supabase',
                confidence: 0.88,
              ),
            ],
          ),
        ],
      );

      final json = session.toCanonicalJson();
      final round =
          Session.fromCanonicalJson(json, userId: 'u1', createdAt: session.createdAt);

      expect(round.id, 's1');
      expect(round.title, 'Planning');
      expect(round.summary, 'A one paragraph summary');
      expect(round.promptVersions['cleanup'], 9);
      expect(round.topics.single.title, 'Benchmark');
      expect(round.topics.single.items.single.type, ItemType.decision);
    });

    test('processing states are terminal/processing as expected', () {
      expect(SessionStatus.failed.isTerminal, isTrue);
      expect(SessionStatus.cancelled.isTerminal, isTrue);
      expect(SessionStatus.ready.isTerminal, isFalse);
      expect(SessionStatus.transcribing.isProcessing, isTrue);
      expect(SessionStatus.analyzing.isProcessing, isTrue);
      expect(SessionStatus.ready.isProcessing, isFalse);
    });
  });
}
