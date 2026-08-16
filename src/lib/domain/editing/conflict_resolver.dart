import '../entities/graph.dart';
import '../entities/session.dart';
import 'edit_operations.dart';
import 'oplog_diff.dart';

/// A divergent change the resolver could not merge silently (architecture
/// §4.13: "true conflicts flagged for review"). Flagged, never auto-applied
/// past the resolver's deterministic default.
sealed class SessionConflict {
  const SessionConflict({
    required this.sessionId,
    required this.kind,
    required this.description,
  });

  final String sessionId;

  /// `field` (last-write-wins applied, both values recorded) or `structural`
  /// (the op could not be applied against the remote state).
  final String kind;
  final String description;
}

/// Both devices changed the same field since the common base; the local edit
/// won (LWW) but the overwritten remote value is preserved for review.
class FieldConflict extends SessionConflict {
  const FieldConflict({
    required super.sessionId,
    required this.fieldPath,
    required this.localValue,
    required this.remoteValue,
  }) : super(
          kind: 'field',
          description:
              'Changed on another device to "$remoteValue" — local value "$localValue" was kept.',
        );

  final String fieldPath;
  final dynamic localValue;
  final dynamic remoteValue;
}

/// The op's target was deleted or structurally invalidated on the remote, so
/// the local edit was skipped (remote state wins).
class StructuralConflict extends SessionConflict {
  const StructuralConflict({
    required super.sessionId,
    required this.opType,
    required this.target,
  }) : super(
          kind: 'structural',
          description: '$opType skipped: $target no longer exists on another device.',
        );

  final String opType;
  final String target;
}

/// Outcome of one resolution pass: the [merged] state to push plus any flagged
/// [conflicts] (in deterministic, op-application order).
class ResolutionResult {
  const ResolutionResult({required this.merged, required this.conflicts});

  final Session merged;
  final List<SessionConflict> conflicts;
}

/// Field-level last-write-wins with flagged true conflicts (architecture
/// §4.13). Pure and deterministic, so two devices resolving the same
/// (remote, diff) pair always converge to the same [ResolutionResult].
///
/// Rules, in application order over the diff's batches:
/// - Content ops compare their recorded pre-state against the current merged
///   value. A mismatch that the local op would overwrite differently is a
///   [FieldConflict] — the local value is kept (LWW). When both sides arrived
///   at the same value, nothing is flagged.
/// - Structural ops locate their targets by id. A missing target is a
///   [StructuralConflict] and the op is skipped. Base-relative positions are
///   translated onto the merged state via id anchors, so reorder/merge/split
///   made offline replay correctly when the other device also changed order.
class ConflictResolver {
  const ConflictResolver();

  ResolutionResult resolve({
    required Session remote,
    required OplogDiff diff,
  }) {
    var merged = remote;
    final conflicts = <SessionConflict>[];
    for (final batch in diff.batches) {
      for (final op in batch) {
        final outcome = _applyOne(op, merged, diff.base, diff.sessionId);
        merged = outcome.session;
        conflicts.addAll(outcome.conflicts);
      }
    }
    return ResolutionResult(merged: merged, conflicts: conflicts);
  }

