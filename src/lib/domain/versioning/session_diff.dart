import '../entities/session.dart';

/// What a diff operation changed (architecture §4.6 diff view).
enum DiffKind {
  titleChanged,
  summaryChanged,
  topicAdded,
  topicRemoved,
  topicRenamed,
  topicMoved,
  itemAdded,
  itemRemoved,
  itemMoved,
  itemEdited,
  entityAdded,
  entityRemoved,
  entityEdited,
  relationshipAdded,
  relationshipRemoved,
  relationshipEdited,
}

/// One atomic change in a [diffSessions] result.
class SessionDiffEntry {
  const SessionDiffEntry({
    required this.kind,
    this.topicId,
    this.topicTitle,
    this.itemId,
    this.detail,
    this.before,
    this.after,
  });

  final DiffKind kind;
  final String? topicId;
  final String? topicTitle;

  /// Item id for item-level entries; null for topic/session entries.
  final String? itemId;

  /// Human-readable subject, e.g. the topic or item title.
  final String? detail;

  /// Old/new values for renamed/edited entries.
  final String? before;
  final String? after;

  String get label {
    return switch (kind) {
      DiffKind.titleChanged => 'Session title',
      DiffKind.summaryChanged => 'Summary',
      DiffKind.topicAdded => 'Topic added',
      DiffKind.topicRemoved => 'Topic removed',
      DiffKind.topicRenamed => 'Topic renamed',
      DiffKind.topicMoved => 'Topic moved',
      DiffKind.itemAdded => 'Item added',
      DiffKind.itemRemoved => 'Item removed',
      DiffKind.itemMoved => 'Item moved',
      DiffKind.itemEdited => 'Item edited',
      DiffKind.entityAdded => 'Entity added',
      DiffKind.entityRemoved => 'Entity removed',
      DiffKind.entityEdited => 'Entity edited',
      DiffKind.relationshipAdded => 'Relationship added',
      DiffKind.relationshipRemoved => 'Relationship removed',
      DiffKind.relationshipEdited => 'Relationship edited',
    };
  }

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        if (topicId != null) 'topic_id': topicId,
        if (topicTitle != null) 'topic_title': topicTitle,
        if (itemId != null) 'item_id': itemId,
        if (detail != null) 'detail': detail,
        if (before != null) 'before': before,
        if (after != null) 'after': after,
      };
}

bool _itemEquals(Item a, Item b) =>
    a.title == b.title &&
    a.description == b.description &&
    a.type == b.type &&
    a.priority == b.priority &&
    a.confidence == b.confidence;

/// Deterministic diff between two session snapshots: topics/items added,
/// removed, moved, renamed/edited (architecture §4.6). Move is detected by id
/// at a different position; content edits by field comparison.
///
/// Processing order is stable (title → summary → topics in index order →
/// removed/added/moved/renamed per topic → items removed/added/moved/edited),
/// so callers can rely on the ordering for rendering and change-reason
/// summaries.
List<SessionDiffEntry> diffSessions(Session before, Session after) {
  final diff = <SessionDiffEntry>[];

  if (before.title != after.title) {
    diff.add(SessionDiffEntry(
      kind: DiffKind.titleChanged,
      detail: 'Session title',
      before: before.title,
      after: after.title,
    ));
  }
  if (before.summary != after.summary) {
    diff.add(SessionDiffEntry(
      kind: DiffKind.summaryChanged,
      detail: 'Summary',
      before: before.summary,
      after: after.summary,
    ));
  }

  final beforeTopics = {for (final t in before.topics) t.id: t};
  final afterTopics = {for (final t in after.topics) t.id: t};

  for (final t in after.topics) {
    if (!beforeTopics.containsKey(t.id)) {
      diff.add(SessionDiffEntry(
        kind: DiffKind.topicAdded,
        topicId: t.id,
        topicTitle: t.title,
        detail: t.title,
      ));
    }
  }
  for (final t in before.topics) {
    if (!afterTopics.containsKey(t.id)) {
      diff.add(SessionDiffEntry(
        kind: DiffKind.topicRemoved,
        topicId: t.id,
        topicTitle: t.title,
        detail: t.title,
      ));
    }
  }

  for (final t in after.topics) {
    final prev = beforeTopics[t.id];
    if (prev == null) continue;
    if (prev.title != t.title) {
      diff.add(SessionDiffEntry(
        kind: DiffKind.topicRenamed,
        topicId: t.id,
        topicTitle: t.title,
        detail: t.title,
        before: prev.title,
        after: t.title,
      ));
    }
    if (prev.position != t.position) {
      diff.add(SessionDiffEntry(
        kind: DiffKind.topicMoved,
        topicId: t.id,
        topicTitle: t.title,
        detail: t.title,
        before: '${prev.position}',
        after: '${t.position}',
      ));
    }

    final beforeItems = {for (final i in prev.items) i.id: i};
    final afterItems = {for (final i in t.items) i.id: i};

    for (final i in t.items) {
      if (!beforeItems.containsKey(i.id)) {
        diff.add(SessionDiffEntry(
          kind: DiffKind.itemAdded,
          topicId: t.id,
          topicTitle: t.title,
          itemId: i.id,
          detail: i.title,
        ));
      }
    }
    for (final i in prev.items) {
      if (!afterItems.containsKey(i.id)) {
        diff.add(SessionDiffEntry(
          kind: DiffKind.itemRemoved,
          topicId: t.id,
          topicTitle: t.title,
          itemId: i.id,
          detail: i.title,
        ));
      }
    }
    for (final i in t.items) {
      final prevItem = beforeItems[i.id];
      if (prevItem == null) continue;
      if (prevItem.position != i.position) {
        diff.add(SessionDiffEntry(
          kind: DiffKind.itemMoved,
          topicId: t.id,
          topicTitle: t.title,
          itemId: i.id,
          detail: i.title,
        ));
      }
      if (!_itemEquals(prevItem, i)) {
        diff.add(SessionDiffEntry(
          kind: DiffKind.itemEdited,
          topicId: t.id,
          topicTitle: t.title,
          itemId: i.id,
          detail: i.title,
          before: prevItem.title,
          after: i.title,
        ));
      }
    }
  }

  final beforeEntities = {for (final e in before.entities) e.id: e};
  final afterEntities = {for (final e in after.entities) e.id: e};
  String entityName(String id) =>
      afterEntities[id]?.name ?? beforeEntities[id]?.name ?? id;

  for (final e in after.entities) {
    if (!beforeEntities.containsKey(e.id)) {
      diff.add(SessionDiffEntry(
        kind: DiffKind.entityAdded,
        detail: e.name,
      ));
    }
  }
  for (final e in before.entities) {
    final current = afterEntities[e.id];
    if (current == null) {
      diff.add(SessionDiffEntry(
        kind: DiffKind.entityRemoved,
        detail: e.name,
      ));
      continue;
    }
    if (!e.contentEquals(current)) {
      diff.add(SessionDiffEntry(
        kind: DiffKind.entityEdited,
        detail: e.name,
        before: e.name,
        after: current.name,
      ));
    }
  }

  final beforeRelations = {for (final r in before.relationships) r.id: r};
  final afterRelations = {for (final r in after.relationships) r.id: r};
  for (final r in after.relationships) {
    if (!beforeRelations.containsKey(r.id)) {
      diff.add(SessionDiffEntry(
        kind: DiffKind.relationshipAdded,
        detail:
            '${entityName(r.sourceId)} —${r.type.name}— ${entityName(r.targetId)}',
        before: entityName(r.sourceId),
        after: entityName(r.targetId),
      ));
    }
  }
  for (final r in before.relationships) {
    final current = afterRelations[r.id];
    if (current == null) {
      diff.add(SessionDiffEntry(
        kind: DiffKind.relationshipRemoved,
        detail:
            '${entityName(r.sourceId)} —${r.type.name}— ${entityName(r.targetId)}',
      ));
      continue;
    }
    if (!r.contentEquals(current)) {
      diff.add(SessionDiffEntry(
        kind: DiffKind.relationshipEdited,
        detail:
            '${entityName(r.sourceId)} —${current.type.name}— ${entityName(r.targetId)}',
        before: r.type.name,
        after: current.type.name,
      ));
    }
  }

  return diff;
}

