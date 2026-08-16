import 'package:ai_knowledge_companion/domain/editing/edit_operations.dart';
import 'package:ai_knowledge_companion/domain/editing/operation_log.dart';
import 'package:ai_knowledge_companion/domain/editing/oplog_diff.dart';
import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:ai_knowledge_companion/domain/usecases/edit_session.dart';
import 'package:flutter_test/flutter_test.dart';

Session _session({
  List<Topic>? topics,
  String? title = 'Root',
  String? summary = 'S',
}) =>
    Session(
      id: 's1',
      userId: 'u1',
      title: title,
      summary: summary,
      status: SessionStatus.ready,
      topics: topics ?? _twoTopics(),
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

/// Verifies the invariant contract: sorted positions, no orphans, no dup ids.
void _expectWellFormed(Session s) {
  for (var t = 0; t < s.topics.length; t++) {
    expect(s.topics[t].position, t);
    final ids = s.topics[t].items.map((i) => i.id).toSet();
    expect(ids.length, s.topics[t].items.length, reason: 'dup item ids');
    for (var i = 0; i < s.topics[t].items.length; i++) {
      expect(s.topics[t].items[i].position, i);
    }
  }
  final tids = s.topics.map((t) => t.id).toSet();
  expect(tids.length, s.topics.length, reason: 'dup topic ids');
}

/// Inverse round-trip: applying `op` then `op.inverse()` must restore the
/// original session exactly.
void _expectInverse(Session original, EditOperation op) {
  final forward = op.apply(original);
  _expectWellFormed(forward);
  final back = op.inverse().apply(forward);
  _expectWellFormed(back);
  expect(back.toCanonicalJson(), original.toCanonicalJson(),
      reason: 'inverse of ${op.type} failed to restore');
}

void main() {
  group('edit operations (architecture §3.4)', () {
    test('text edits mutate content and clear AI confidence', () {
      final s = _session();
      final next = const UpdateItemText(
        topicId: 't1',
        itemId: 'i1',
        oldTitle: 'A',
        oldDescription: '',
        newTitle: 'Finalize the budget',
        newDescription: 'Due Friday',
        oldConfidence: 0.9,
      ).apply(s);
      expect(next.topics.first.items.first.title, 'Finalize the budget');
      expect(next.topics.first.items.first.description, 'Due Friday');
      expect(next.topics.first.items.first.confidence, isNull);
    });

    test('transcript edit replaces the cleaned transcript only', () {
      final s = _session().copyWith(
        originalTranscript: 'um the budget',
        cleanedTranscript: 'The budget',
      );
      const op = UpdateSessionTranscript(
        oldTranscript: 'The budget',
        newTranscript: 'The budget is due Friday.',
      );
      final next = op.apply(s);
      expect(next.cleanedTranscript, 'The budget is due Friday.');
      expect(next.originalTranscript, 'um the budget');
      expect(next.topics, s.topics);
      expect(op.inverse().apply(next).toCanonicalJson(), s.toCanonicalJson());
    });

    test('type/priority/confidence changes', () {
      final s = _session();
      final typed = const ChangeItemType(
        topicId: 't1', itemId: 'i1', oldType: 'task', newType: 'decision',
        oldConfidence: 0.9,
      ).apply(s);
      expect(typed.topics.first.items.first.type, ItemType.decision);
      expect(typed.topics.first.items.first.confidence, isNull);

      final prioritized = const SetItemPriority(
        topicId: 't1', itemId: 'i1', oldPriority: null, newPriority: 'high',
      ).apply(s);
      expect(prioritized.topics.first.items.first.priority, Priority.high);

      final confidence = const SetItemConfidence(
        topicId: 't1', itemId: 'i1', oldConfidence: 0.9, newConfidence: 0.3,
      ).apply(s);
      expect(confidence.topics.first.items.first.confidence, 0.3);
    });

    test('add/delete topic renumbers and keeps other topics', () {
      final s = _session();
      final added = AddTopic(
        topic: Topic(id: 't9', position: 1, title: 'New'),
        position: 1,
      ).apply(s);
      _expectWellFormed(added);
      expect(added.topics[1].id, 't9');

      final deleted = const DeleteTopic(topic: Topic(id: 't1', position: 0, title: 'Budget')).apply(s);
      _expectWellFormed(deleted);
      expect(deleted.topics.single.id, 't2');
    });

    test('merge absorbs items; split moves them into a new topic', () {
      final s = _session();
      final merged = MergeTopics(
        source: s.topics.first, // t1 Budget
        targetId: 't2',
      ).apply(s);
      _expectWellFormed(merged);
      expect(merged.topics.single.id, 't2');
      expect(merged.topics.single.items, hasLength(3));

      final split = SplitTopic(
        targetId: 't2',
        sourceId: 't1',
        title: 'Budget',
        description: '',
        position: 0,
        movedItems: merged.topics.single.items.sublist(0, 2),
      ).apply(merged);
      _expectWellFormed(split);
      expect(split.topics, hasLength(2));
      expect(split.topics.first.id, 't1');
      expect(split.topics.first.items, hasLength(2));
      expect(split.topics.last.items.single.id, 'i3');
    });

    test('move item across topics and within a topic', () {
      final s = _session();
      final moved = MoveItem(
        fromTopicId: 't1',
        toTopicId: 't2',
        position: 1,
        originalPosition: 0,
        item: s.topics.first.items.first,
      ).apply(s);
      _expectWellFormed(moved);
      expect(moved.topics.last.items, hasLength(2));
      expect(moved.topics.last.items[1].id, 'i1');
      expect(moved.topics.first.items.single.id, 'i2');
      // Structural moves preserve AI confidence (only content edits clear it).
      expect(moved.topics.last.items[1].confidence, 0.9);

      // within-topic move must not duplicate
      final within = MoveItem(
        fromTopicId: 't1',
        toTopicId: 't1',
        position: 2,
        originalPosition: 0,
        item: s.topics.first.items.first,
      ).apply(s);
      _expectWellFormed(within);
      expect(within.topics.first.items, hasLength(2));
    });

    test('reorder topic', () {
      final s = _session();
      final reordered = const ReorderTopic(topicId: 't1', from: 0, to: 1).apply(s);
      _expectWellFormed(reordered);
      expect(reordered.topics.first.id, 't2');
      expect(reordered.topics.last.id, 't1');
    });

    test('inverse round-trips restore the exact original session', () {
      final s = _session();
      for (final op in <EditOperation>[
        const RenameTopic(topicId: 't1', oldTitle: 'Budget', newTitle: 'Finances'),
        const UpdateItemText(
          topicId: 't1', itemId: 'i1',
          oldTitle: 'A', oldDescription: '', newTitle: 'X', newDescription: 'Y',
          oldConfidence: 0.9,
        ),
        const ChangeItemType(
          topicId: 't1', itemId: 'i1', oldType: 'task', newType: 'idea',
          oldConfidence: 0.9,
        ),
        const SetItemPriority(topicId: 't1', itemId: 'i1', oldPriority: null, newPriority: 'high'),
        AddTopic(topic: Topic(id: 't9', position: 0, title: 'New'), position: 0),
        DeleteTopic(topic: s.topics.first),
        MergeTopics(source: s.topics.first, targetId: 't2'),
        SplitTopic(
          targetId: 't1', sourceId: 't9', title: 'Split', description: '',
          position: 1, movedItems: [s.topics.first.items.first],
        ),
        const ReorderTopic(topicId: 't1', from: 0, to: 1),
        InsertItem(topicId: 't1', position: 0, item: const Item(id: 'i9', type: ItemType.question, title: 'Q', confidence: 0.5)),
        DeleteItem(topicId: 't1', item: s.topics.first.items.first),
        MoveItem(
          fromTopicId: 't1', toTopicId: 't2', position: 0, originalPosition: 0,
          item: s.topics.first.items.first,
        ),
        const UpdateSessionTitle(oldTitle: 'Root', newTitle: 'Renamed'),
        const UpdateSessionSummary(oldSummary: 'S', newSummary: 'New summary'),
        const UpdateSessionTranscript(
          oldTranscript: 'um we need to uh finalize the budget by Friday',
          newTranscript: 'We need to finalize the budget by Friday.',
        ),
      ]) {
        _expectInverse(s, op);
      }
    });

    test('json round-trips every operation type', () {
      final s = _session();
      final ops = <EditOperation>[
        const RenameTopic(topicId: 't1', oldTitle: 'a', newTitle: 'b'),
        AddTopic(topic: Topic(id: 't9', position: 0, title: 'N'), position: 0),
        DeleteTopic(topic: s.topics.first),
        MergeTopics(source: s.topics.first, targetId: 't2'),
        const SplitTopic(
          targetId: 't1', sourceId: 't9', title: 'S', description: 'd',
          position: 1,
          movedItems: [Item(id: 'i1', type: ItemType.task, position: 0, title: 'A', confidence: 0.9)],
        ),
        const ReorderTopic(topicId: 't1', from: 0, to: 1),
        InsertItem(topicId: 't1', position: 0, item: s.topics.first.items.first),
        DeleteItem(topicId: 't1', item: s.topics.first.items.first),
        MoveItem(
          fromTopicId: 't1', toTopicId: 't2', position: 0, originalPosition: 0,
          item: s.topics.first.items.first,
        ),
        const UpdateItemText(topicId: 't1', itemId: 'i1', oldTitle: 'a', oldDescription: '', newTitle: 'b', newDescription: '', oldConfidence: 0.9),
        const ChangeItemType(topicId: 't1', itemId: 'i1', oldType: 'task', newType: 'idea', oldConfidence: 0.9),
        const SetItemPriority(topicId: 't1', itemId: 'i1', oldPriority: null, newPriority: 'high'),
        const SetItemConfidence(topicId: 't1', itemId: 'i1', oldConfidence: 0.9, newConfidence: null),
        const UpdateSessionTitle(oldTitle: 'a', newTitle: 'b'),
        const UpdateSessionSummary(oldSummary: 'a', newSummary: 'b'),
        const UpdateSessionTranscript(oldTranscript: 'a', newTranscript: 'b'),
      ];
      for (final op in ops) {
        expect(
          EditOperation.fromJson(op.toJson()).toJson(),
          op.toJson(),
          reason: 'json round-trip for ${op.type}',
        );
      }
    });
  });

  group('operation log (architecture §3.4)', () {
    test('undo/redo walk the log and restore state', () {
      var s = _session();
      final log = OperationLog();
      s = log.applyOp(s,
          const UpdateSessionTitle(oldTitle: 'Root', newTitle: 'One'));
      s = log.applyOp(s,
          const RenameTopic(topicId: 't1', oldTitle: 'Budget', newTitle: 'Finances'));

      final afterTwo = s.toCanonicalJson();

      // First undo walks back one batch (the last applied: the rename).
      for (final op in log.undo()) {
        s = op.inverse().apply(s);
      }
      expect(s.title, 'One');
      expect(s.topics.first.title, 'Budget');

      // Second undo reaches the state before any edit.
      for (final op in log.undo()) {
        s = op.inverse().apply(s);
      }
      expect(s.toCanonicalJson(), _session().toCanonicalJson());
      expect(log.canUndo, isFalse);

      // Redo replays forward to the fully-edited state.
      for (final op in log.redo()) {
        s = op.apply(s);
      }
      expect(s.title, 'One');
      expect(s.topics.first.title, 'Budget');

      for (final op in log.redo()) {
        s = op.apply(s);
      }
      expect(s.toCanonicalJson(), afterTwo);
      expect(log.canRedo, isFalse);
    });

    test('applying after an undo trims the redo tail', () {
      final log = OperationLog()
        ..apply(const RenameTopic(topicId: 't1', oldTitle: 'a', newTitle: 'b'))
        ..apply(const RenameTopic(topicId: 't1', oldTitle: 'b', newTitle: 'c'));
      log.undo();
      log.undo();
      expect(log.canRedo, isTrue);
      log.apply(const RenameTopic(topicId: 't1', oldTitle: 'a', newTitle: 'z'));
      expect(log.canRedo, isFalse);
    });

    test('batch coalesces into a single undo step', () {
      var s = _session();
      final log = OperationLog();
      log.beginBatch();
      log.record(const UpdateItemText(
          topicId: 't1', itemId: 'i1', oldTitle: 'A', oldDescription: '',
          newTitle: 'Aa', newDescription: '', oldConfidence: 0.9));
      log.record(const UpdateItemText(
          topicId: 't1', itemId: 'i1', oldTitle: 'Aa', oldDescription: '',
          newTitle: 'Aab', newDescription: '', oldConfidence: null));
      log.endBatch();
      expect(log.batchCount, 1);
      expect(log.canUndo, isTrue);

      final undone = log.undo();
      expect(undone, hasLength(2));
      for (final op in undone.reversed) {
        s = op.inverse().apply(s);
      }
      expect(s.topics.first.items.first.title, 'A');
      expect(s.topics.first.items.first.confidence, 0.9);
    });

    test('json round-trips a log with batches and cursor', () {
      final log = OperationLog()
        ..apply(const RenameTopic(topicId: 't1', oldTitle: 'a', newTitle: 'b'));
      log.beginBatch();
      log.record(const SetItemPriority(topicId: 't1', itemId: 'i1', oldPriority: null, newPriority: 'high'));
      log.endBatch();

      final restored = OperationLog.fromJson(log.toJson());
      expect(restored.batchCount, 2);
      expect(restored.appliedOps, hasLength(2));
      expect(restored.batches.last.single.type, 'SetItemPriority');
      expect(restored.cursor, 2);
      expect(restored.canUndo, isTrue);

      // An undo position survives serialization.
      log.undo();
      final afterUndo = OperationLog.fromJson(log.toJson());
      expect(afterUndo.cursor, 1);
      expect(afterUndo.canRedo, isTrue);
    });
  });

  group('sync watermark (architecture §4.13)', () {
    test('unsyncedDelta emits only the applied-but-unsynced tail', () {
      final log = OperationLog()
        ..apply(const RenameTopic(topicId: 't1', oldTitle: 'a', newTitle: 'b'));
      log.markSynced();
      expect(log.hasUnsyncedEdits, isFalse);
      log.apply(const RenameTopic(topicId: 't1', oldTitle: 'b', newTitle: 'c'));
      expect(log.hasUnsyncedEdits, isTrue);

      final delta = log.unsyncedDelta();
      expect(delta, hasLength(1));
      expect(delta.single.single.type, 'RenameTopic');
      expect((delta.single.single as RenameTopic).newTitle, 'c');
    });

    test('markSynced advances the watermark to the cursor', () {
      final log = OperationLog()
        ..apply(const RenameTopic(topicId: 't1', oldTitle: 'a', newTitle: 'b'))
        ..apply(const RenameTopic(topicId: 't1', oldTitle: 'b', newTitle: 'c'));
      log.markSynced();
      expect(log.syncWatermark, 2);
      expect(log.hasUnsyncedEdits, isFalse);
      expect(log.unsyncedDelta(), isEmpty);
    });

    test('an undo below the watermark emits inverse ops', () {
      final log = OperationLog()
        ..apply(const RenameTopic(topicId: 't1', oldTitle: 'a', newTitle: 'b'))
        ..apply(const RenameTopic(topicId: 't1', oldTitle: 'b', newTitle: 'c'));
      log.markSynced(); // both batches pushed; cloud holds [a -> c]
      log.undo(); // cursor rewinds to batch 1; cloud must converge back

      final delta = log.unsyncedDelta();
      expect(delta, hasLength(1));
      expect(delta.single.single.type, 'RenameTopic');
      expect((delta.single.single as RenameTopic).newTitle, 'b');
      // Replaying the delta from the cloud state restores the local state.
      final replayed = delta.single.fold<Session>(_session(), (s, op) => op.apply(s));
      expect(replayed.topics.first.title, 'b');
    });

    test('watermark survives JSON round-trip (backward compatible)', () {
      final log = OperationLog()
        ..apply(const RenameTopic(topicId: 't1', oldTitle: 'a', newTitle: 'b'));
      log.markSynced();
      final restored = OperationLog.fromJson(log.toJson());
      expect(restored.syncWatermark, 1);
      expect(restored.hasUnsyncedEdits, isFalse);

      // Old persisted logs without a watermark default to 0.
      final legacy = OperationLog.fromJson({
        'batches': [
          [
            const RenameTopic(
              topicId: 't1',
              oldTitle: 'a',
              newTitle: 'b',
            ).toJson(),
          ],
        ],
        'cursor': 1,
      });
      expect(legacy.syncWatermark, 0);
      expect(legacy.hasUnsyncedEdits, isTrue); // safe: re-emits from scratch
    });
  });

  group('EditSession use case (architecture §3.2)', () {
    test('apply persists session + log; undo restores via inverse', () async {
      final sessions = _MemorySessionRepo();
      final logs = _MemoryLogRepo();
      final original = _session();
      await sessions.upsert(original);
      final usecase = EditSession(sessions, logs);

      var result = await usecase.apply(
        session: original,
        log: OperationLog(),
        op: const RenameTopic(topicId: 't1', oldTitle: 'Budget', newTitle: 'Finances'),
      );
      expect(sessions.byId['s1']!.topics.first.title, 'Finances');
      expect(logs.byId['s1']!.canUndo, isTrue);

      result = await usecase.undo(session: result.session, log: result.log);
      expect(sessions.byId['s1']!.topics.first.title, 'Budget');
      expect(result.log.canUndo, isFalse);
      expect(result.log.canRedo, isTrue);

      result = await usecase.redo(session: result.session, log: result.log);
      expect(sessions.byId['s1']!.topics.first.title, 'Finances');
    });
  });
}

class _MemorySessionRepo implements SessionRepository {
  final Map<String, Session> byId = {};

  Future<void> upsert(Session s) async => byId[s.id] = s;

  @override
  Future<void> deleteSession(String id) async => byId.remove(id);

  @override
  Future<Session?> getSession(String id) async => byId[id];

  @override
  Future<List<Topic>> getTopics(String sessionId) async =>
      byId[sessionId]?.topics ?? const [];

  @override
  Future<Session> insertSession(Session session) async {
    byId[session.id] = session;
    return session;
  }

  @override
  Future<void> replaceTopics(String sessionId, List<Topic> topics) async {
    final s = byId[sessionId];
    if (s != null) byId[sessionId] = s.copyWith(topics: topics);
  }

  @override
  Future<void> updateSession(Session session, {bool emitDiff = false}) async =>
      byId[session.id] = session;

  @override
  Stream<List<Session>> watchSessions({bool includeDeleted = false}) =>
      Stream.value(byId.values.toList());
}

class _MemoryLogRepo implements EditLogRepository {
  final Map<String, OperationLog> byId = {};
  final Map<String, Session> diffBases = {};

  @override
  Future<OperationLog?> getLog(String sessionId) async => byId[sessionId];

  @override
  Future<void> saveLog(
    String sessionId,
    OperationLog log, {
    Session? diffBase,
  }) async {
    byId[sessionId] = log;
    if (diffBase != null) diffBases[sessionId] = diffBase;
  }

  @override
  Future<OplogDiff?> getPendingDiff(String sessionId) async {
    final log = byId[sessionId];
    final base = diffBases[sessionId];
    if (log == null || base == null) return null;
    final batches = log.unsyncedDelta();
    if (batches.isEmpty) return null;
    return OplogDiff(
      sessionId: sessionId,
      base: base,
      batches: batches,
    );
  }

  @override
  Future<void> markSynced(String sessionId, {required Session base}) async {
    final log = byId[sessionId];
    if (log == null) return;
    log.markSynced();
    byId[sessionId] = log;
    diffBases[sessionId] = base;
  }
}