  ({Session session, List<SessionConflict> conflicts}) _applyOne(
    EditOperation op,
    Session merged,
    Session base,
    String sessionId,
  ) {
    final conflicts = <SessionConflict>[];

    void fieldConflict(String path, dynamic localValue, dynamic remoteValue) {
      if (remoteValue != localValue) {
        conflicts.add(FieldConflict(
          sessionId: sessionId,
          fieldPath: path,
          localValue: localValue,
          remoteValue: remoteValue,
        ));
      }
    }

    void structuralConflict(String target) {
      conflicts.add(StructuralConflict(
        sessionId: sessionId,
        opType: op.type,
        target: target,
      ));
    }

    switch (op) {
      case UpdateSessionTitle(:final oldTitle, :final newTitle):
        if (merged.title != oldTitle && merged.title != newTitle) {
          fieldConflict('session.title', newTitle, merged.title);
        }
        return (session: op.apply(merged), conflicts: conflicts);

      case UpdateSessionSummary(:final oldSummary, :final newSummary):
        if (merged.summary != oldSummary && merged.summary != newSummary) {
          fieldConflict('session.summary', newSummary, merged.summary);
        }
        return (session: op.apply(merged), conflicts: conflicts);

      case UpdateSessionTranscript(
          :final oldTranscript,
          :final newTranscript,
        ):
        if (merged.cleanedTranscript != oldTranscript &&
            merged.cleanedTranscript != newTranscript) {
          fieldConflict('session.cleaned_transcript', newTranscript, merged.cleanedTranscript);
        }
        return (session: op.apply(merged), conflicts: conflicts);

      case RenameTopic(:final topicId, :final oldTitle, :final newTitle):
        final topic = _topicById(merged, topicId);
        if (topic == null) {
          structuralConflict('topic $topicId');
          return (session: merged, conflicts: conflicts);
        }
        if (topic.title != oldTitle && topic.title != newTitle) {
          fieldConflict('topic.$topicId.title', newTitle, topic.title);
        }
        return (session: op.apply(merged), conflicts: conflicts);

      case UpdateItemText(
          :final topicId,
          :final itemId,
          :final oldTitle,
          :final oldDescription,
          :final newTitle,
          :final newDescription,
        ):
        final item = _itemById(merged, topicId, itemId);
        if (item == null) {
          structuralConflict('item $itemId');
          return (session: merged, conflicts: conflicts);
        }
        final remoteTitle = item.title;
        final remoteDescription = item.description;
        if ((remoteTitle != oldTitle || remoteDescription != oldDescription) &&
            (remoteTitle != newTitle || remoteDescription != newDescription)) {
          fieldConflict(
            'item.$itemId.title/description',
            '$newTitle — $newDescription',
            '$remoteTitle — $remoteDescription',
          );
        }
        return (session: op.apply(merged), conflicts: conflicts);

      case ChangeItemType(
          :final topicId,
          :final itemId,
          :final oldType,
          :final newType,
        ):
        final item = _itemById(merged, topicId, itemId);
        if (item == null) {
          structuralConflict('item $itemId');
          return (session: merged, conflicts: conflicts);
        }
        if (item.type.name != oldType && item.type.name != newType) {
          fieldConflict('item.$itemId.type', newType, item.type.name);
        }
        return (session: op.apply(merged), conflicts: conflicts);

      case SetItemPriority(:final topicId, :final itemId, :final oldPriority, :final newPriority):
        final item = _itemById(merged, topicId, itemId);
        if (item == null) {
          structuralConflict('item $itemId');
          return (session: merged, conflicts: conflicts);
        }
        if (item.priority?.name != oldPriority && item.priority?.name != newPriority) {
          fieldConflict('item.$itemId.priority', newPriority, item.priority?.name);
        }
        return (session: op.apply(merged), conflicts: conflicts);

      case SetItemConfidence(:final topicId, :final itemId, :final oldConfidence, :final newConfidence):
        final item = _itemById(merged, topicId, itemId);
        if (item == null) {
          structuralConflict('item $itemId');
          return (session: merged, conflicts: conflicts);
        }
        if (item.confidence != oldConfidence && item.confidence != newConfidence) {
          fieldConflict('item.$itemId.confidence', newConfidence, item.confidence);
        }
        return (session: op.apply(merged), conflicts: conflicts);

      case AddTopic(:final topic, :final position):
        if (_topicById(merged, topic.id) != null) {
          return (session: merged, conflicts: conflicts); // already there
        }
        final translated = _translate(
          merged.topics,
          base.topics,
          position,
          idOf: (t) => t.id,
        );
        return (
          session: AddTopic(topic: topic, position: translated).apply(merged),
          conflicts: conflicts,
        );

      case DeleteTopic():
        if (_topicById(merged, op.topic.id) == null) {
          return (session: merged, conflicts: conflicts); // remote already deleted
        }
        return (session: op.apply(merged), conflicts: conflicts);

      case MergeTopics(:final source, :final targetId):
        if (_topicById(merged, source.id) == null ||
            _topicById(merged, targetId) == null) {
          structuralConflict('topics $source.id/$targetId');
          return (session: merged, conflicts: conflicts);
        }
        return (session: op.apply(merged), conflicts: conflicts);

      case SplitTopic(
          :final targetId,
          :final sourceId,
          :final title,
          :final description,
          :final position,
          :final movedItems,
        ):
        final target = _topicById(merged, targetId);
        if (target == null) {
          structuralConflict('topic $targetId');
          return (session: merged, conflicts: conflicts);
        }
        final present = target.items
            .where((i) => movedItems.any((m) => m.id == i.id))
            .length;
        if (present != movedItems.length) {
          structuralConflict('items ${[for (final m in movedItems) m.id].join(', ')}');
          return (session: merged, conflicts: conflicts);
        }
        final translated = _translate(
          merged.topics,
          base.topics,
          position,
          idOf: (t) => t.id,
        );
        return (
          session: SplitTopic(
            targetId: targetId,
            sourceId: sourceId,
            title: title,
            description: description,
            position: translated,
            movedItems: movedItems,
          ).apply(merged),
          conflicts: conflicts,
        );

      case ReorderTopic(:final topicId, :final to):
        final newFrom = merged.topics.indexWhere((t) => t.id == topicId);
        if (newFrom == -1) {
          structuralConflict('topic $topicId');
          return (session: merged, conflicts: conflicts);
        }
        final anchor = _translate(
          merged.topics,
          base.topics,
          to,
          idOf: (t) => t.id,
          excluding: {topicId},
        );
        var newTo = anchor;
        if (newTo > newFrom) newTo--;
        if (newTo < 0) newTo = 0;
        final cap = merged.topics.length - 1;
        if (newTo > cap) newTo = cap;
        return (
          session: ReorderTopic(topicId: topicId, from: newFrom, to: newTo)
              .apply(merged),
          conflicts: conflicts,
        );

      case InsertItem(:final topicId, :final position, :final item):
        final topic = _topicById(merged, topicId);
        if (topic == null) {
          structuralConflict('topic $topicId');
          return (session: merged, conflicts: conflicts);
        }
        if (topic.items.any((i) => i.id == item.id)) {
          return (session: merged, conflicts: conflicts); // already there
        }
        final baseTopic = _topicById(base, topicId);
        final translated = _translate(
          topic.items,
          baseTopic?.items ?? const <Item>[],
          position,
          idOf: (i) => i.id,
        );
        return (
          session: InsertItem(topicId: topicId, position: translated, item: item)
              .apply(merged),
          conflicts: conflicts,
        );

      case DeleteItem():
        final item = _itemById(merged, op.topicId, op.item.id);
        if (item == null) {
          return (session: merged, conflicts: conflicts); // remote already deleted
        }
        return (session: op.apply(merged), conflicts: conflicts);

      case MoveItem(
          :final fromTopicId,
          :final toTopicId,
          :final position,
          :final originalPosition,
          :final item,
        ):
        final source = _topicById(merged, fromTopicId);
        if (source == null || !source.items.any((i) => i.id == item.id)) {
          structuralConflict('item ${item.id}');
          return (session: merged, conflicts: conflicts);
        }
        final target = _topicById(merged, toTopicId);
        if (target == null) {
          structuralConflict('topic $toTopicId');
          return (session: merged, conflicts: conflicts);
        }
        final baseTarget = _topicById(base, toTopicId);
        final translated = _translate(
          target.items,
          baseTarget?.items ?? const <Item>[],
          position,
          idOf: (i) => i.id,
        );
        return (
          session: MoveItem(
            fromTopicId: fromTopicId,
            toTopicId: toTopicId,
            position: translated,
            originalPosition: originalPosition,
            item: item,
          ).apply(merged),
          conflicts: conflicts,
        );

      case AddEntity(:final entity):
        if (merged.entities.any((e) => e.id == entity.id)) {
          return (session: merged, conflicts: conflicts); // already there
        }
        return (session: op.apply(merged), conflicts: conflicts);

      case RenameEntity(
          :final entityId,
          :final oldEntity,
          :final newEntity,
        ):
        final entity = _entityById(merged, entityId);
        if (entity == null) {
          structuralConflict('entity $entityId');
          return (session: merged, conflicts: conflicts);
        }
        if (entity.name != oldEntity.name && entity.name != newEntity.name) {
          fieldConflict('entity.$entityId.name', newEntity.name, entity.name);
        }
        return (session: op.apply(merged), conflicts: conflicts);

      case MergeEntities(:final source, :final targetId):
        if (_entityById(merged, source.id) == null ||
            _entityById(merged, targetId) == null) {
          structuralConflict('entities ${source.id}/$targetId');
          return (session: merged, conflicts: conflicts);
        }
        return (session: op.apply(merged), conflicts: conflicts);

      case DeleteEntity():
        if (_entityById(merged, op.entity.id) == null) {
          return (session: merged, conflicts: conflicts); // remote deleted
        }
        return (session: op.apply(merged), conflicts: conflicts);

      case RestoreEntity():
        if (_entityById(merged, op.entity.id) != null) {
          return (session: merged, conflicts: conflicts); // already there
        }
        return (session: op.apply(merged), conflicts: conflicts);

      case SplitEntity():
        if (_entityById(merged, op.entity.id) != null ||
            _entityById(merged, op.targetId) == null) {
          return (session: merged, conflicts: conflicts); // no-op or undone
        }
        return (session: op.apply(merged), conflicts: conflicts);

      case AddRelationship(:final relationship):
        if (_entityById(merged, relationship.sourceId) == null ||
            _entityById(merged, relationship.targetId) == null) {
          structuralConflict(
              'entities ${relationship.sourceId}/${relationship.targetId}');
          return (session: merged, conflicts: conflicts);
        }
        if (merged.relationships.any((r) => r.id == relationship.id)) {
          return (session: merged, conflicts: conflicts); // already there
        }
        return (session: op.apply(merged), conflicts: conflicts);

      case DeleteRelationship():
        if (!merged.relationships.any((r) => r.id == op.relationship.id)) {
          return (session: merged, conflicts: conflicts); // remote deleted
        }
        return (session: op.apply(merged), conflicts: conflicts);

      case RelabelRelationship(
          :final relationshipId,
          :final oldRelationship,
          :final newRelationship,
        ):
        final relationship = _relationshipById(merged, relationshipId);
        if (relationship == null) {
          structuralConflict('relationship $relationshipId');
          return (session: merged, conflicts: conflicts);
        }
        if (relationship.type != oldRelationship.type &&
            relationship.type != newRelationship.type) {
          fieldConflict(
            'relationship.$relationshipId.type',
            newRelationship.type.name,
            relationship.type.name,
          );
        }
        return (session: op.apply(merged), conflicts: conflicts);
    }
  }