/// Compresses a diff into a short, human-readable change-reason (e.g. stored
/// as `change_reason` on a version). Returns `null` for an empty diff.
String? summarizeDiff(List<SessionDiffEntry> diff) {
  if (diff.isEmpty) return null;
  final counts = <DiffKind, int>{};
  for (final e in diff) {
    counts[e.kind] = (counts[e.kind] ?? 0) + 1;
  }

  final verb = <DiffKind, String>{
    DiffKind.topicAdded: 'added',
    DiffKind.topicRemoved: 'removed',
    DiffKind.topicRenamed: 'renamed',
    DiffKind.topicMoved: 'moved',
    DiffKind.itemAdded: 'added',
    DiffKind.itemRemoved: 'removed',
    DiffKind.itemMoved: 'moved',
    DiffKind.itemEdited: 'edited',
    DiffKind.titleChanged: 'changed',
    DiffKind.summaryChanged: 'changed',
    DiffKind.entityAdded: 'added',
    DiffKind.entityRemoved: 'removed',
    DiffKind.entityEdited: 'edited',
    DiffKind.relationshipAdded: 'added',
    DiffKind.relationshipRemoved: 'removed',
    DiffKind.relationshipEdited: 'relabelled',
  };
  final noun = <DiffKind, String>{
    DiffKind.topicAdded: 'topic',
    DiffKind.topicRemoved: 'topic',
    DiffKind.topicRenamed: 'topic',
    DiffKind.topicMoved: 'topic',
    DiffKind.itemAdded: 'item',
    DiffKind.itemRemoved: 'item',
    DiffKind.itemMoved: 'item',
    DiffKind.itemEdited: 'item',
    DiffKind.titleChanged: 'title',
    DiffKind.summaryChanged: 'summary',
    DiffKind.entityAdded: 'entity',
    DiffKind.entityRemoved: 'entity',
    DiffKind.entityEdited: 'entity',
    DiffKind.relationshipAdded: 'relationship',
    DiffKind.relationshipRemoved: 'relationship',
    DiffKind.relationshipEdited: 'relationship',
  };

  const order = [
    DiffKind.titleChanged,
    DiffKind.summaryChanged,
    DiffKind.topicAdded,
    DiffKind.topicRemoved,
    DiffKind.topicRenamed,
    DiffKind.topicMoved,
    DiffKind.itemAdded,
    DiffKind.itemRemoved,
    DiffKind.itemMoved,
    DiffKind.itemEdited,
    DiffKind.entityAdded,
    DiffKind.entityRemoved,
    DiffKind.entityEdited,
    DiffKind.relationshipAdded,
    DiffKind.relationshipRemoved,
    DiffKind.relationshipEdited,
  ];

  String plural(String word, int n) => n == 1 ? word : '${word}s';

  final parts = <String>[];
  for (final kind in order) {
    final n = counts[kind];
    if (n == null) continue;
    parts.add('${verb[kind]} $n ${plural(noun[kind]!, n)}');
  }
  return parts.join(', ');
}
