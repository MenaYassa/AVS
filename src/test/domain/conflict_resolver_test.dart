import 'package:ai_knowledge_companion/domain/editing/conflict_resolver.dart';
import 'package:ai_knowledge_companion/domain/editing/edit_operations.dart';
import 'package:ai_knowledge_companion/domain/editing/oplog_diff.dart';
import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:flutter_test/flutter_test.dart';

/// Two-device offline simulation (architecture §4.13, roadmap §3.5): both
/// devices share a [base], diverge offline, and the resolver replays one
/// device's op-log diff onto the other's [remote] state. Results must be
/// deterministic and lossless.
Session _session({List<Topic>? topics, String? title}) => Session(
      id: 's1',
      userId: 'u1',
      title: title ?? 'Planning',
      status: SessionStatus.ready,
      topics: topics ?? const [],
    );

List<Topic> _twoTopics() => [
      Topic(
        id: 't1',
        position: 0,
        title: 'Budget',
        items: [
          Item(id: 'i1', type: ItemType.task, position: 0, title: 'A', confidence: 0.9),
          Item(id: 'i2', type: ItemType.idea, position: 1, title: 'B', confidence: 0.8),
        ],
      ),
      Topic(
        id: 't2',
        position: 1,
        title: 'Roadmap',
        items: [
          Item(id: 'i3', type: ItemType.event, position: 0, title: 'C', confidence: 0.7),
        ],
      ),
    ];

