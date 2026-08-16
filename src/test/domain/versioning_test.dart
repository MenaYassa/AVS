import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:ai_knowledge_companion/domain/versioning/session_diff.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Topic topic(String id, int position, {String title = 'T', List<Item> items = const []}) =>
      Topic(id: id, position: position, title: title, items: items);

  Session session({List<Topic> topics = const [], String? title, String? summary}) =>
      Session(
        id: 's1',
        userId: 'u1',
        title: title ?? 'Budget',
        summary: summary ?? 'We reviewed the numbers.',
        topics: topics,
      );

  group('diffSessions', () {
    test('empty when the sessions are equal', () {
      final a = session(topics: [topic('t1', 0, title: 'Costs')]);
      final b = session(topics: [topic('t1', 0, title: 'Costs')]);
      expect(diffSessions(a, b), isEmpty);
    });

    test('title and summary changes come first', () {
      final before = session();
      final after = session(title: 'Annual budget', summary: 'Reviewed Q3.');
      final diff = diffSessions(before, after);
      expect(diff.map((e) => e.kind).toList(), [
        DiffKind.titleChanged,
        DiffKind.summaryChanged,
      ]);
    });

    test('topic added/removed detected by id', () {
      final before = session(topics: [topic('t1', 0, title: 'Costs')]);
      final after = session(topics: [
        topic('t1', 0, title: 'Costs'),
        topic('t2', 1, title: 'Ideas'),
      ]);
      final diff = diffSessions(before, after);
      expect(diff.single.kind, DiffKind.topicAdded);
      expect(diff.single.detail, 'Ideas');
    });

    test('topic removed detected', () {
      final before = session(topics: [
        topic('t1', 0, title: 'Costs'),
        topic('t2', 1, title: 'Ideas'),
      ]);
      final after = session(topics: [topic('t1', 0, title: 'Costs')]);
      final diff = diffSessions(before, after);
      expect(diff.single.kind, DiffKind.topicRemoved);
      expect(diff.single.detail, 'Ideas');
    });

    test('rename is not confused with a move', () {
      final before = session(topics: [topic('t1', 0, title: 'Costs')]);
      final after = session(topics: [topic('t1', 0, title: 'Expenses')]);
      final diff = diffSessions(before, after);
      expect(diff.map((e) => e.kind).toList(), [DiffKind.topicRenamed]);
      expect(diff.single.before, 'Costs');
      expect(diff.single.after, 'Expenses');
    });

    test('pure reorder produces moves, never renames', () {
      final before = session(topics: [
        topic('t1', 0, title: 'Costs'),
        topic('t2', 1, title: 'Ideas'),
      ]);
      final after = session(topics: [
        topic('t2', 0, title: 'Ideas'),
        topic('t1', 1, title: 'Costs'),
      ]);
      final diff = diffSessions(before, after);
      expect(diff.map((e) => e.kind).toList(), [
        DiffKind.topicMoved,
        DiffKind.topicMoved,
      ]);
    });

    test('item add/remove/move/edit within a topic', () {
      final before = session(topics: [
        topic('t1', 0, title: 'Costs', items: [
          Item(id: 'i1', type: ItemType.task, position: 0, title: 'A'),
          Item(id: 'i2', type: ItemType.task, position: 1, title: 'B'),
          Item(id: 'i3', type: ItemType.task, position: 2, title: 'C'),
        ]),
      ]);
      final after = session(topics: [
        topic('t1', 0, title: 'Costs', items: [
          Item(id: 'i3', type: ItemType.task, position: 0, title: 'C'),
          Item(id: 'i1', type: ItemType.task, position: 1, title: 'A'),
          Item(id: 'i4', type: ItemType.task, position: 2, title: 'D'),
        ]),
      ]);
      final diff = diffSessions(before, after);
      // Stable order: added, removed, then per-item moves/edits. Moving i3 to
      // the front shifts i1 down, so both report as moved (positional diff).
      expect(diff.map((e) => e.kind).toList(), [
        DiffKind.itemAdded, // i4
        DiffKind.itemRemoved, // i2
        DiffKind.itemMoved, // i3 2 -> 0
        DiffKind.itemMoved, // i1 0 -> 1
      ]);
    });

    test('item content edit detected with before/after', () {
      final before = session(topics: [
        topic('t1', 0, title: 'Costs', items: [
          Item(
              id: 'i1',
              type: ItemType.task,
              position: 0,
              title: 'A',
              confidence: 0.9),
        ]),
      ]);
      final after = session(topics: [
        topic('t1', 0, title: 'Costs', items: [
          Item(id: 'i1', type: ItemType.task, position: 0, title: 'A (2)'),
        ]),
      ]);
      final diff = diffSessions(before, after);
      expect(diff.single.kind, DiffKind.itemEdited);
      expect(diff.single.before, 'A');
      expect(diff.single.after, 'A (2)');
    });

    test('deterministic ordering for identical changes', () {
      Session build(String title) => session(title: title, topics: [
            topic('t1', 0, title: 'Costs', items: [
              Item(id: 'i1', type: ItemType.task, position: 0, title: 'A'),
            ]),
            topic('t2', 1, title: 'Ideas'),
          ]);
      final a = diffSessions(build('one'), build('two'));
      final b = diffSessions(build('one'), build('two'));
      expect(a.map((e) => e.toJson()).toList(),
          b.map((e) => e.toJson()).toList());
    });
  });

  group('summarizeDiff', () {
    test('null for an empty diff', () {
      expect(summarizeDiff(const []), isNull);
    });

    test('pluralizes and orders kinds deterministically', () {
      final diff = [
        SessionDiffEntry(kind: DiffKind.itemAdded, detail: 'D'),
        SessionDiffEntry(kind: DiffKind.topicAdded, detail: 'Ideas'),
        SessionDiffEntry(kind: DiffKind.itemEdited, detail: 'A'),
        SessionDiffEntry(kind: DiffKind.topicAdded, detail: 'Risks'),
      ];
      expect(summarizeDiff(diff), 'added 2 topics, added 1 item, edited 1 item');
    });

    test('singular forms', () {
      final diff = [SessionDiffEntry(kind: DiffKind.itemEdited, detail: 'A')];
      expect(summarizeDiff(diff), 'edited 1 item');
    });
  });
}