  GraphEntity? _entityById(Session session, String id) =>
      session.entities.where((e) => e.id == id).firstOrNull;

  GraphRelation? _relationshipById(Session session, String id) =>
      session.relationships.where((r) => r.id == id).firstOrNull;

  Topic? _topicById(Session session, String id) =>
      session.topics.where((t) => t.id == id).firstOrNull;

  Item? _itemById(Session session, String topicId, String itemId) {
    final topic = _topicById(session, topicId);
    if (topic == null) return null;
    return topic.items.where((i) => i.id == itemId).firstOrNull;
  }

  /// Translates a base-relative [baseIndex] onto [current] by anchoring on the
  /// node that occupied that index in [base]. When the anchor is gone (the
  /// remote removed/reordered it) the index clamps deterministically.
  int _translate<T>(
    List<T> current,
    List<T> base,
    int baseIndex, {
    required String Function(T) idOf,
    Set<String>? excluding,
  }) {
    if (base.isEmpty) return 0;
    var idx = baseIndex < 0 ? 0 : baseIndex;
    if (idx >= base.length) return current.length;
    var anchorId = idOf(base[idx]);
    while (excluding != null && excluding.contains(anchorId) && idx > 0) {
      idx--;
      anchorId = idOf(base[idx]);
    }
    final anchor = current.indexWhere((e) => idOf(e) == anchorId);
    if (anchor == -1) return baseIndex.clamp(0, current.length);
    return anchor;
  }
}