void main() {
  const resolver = ConflictResolver();

  group('clean replay (no remote changes)', () {
    test('applies the diff onto the remote and flags nothing', () {
      final base = _session(topics: _twoTopics());
      final local = const RenameTopic(
        topicId: 't1',
        oldTitle: 'Budget',
        newTitle: 'Finances',
      ).apply(base);
      final diff = OplogDiff(
        sessionId: 's1',
        base: base,
        batches: [
          [
            const RenameTopic(
              topicId: 't1',
              oldTitle: 'Budget',
              newTitle: 'Finances',
            ),
          ],
        ],
      );

      final result = resolver.resolve(remote: base, diff: diff);

      expect(result.conflicts, isEmpty);
      expect(result.merged.title, base.title);
      expect(result.merged.topics.first.title, 'Finances');
      // Merged == local state exactly.
      expect(result.merged.toCanonicalJson(), local.toCanonicalJson());
    });

    test('a plain AddTopic lands at its recorded position', () {
      final base = _session(topics: _twoTopics());
      final added = Topic(
        id: 't3',
        title: 'People',
        position: 1,
        items: [Item(id: 'i9', type: ItemType.idea, position: 0, title: 'X')],
      );
      final diff = OplogDiff(
        sessionId: 's1',
        base: base,
        batches: [
          [AddTopic(topic: added, position: 1)],
        ],
      );

      final result = resolver.resolve(remote: base, diff: diff);

      expect(result.conflicts, isEmpty);
      expect(result.merged.topics.map((t) => t.id), ['t1', 't3', 't2']);
    });

    test('sequential edits to the same field do not cause false conflicts', () {
      final base = _session(title: 'A');
      final diff = OplogDiff(
        sessionId: 's1',
        base: base,
        batches: [
          [
            const UpdateSessionTitle(oldTitle: 'A', newTitle: 'B'),
          ],
          [
            const UpdateSessionTitle(oldTitle: 'B', newTitle: 'C'),
          ],
        ],
      );

      final result = resolver.resolve(remote: base, diff: diff);

      expect(result.conflicts, isEmpty);
      expect(result.merged.title, 'C');
    });
  });

  group('field-level LWW (architecture §4.13)', () {
    test('remote title edit conflicts; local wins and the remote value is kept',
        () {
      final base = _session(title: 'Planning');
      final remote = base.copyWith(title: 'Roadmap (remote)');
      final diff = OplogDiff(
        sessionId: 's1',
        base: base,
        batches: [
          [
            const UpdateSessionTitle(oldTitle: 'Planning', newTitle: 'Budget'),
          ],
        ],
      );

      final result = resolver.resolve(remote: remote, diff: diff);

      expect(result.merged.title, 'Budget'); // local wins (LWW)
      final conflict = result.conflicts.single as FieldConflict;
      expect(conflict.fieldPath, 'session.title');
      expect(conflict.remoteValue, 'Roadmap (remote)');
      expect(conflict.localValue, 'Budget');
    });

    test('both devices setting the same value is not a conflict', () {
      final base = _session(title: 'Planning');
      final remote = base.copyWith(title: 'Budget');
      final diff = OplogDiff(
        sessionId: 's1',
        base: base,
        batches: [
          [
            const UpdateSessionTitle(oldTitle: 'Planning', newTitle: 'Budget'),
          ],
        ],
      );

      final result = resolver.resolve(remote: remote, diff: diff);

      expect(result.conflicts, isEmpty);
      expect(result.merged.title, 'Budget');
    });

    test('concurrent item text edit is flagged and local content wins', () {
      final base = _session(topics: _twoTopics());
      final remote = base.copyWith(
        topics: [
          base.topics.first.copyWith(
            items: [
              base.topics.first.items.first.copyWith(title: 'A (remote)'),
              base.topics.first.items[1],
            ],
          ),
          base.topics[1],
        ],
      );
      final diff = OplogDiff(
        sessionId: 's1',
        base: base,
        batches: [
          [
            const UpdateItemText(
              topicId: 't1',
              itemId: 'i1',
              oldTitle: 'A',
              oldDescription: '',
              newTitle: 'Finalize',
              newDescription: '',
              oldConfidence: 0.9,
            ),
          ],
        ],
      );

      final result = resolver.resolve(remote: remote, diff: diff);

      final conflict = result.conflicts.single as FieldConflict;
      expect(conflict.fieldPath, 'item.i1.title/description');
      expect(conflict.remoteValue, contains('A (remote)'));
      final item = result.merged.topics.first.items.first;
      expect(item.title, 'Finalize');
      expect(item.confidence, isNull); // human edit clears AI confidence
    });
  });

  group('structural conflicts (target deleted on the remote)', () {
    test('rename of a deleted topic is skipped and flagged', () {
      final base = _session(topics: _twoTopics());
      // Remote deleted t1 entirely (e.g. the other device deleted it).
      final remote = base.copyWith(topics: [base.topics[1]]);
      final diff = OplogDiff(
        sessionId: 's1',
        base: base,
        batches: [
          [
            const RenameTopic(
              topicId: 't1',
              oldTitle: 'Budget',
              newTitle: 'Finances',
            ),
          ],
        ],
      );

      final result = resolver.resolve(remote: remote, diff: diff);

      expect(result.conflicts.single, isA<StructuralConflict>());
      expect(result.merged.topics.map((t) => t.id), ['t2']); // remote wins
    });

    test('local delete of an already-deleted topic converges silently', () {
      final base = _session(topics: _twoTopics());
      final remote = base.copyWith(topics: [base.topics[1]]);
      final diff = OplogDiff(
        sessionId: 's1',
        base: base,
        batches: [
          [DeleteTopic(topic: base.topics.first)],
        ],
      );

      final result = resolver.resolve(remote: remote, diff: diff);

      expect(result.conflicts, isEmpty);
      expect(result.merged.topics.map((t) => t.id), ['t2']);
    });
  });

  group('offline structural edits replay correctly', () {
    test('split made offline applies onto a remote that gained items', () {
      final base = _session(topics: _twoTopics());
      // Remote added a new item to t1 while the local device was offline.
      final remote = base.copyWith(
        topics: [
          base.topics.first.copyWith(
            items: [
              ...base.topics.first.items,
              const Item(
                id: 'i4',
                type: ItemType.decision,
                position: 2,
                title: 'D',
              ),
            ],
          ),
          base.topics[1],
        ],
      );
      final diff = OplogDiff(
        sessionId: 's1',
        base: base,
        batches: [
          [
            const SplitTopic(
              targetId: 't1',
              sourceId: 't3',
              title: 'Ideas',
              description: '',
              position: 1,
              movedItems: [
                Item(id: 'i2', type: ItemType.idea, position: 1, title: 'B', confidence: 0.8),
              ],
            ),
          ],
        ],
      );

      final result = resolver.resolve(remote: remote, diff: diff);

      expect(result.conflicts, isEmpty);
      final byId = {for (final t in result.merged.topics) t.id: t};
      expect(byId['t3'], isNotNull);
      expect(byId['t3']!.items.single.id, 'i2'); // the split item moved out
      expect(byId['t1']!.items.map((i) => i.id), ['i1', 'i4']); // kept + remote's
    });

    test('split of items the remote already moved is flagged and skipped', () {
      final base = _session(topics: _twoTopics());
      // Remote moved i2 into t2 while offline.
      final remote = base.copyWith(
        topics: [
          base.topics.first.copyWith(items: [base.topics.first.items.first]),
          base.topics[1].copyWith(items: [
            base.topics[1].items.first,
            const Item(id: 'i2', type: ItemType.idea, position: 1, title: 'B', confidence: 0.8),
          ]),
        ],
      );
      final diff = OplogDiff(
        sessionId: 's1',
        base: base,
        batches: [
          [
            const SplitTopic(
              targetId: 't1',
              sourceId: 't3',
              title: 'Ideas',
              description: '',
              position: 1,
              movedItems: [
                Item(id: 'i2', type: ItemType.idea, position: 1, title: 'B', confidence: 0.8),
              ],
            ),
          ],
        ],
      );

      final result = resolver.resolve(remote: remote, diff: diff);

      expect(result.conflicts.single, isA<StructuralConflict>());
      // Remote state untouched (no t3 topic, i2 stays in t2).
      expect(result.merged.topics.any((t) => t.id == 't3'), isFalse);
    });

    test('merge made offline applies onto the remote state', () {
      final base = _session(topics: _twoTopics());
      final diff = OplogDiff(
        sessionId: 's1',
        base: base,
        batches: [
          [
            MergeTopics(
              source: base.topics[1],
              targetId: 't1',
            ),
          ],
        ],
      );

      final result = resolver.resolve(remote: base, diff: diff);

      expect(result.conflicts, isEmpty);
      expect(result.merged.topics.map((t) => t.id), ['t1']);
      // Source items land at their snapshot positions (i3 was at position 0).
      expect(result.merged.topics.first.items.map((i) => i.id), ['i3', 'i1', 'i2']);
    });

    test('reorder against a remote that also reordered is deterministic', () {
      final base = _session(topics: [
        const Topic(id: 't1', position: 0, title: 'One'),
        const Topic(id: 't2', position: 1, title: 'Two'),
        const Topic(id: 't3', position: 2, title: 'Three'),
      ]);
      // Remote moved t3 to the front offline.
      final remote = base.copyWith(
        topics: [
          base.topics[2],
          base.topics[0],
          base.topics[1],
        ],
      );
      final diff = OplogDiff(
        sessionId: 's1',
        base: base,
        batches: [
          [
            const ReorderTopic(topicId: 't1', from: 0, to: 2),
          ],
        ],
      );

      final result = resolver.resolve(remote: remote, diff: diff);

      expect(result.conflicts, isEmpty);
      // Local intent "t1 to the end" translates to "t1 in front of t3" (t3 is
      // at the remote front); the interleaving is fixed and reproducible.
      expect(result.merged.topics.map((t) => t.id), ['t1', 't3', 't2']);
    });

    test('remote adding a topic shifts a local AddTopic via id anchors', () {
      final base = _session(topics: _twoTopics());
      // Remote inserted a topic at the front offline.
      final remote = base.copyWith(
        topics: [
          const Topic(id: 'r0', position: 0, title: 'Remote first'),
          base.topics[0],
          base.topics[1],
        ],
      );
      final diff = OplogDiff(
        sessionId: 's1',
        base: base,
        batches: [
          [
            AddTopic(
              topic: const Topic(
                id: 't3',
                title: 'People',
                position: 1,
                items: [
                  Item(id: 'i9', type: ItemType.idea, position: 0, title: 'X'),
                ],
              ),
              position: 1,
            ),
          ],
        ],
      );

      final result = resolver.resolve(remote: remote, diff: diff);

      expect(result.conflicts, isEmpty);
      // "Between t1 and t2" still maps to before t2, so t3 lands in place and
      // the remote's r0 keeps the lead.
      expect(result.merged.topics.map((t) => t.id), ['r0', 't1', 't3', 't2']);
    });

    test('move made offline lands in the remote destination topic', () {
      final base = _session(topics: _twoTopics());
      final diff = OplogDiff(
        sessionId: 's1',
        base: base,
        batches: [
          [
            const MoveItem(
              fromTopicId: 't1',
              toTopicId: 't2',
              position: 1,
              originalPosition: 1,
              item: Item(
                id: 'i2',
                type: ItemType.idea,
                position: 1,
                title: 'B',
                confidence: 0.8,
              ),
            ),
          ],
        ],
      );

      final result = resolver.resolve(remote: base, diff: diff);

      expect(result.conflicts, isEmpty);
      final byId = {for (final t in result.merged.topics) t.id: t};
      expect(byId['t1']!.items.map((i) => i.id), ['i1']);
      expect(byId['t2']!.items.map((i) => i.id), ['i3', 'i2']);
    });
  });

  group('OplogDiff serialization', () {
    test('toJson/fromJson round-trips base + batches', () {
      final base = _session(topics: _twoTopics());
      final diff = OplogDiff(
        sessionId: 's1',
        base: base,
        emittedAt: DateTime.utc(2026, 8, 7),
        batches: [
          [
            const UpdateSessionTitle(oldTitle: 'Planning', newTitle: 'Budget'),
            const RenameTopic(
              topicId: 't1',
              oldTitle: 'Budget',
              newTitle: 'Finances',
            ),
          ],
        ],
      );

      final round = OplogDiff.fromJson(diff.toJson());

      expect(round.sessionId, 's1');
      expect(round.base.toCanonicalJson(), base.toCanonicalJson());
      expect(round.batches, hasLength(1));
      expect(round.batches.first, hasLength(2));
      expect(round.batches.first.first, isA<UpdateSessionTitle>());
      expect(round.batches.first.last, isA<RenameTopic>());
      expect(round.emittedAt, DateTime.utc(2026, 8, 7));
    });
  });
}
