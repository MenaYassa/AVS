import '../entities/enums.dart';
import '../entities/graph.dart';
import '../entities/session.dart';

/// The single mutation path for session content (architecture §3.4).
///
/// Every user edit is an [EditOperation]: a pure `apply(Session) -> Session`
/// plus an exact `inverse()` for undo/redo. Operations carry the pre-state
/// snapshots they need, so undo of a delete/merge/split restores bit-for-bit.
///
/// Invariants preserved by every apply:
/// - topics sorted by `position`, items sorted by `position` within a topic;
/// - positions renumbered as list indexes after every mutation;
/// - content edits clear the affected item's AI `confidence` (architecture
///   §4.7 — confidence is never authoritative once a human touches content).
sealed class EditOperation {
  const EditOperation();

  String get type;

  Session apply(Session session);

  EditOperation inverse();

  Map<String, dynamic> toJson();

  static EditOperation fromJson(Map<String, dynamic> json) {
    switch (json['type']) {
      case 'RenameTopic':
        return RenameTopic(
          topicId: json['topic_id'] as String,
          oldTitle: json['old_title'] as String,
          newTitle: json['new_title'] as String,
        );
      case 'AddTopic':
        return AddTopic(
          topic: Topic.fromJson(json['topic'] as Map<String, dynamic>),
          position: (json['position'] as num).toInt(),
        );
      case 'DeleteTopic':
        return DeleteTopic(
          topic: Topic.fromJson(json['topic'] as Map<String, dynamic>),
        );
      case 'MergeTopics':
        return MergeTopics(
          source: Topic.fromJson(json['source'] as Map<String, dynamic>),
          targetId: json['target_id'] as String,
        );
      case 'SplitTopic':
        return SplitTopic(
          targetId: json['target_id'] as String,
          sourceId: json['source_id'] as String,
          title: json['title'] as String,
          description: json['description'] as String? ?? '',
          position: (json['position'] as num).toInt(),
          movedItems: [
            for (final item in (json['moved_items'] as List<dynamic>? ?? const []))
              Item.fromJson(item as Map<String, dynamic>),
          ],
        );
      case 'ReorderTopic':
        return ReorderTopic(
          topicId: json['topic_id'] as String,
          from: (json['from'] as num).toInt(),
          to: (json['to'] as num).toInt(),
        );
      case 'InsertItem':
        return InsertItem(
          topicId: json['topic_id'] as String,
          position: (json['position'] as num).toInt(),
          item: Item.fromJson(json['item'] as Map<String, dynamic>),
        );
      case 'DeleteItem':
        return DeleteItem(
          topicId: json['topic_id'] as String,
          item: Item.fromJson(json['item'] as Map<String, dynamic>),
        );
      case 'MoveItem':
        return MoveItem(
          fromTopicId: json['from_topic_id'] as String,
          toTopicId: json['to_topic_id'] as String,
          position: (json['position'] as num).toInt(),
          originalPosition: (json['original_position'] as num?)?.toInt() ?? 0,
          item: Item.fromJson(json['item'] as Map<String, dynamic>),
        );
      case 'UpdateItemText':
        return UpdateItemText(
          topicId: json['topic_id'] as String,
          itemId: json['item_id'] as String,
          oldTitle: json['old_title'] as String,
          oldDescription: json['old_description'] as String? ?? '',
          newTitle: json['new_title'] as String,
          newDescription: json['new_description'] as String? ?? '',
          oldConfidence: (json['old_confidence'] as num?)?.toDouble(),
        );
      case 'ChangeItemType':
        return ChangeItemType(
          topicId: json['topic_id'] as String,
          itemId: json['item_id'] as String,
          oldType: json['old_type'] as String,
          newType: json['new_type'] as String,
          oldConfidence: (json['old_confidence'] as num?)?.toDouble(),
        );
      case 'SetItemPriority':
        return SetItemPriority(
          topicId: json['topic_id'] as String,
          itemId: json['item_id'] as String,
          oldPriority: json['old_priority'] as String?,
          newPriority: json['new_priority'] as String?,
        );
      case 'SetItemConfidence':
        return SetItemConfidence(
          topicId: json['topic_id'] as String,
          itemId: json['item_id'] as String,
          oldConfidence: (json['old_confidence'] as num?)?.toDouble(),
          newConfidence: (json['new_confidence'] as num?)?.toDouble(),
        );
      case 'UpdateSessionTitle':
        return UpdateSessionTitle(
          oldTitle: json['old_title'] as String?,
          newTitle: json['new_title'] as String?,
        );
      case 'UpdateSessionSummary':
        return UpdateSessionSummary(
          oldSummary: json['old_summary'] as String?,
          newSummary: json['new_summary'] as String?,
        );
      case 'UpdateSessionTranscript':
        return UpdateSessionTranscript(
          oldTranscript: json['old_transcript'] as String?,
          newTranscript: json['new_transcript'] as String?,
        );
      case 'AddEntity':
        return AddEntity(
          entity: GraphEntity.fromJson(json['entity'] as Map<String, dynamic>),
        );
      case 'RenameEntity':
        return RenameEntity(
          entityId: json['entity_id'] as String,
          oldEntity:
              GraphEntity.fromJson(json['old_entity'] as Map<String, dynamic>),
          newEntity:
              GraphEntity.fromJson(json['new_entity'] as Map<String, dynamic>),
        );
      case 'MergeEntities':
        return MergeEntities(
          source:
              GraphEntity.fromJson(json['source'] as Map<String, dynamic>),
          targetId: json['target_id'] as String,
          mergedEdges: [
            for (final e in (json['merged_edges'] as List<dynamic>? ?? const []))
              GraphRelation.fromJson(e as Map<String, dynamic>),
          ],
        );
      case 'DeleteEntity':
        return DeleteEntity(
          entity:
              GraphEntity.fromJson(json['entity'] as Map<String, dynamic>),
          incidentEdges: [
            for (final e in (json['incident_edges'] as List<dynamic>? ?? const []))
              GraphRelation.fromJson(e as Map<String, dynamic>),
          ],
        );
      case 'AddRelationship':
        return AddRelationship(
          relationship:
              GraphRelation.fromJson(json['relationship'] as Map<String, dynamic>),
        );
      case 'DeleteRelationship':
        return DeleteRelationship(
          relationship:
              GraphRelation.fromJson(json['relationship'] as Map<String, dynamic>),
        );
      case 'RelabelRelationship':
        return RelabelRelationship(
          relationshipId: json['relationship_id'] as String,
          oldRelationship: GraphRelation.fromJson(
              json['old_relationship'] as Map<String, dynamic>),
          newRelationship: GraphRelation.fromJson(
              json['new_relationship'] as Map<String, dynamic>),
        );
      default:
        throw ArgumentError('Unknown edit operation: ${json['type']}');
    }
  }
}

/// Re-numbers topic/item positions as list indexes (invariant keeper).
Session _renumber(Session session) {
  return session.copyWith(
    topics: [
      for (var t = 0; t < session.topics.length; t++)
        session.topics[t].copyWith(
          position: t,
          items: [
            for (var i = 0; i < session.topics[t].items.length; i++)
              session.topics[t].items[i].copyWith(position: i),
          ],
        ),
    ],
  );
}

/// Inserts [item] into the topic at [position]. Structural placement — the
/// item's confidence is preserved (only content edits invalidate AI output).
Topic _insertItem(Topic topic, Item item, int position) {
  final items = [...topic.items];
  final p = position.clamp(0, items.length);
  items.insert(p, item.copyWith(position: p));
  return topic.copyWith(items: _renumberItems(items));
}

List<Item> _renumberItems(List<Item> items) => [
      for (var i = 0; i < items.length; i++) items[i].copyWith(position: i),
    ];

/// Rename a topic's title.
class RenameTopic extends EditOperation {
  const RenameTopic({
    required this.topicId,
    required this.oldTitle,
    required this.newTitle,
  });

  final String topicId;
  final String oldTitle;
  final String newTitle;

  @override
  String get type => 'RenameTopic';

  @override
  Session apply(Session session) => session.copyWith(
        topics: [
          for (final t in session.topics)
            if (t.id == topicId)
              t.copyWith(title: newTitle)
            else
              t,
        ],
      );

  @override
  EditOperation inverse() =>
      RenameTopic(topicId: topicId, oldTitle: newTitle, newTitle: oldTitle);

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'topic_id': topicId,
        'old_title': oldTitle,
        'new_title': newTitle,
      };
}

/// Insert a brand-new topic (with items) at [position].
class AddTopic extends EditOperation {
  const AddTopic({required this.topic, required this.position});

  final Topic topic;
  final int position;

  @override
  String get type => 'AddTopic';

  @override
  Session apply(Session session) {
    final topics = [...session.topics];
    final p = position.clamp(0, topics.length);
    topics.insert(
      p,
      topic.copyWith(position: p, items: _renumberItems(topic.items)),
    );
    return _renumber(session.copyWith(topics: topics));
  }

  @override
  EditOperation inverse() => DeleteTopic(topic: topic);

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'position': position,
        'topic': topic.toJson(),
      };
}

/// Delete a topic (snapshot carries the full topic for exact undo).
class DeleteTopic extends EditOperation {
  const DeleteTopic({required this.topic});

  final Topic topic;

  @override
  String get type => 'DeleteTopic';

  @override
  Session apply(Session session) => _renumber(
        session.copyWith(
          topics: session.topics.where((t) => t.id != topic.id).toList(),
        ),
      );

  @override
  EditOperation inverse() => AddTopic(topic: topic, position: topic.position);

  @override
  Map<String, dynamic> toJson() => {'type': type, 'topic': topic.toJson()};
}

/// Merge [source] into [targetId]: the source's items are placed into the
/// target at their snapshot positions (clamped), source is removed. For a
/// plain append-merge the caller numbers the snapshot items from the target's
/// current length onward. [source] is a full snapshot for exact undo.
class MergeTopics extends EditOperation {
  const MergeTopics({required this.source, required this.targetId});

  final Topic source;
  final String targetId;

  @override
  String get type => 'MergeTopics';

  @override
  Session apply(Session session) {
    if (!session.topics.any((t) => t.id == source.id) ||
        !session.topics.any((t) => t.id == targetId)) {
      return session;
    }
    final topics = [
      for (final t in session.topics)
        if (t.id == targetId)
          t.copyWith(items: _renumberItems(_placeItems(t.items, source.items)))
        else if (t.id != source.id)
          t,
    ];
    return _renumber(session.copyWith(topics: topics));
  }

  @override
  EditOperation inverse() => SplitTopic(
        targetId: targetId,
        sourceId: source.id,
        title: source.title,
        description: source.description,
        position: source.position,
        movedItems: source.items,
      );

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'source': source.toJson(),
        'target_id': targetId,
      };
}

/// Inserts [incoming] items into [targetItems], each at its snapshot position
/// clamped to the running length. This is order-exact for inverse splits and
/// appends when incoming positions start at (or beyond) the target's length.
List<Item> _placeItems(List<Item> targetItems, List<Item> incoming) {
  final out = [...targetItems];
  for (final item in incoming) {
    out.insert(item.position.clamp(0, out.length), item);
  }
  return out;
}

/// Split [movedItems] out of [targetId] into a new topic [sourceId] at
/// [position]. The moved items are carried as full snapshots (with their
/// pre-split positions) so undo restores the target bit-for-bit.
class SplitTopic extends EditOperation {
  const SplitTopic({
    required this.targetId,
    required this.sourceId,
    required this.title,
    required this.description,
    required this.position,
    required this.movedItems,
  });

  final String targetId;
  final String sourceId;
  final String title;
  final String description;
  final int position;
  final List<Item> movedItems;

  List<String> get movedItemIds => [for (final i in movedItems) i.id];

  @override
  String get type => 'SplitTopic';

  @override
  Session apply(Session session) {
    final target = session.topics.where((t) => t.id == targetId).firstOrNull;
    if (target == null) return session;
    final ids = movedItemIds.toSet();
    final moved = target.items.where((i) => ids.contains(i.id)).toList();
    if (moved.length != ids.length) return session;
    final kept = target.items.where((i) => !ids.contains(i.id)).toList();
    final newTopic = Topic(
      id: sourceId,
      title: title,
      description: description,
      position: position.clamp(0, session.topics.length),
      items: _renumberItems(moved),
    );
    final topics = [
      for (final t in session.topics)
        if (t.id == targetId)
          t.copyWith(items: _renumberItems(kept))
        else
          t,
    ];
    topics.insert(
      newTopic.position.clamp(0, topics.length),
      newTopic,
    );
    return _renumber(session.copyWith(topics: topics));
  }

  @override
  EditOperation inverse() => MergeTopics(
        source: Topic(
          id: sourceId,
          title: title,
          description: description,
          position: position,
          items: movedItems,
        ),
        targetId: targetId,
      );

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'target_id': targetId,
        'source_id': sourceId,
        'title': title,
        'description': description,
        'position': position,
        'moved_items': [for (final i in movedItems) i.toJson()],
      };
}

/// Move a topic within the topic list.
class ReorderTopic extends EditOperation {
  const ReorderTopic({
    required this.topicId,
    required this.from,
    required this.to,
  });

  final String topicId;
  final int from;
  final int to;

  @override
  String get type => 'ReorderTopic';

  @override
  Session apply(Session session) {
    if (from < 0 || from >= session.topics.length) return session;
    final topics = [...session.topics];
    final topic = topics.removeAt(from);
    final dest = to.clamp(0, topics.length);
    topics.insert(dest, topic);
    return _renumber(session.copyWith(topics: topics));
  }

  @override
  EditOperation inverse() =>
      ReorderTopic(topicId: topicId, from: to, to: from);

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'topic_id': topicId,
        'from': from,
        'to': to,
      };
}

/// Insert an item into a topic at [position].
class InsertItem extends EditOperation {
  const InsertItem({
    required this.topicId,
    required this.position,
    required this.item,
  });

  final String topicId;
  final int position;
  final Item item;

  @override
  String get type => 'InsertItem';

  @override
  Session apply(Session session) => session.copyWith(
        topics: [
          for (final t in session.topics)
            if (t.id == topicId)
              _insertItem(t, item, position)
            else
              t,
        ],
      );

  @override
  EditOperation inverse() => DeleteItem(topicId: topicId, item: item);

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'topic_id': topicId,
        'position': position,
        'item': item.toJson(),
      };
}

/// Delete an item (snapshot carries it for exact undo).
class DeleteItem extends EditOperation {
  const DeleteItem({required this.topicId, required this.item});

  final String topicId;
  final Item item;

  @override
  String get type => 'DeleteItem';

  @override
  Session apply(Session session) => session.copyWith(
        topics: [
          for (final t in session.topics)
            if (t.id == topicId)
              t.copyWith(
                items: _renumberItems(
                  t.items.where((i) => i.id != item.id).toList(),
                ),
              )
            else
              t,
        ],
      );

  @override
  EditOperation inverse() =>
      InsertItem(topicId: topicId, position: item.position, item: item);

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'topic_id': topicId,
        'item': item.toJson(),
      };
}

/// Move an item across (or within) topics.
class MoveItem extends EditOperation {
  const MoveItem({
    required this.fromTopicId,
    required this.toTopicId,
    required this.position,
    required this.originalPosition,
    required this.item,
  });

  final String fromTopicId;
  final String toTopicId;
  final int position;
  final int originalPosition;
  final Item item;

  @override
  String get type => 'MoveItem';

  @override
  Session apply(Session session) {
    final source = session.topics.where((t) => t.id == fromTopicId).firstOrNull;
    if (source == null || !source.items.any((i) => i.id == item.id)) {
      return session;
    }
    return _moveItem(
      session,
      from: fromTopicId,
      to: toTopicId,
      itemId: item.id,
      position: position,
    );
  }

  @override
  EditOperation inverse() => MoveItem(
        fromTopicId: toTopicId,
        toTopicId: fromTopicId,
        position: originalPosition,
        originalPosition: position,
        item: item,
      );

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'from_topic_id': fromTopicId,
        'to_topic_id': toTopicId,
        'position': position,
        'original_position': originalPosition,
        'item': item.toJson(),
      };
}

Session _moveItem(
  Session session, {
  required String from,
  required String to,
  required String itemId,
  required int position,
}) {
  final fromTopic = session.topics.where((t) => t.id == from).firstOrNull;
  final moving = fromTopic?.items.where((i) => i.id == itemId).firstOrNull;
  if (moving == null) return session;
  final mapped = [
    for (final t in session.topics)
      if (t.id == from)
        t.copyWith(
          items: _renumberItems(
            t.items.where((i) => i.id != itemId).toList(),
          ),
        )
      else
        t,
  ];
  final target = mapped.where((t) => t.id == to).firstOrNull;
  if (target == null) return session;
  final items = [...target.items];
  final p = position.clamp(0, items.length);
  items.insert(p, moving.copyWith(position: p));
  final out = [
    for (final t in mapped)
      if (t.id == to) t.copyWith(items: _renumberItems(items)) else t,
  ];
  return _renumber(session.copyWith(topics: out));
}

/// Edit an item's title/description. Content is now human-authoritative, so
/// AI confidence is cleared; [oldConfidence] lets undo restore it exactly.
class UpdateItemText extends EditOperation {
  const UpdateItemText({
    required this.topicId,
    required this.itemId,
    required this.oldTitle,
    required this.oldDescription,
    required this.newTitle,
    required this.newDescription,
    required this.oldConfidence,
    this.newConfidence,
  });

  final String topicId;
  final String itemId;
  final String oldTitle;
  final String oldDescription;
  final String newTitle;
  final String newDescription;
  final double? oldConfidence;

  /// Confidence to set on apply; null clears it (forward edit). The inverse
  /// passes [oldConfidence] to restore. Never serialized — inverse ops are
  /// derived, not stored.
  final double? newConfidence;

  @override
  String get type => 'UpdateItemText';

  @override
  Session apply(Session session) => session.copyWith(
        topics: [
          for (final t in session.topics)
            if (t.id == topicId)
              t.copyWith(
                items: [
                  for (final i in t.items)
                    if (i.id == itemId)
                      i.copyWith(
                        title: newTitle,
                        description: newDescription,
                        confidence: newConfidence,
                        clearConfidence: newConfidence == null,
                      )
                    else
                      i,
                ],
              )
            else
              t,
        ],
      );

  @override
  EditOperation inverse() => UpdateItemText(
        topicId: topicId,
        itemId: itemId,
        oldTitle: newTitle,
        oldDescription: newDescription,
        newTitle: oldTitle,
        newDescription: oldDescription,
        oldConfidence: oldConfidence,
        newConfidence: oldConfidence,
      );

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'topic_id': topicId,
        'item_id': itemId,
        'old_title': oldTitle,
        'old_description': oldDescription,
        'new_title': newTitle,
        'new_description': newDescription,
        'old_confidence': oldConfidence,
      };
}

/// Change an item's type. Content is now human-authoritative, so AI confidence
/// is cleared; [oldConfidence] lets undo restore it exactly.
class ChangeItemType extends EditOperation {
  const ChangeItemType({
    required this.topicId,
    required this.itemId,
    required this.oldType,
    required this.newType,
    required this.oldConfidence,
    this.newConfidence,
  });

  final String topicId;
  final String itemId;
  final String oldType;
  final String newType;
  final double? oldConfidence;

  /// Confidence to set on apply; null clears it (forward edit). The inverse
  /// passes [oldConfidence] to restore. Never serialized — inverse ops are
  /// derived, not stored.
  final double? newConfidence;

  @override
  String get type => 'ChangeItemType';

  @override
  Session apply(Session session) => session.copyWith(
        topics: [
          for (final t in session.topics)
            if (t.id == topicId)
              t.copyWith(
                items: [
                  for (final i in t.items)
                    if (i.id == itemId)
                      i.copyWith(
                        type: newType,
                        confidence: newConfidence,
                        clearConfidence: newConfidence == null,
                      )
                    else
                      i,
                ],
              )
            else
              t,
        ],
      );

  @override
  EditOperation inverse() => ChangeItemType(
        topicId: topicId,
        itemId: itemId,
        oldType: newType,
        newType: oldType,
        oldConfidence: oldConfidence,
        newConfidence: oldConfidence,
      );

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'topic_id': topicId,
        'item_id': itemId,
        'old_type': oldType,
        'new_type': newType,
        'old_confidence': oldConfidence,
      };
}

/// Set (or clear) an item's priority.
class SetItemPriority extends EditOperation {
  const SetItemPriority({
    required this.topicId,
    required this.itemId,
    required this.oldPriority,
    required this.newPriority,
  });

  final String topicId;
  final String itemId;
  final String? oldPriority;
  final String? newPriority;

  @override
  String get type => 'SetItemPriority';

  @override
  Session apply(Session session) => session.copyWith(
        topics: [
          for (final t in session.topics)
            if (t.id == topicId)
              t.copyWith(
                items: [
                  for (final i in t.items)
                    if (i.id == itemId)
                      i.copyWith(
                        priority: newPriority == null
                            ? null
                            : Priority.values.firstWhere(
                                (p) => p.name == newPriority),
                        clearPriority: newPriority == null,
                      )
                    else
                      i,
                ],
              )
            else
              t,
        ],
      );

  @override
  EditOperation inverse() => SetItemPriority(
        topicId: topicId,
        itemId: itemId,
        oldPriority: newPriority,
        newPriority: oldPriority,
      );

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'topic_id': topicId,
        'item_id': itemId,
        'old_priority': oldPriority,
        'new_priority': newPriority,
      };
}

/// Set (or clear) an item's confidence — the user is authoritative (§4.7).
class SetItemConfidence extends EditOperation {
  const SetItemConfidence({
    required this.topicId,
    required this.itemId,
    required this.oldConfidence,
    required this.newConfidence,
  });

  final String topicId;
  final String itemId;
  final double? oldConfidence;
  final double? newConfidence;

  @override
  String get type => 'SetItemConfidence';

  @override
  Session apply(Session session) => session.copyWith(
        topics: [
          for (final t in session.topics)
            if (t.id == topicId)
              t.copyWith(
                items: [
                  for (final i in t.items)
                    if (i.id == itemId)
                      i.copyWith(
                        confidence: newConfidence,
                        clearConfidence: newConfidence == null,
                      )
                    else
                      i,
                ],
              )
            else
              t,
        ],
      );

  @override
  EditOperation inverse() => SetItemConfidence(
        topicId: topicId,
        itemId: itemId,
        oldConfidence: newConfidence,
        newConfidence: oldConfidence,
      );

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'topic_id': topicId,
        'item_id': itemId,
        'old_confidence': oldConfidence,
        'new_confidence': newConfidence,
      };
}

/// Set the session title.
class UpdateSessionTitle extends EditOperation {
  const UpdateSessionTitle({required this.oldTitle, required this.newTitle});

  final String? oldTitle;
  final String? newTitle;

  @override
  String get type => 'UpdateSessionTitle';

  @override
  Session apply(Session session) => session.copyWith(title: newTitle);

  @override
  EditOperation inverse() =>
      UpdateSessionTitle(oldTitle: newTitle, newTitle: oldTitle);

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'old_title': oldTitle,
        'new_title': newTitle,
      };
}

/// Set the session summary.
class UpdateSessionSummary extends EditOperation {
  const UpdateSessionSummary({
    required this.oldSummary,
    required this.newSummary,
  });

  final String? oldSummary;
  final String? newSummary;

  @override
  String get type => 'UpdateSessionSummary';

  @override
  Session apply(Session session) => session.copyWith(summary: newSummary);

  @override
  EditOperation inverse() =>
      UpdateSessionSummary(oldSummary: newSummary, newSummary: oldSummary);

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'old_summary': oldSummary,
        'new_summary': newSummary,
      };
}

/// Edit the (cleaned) transcript text. A human edit, so a later re-analysis
/// re-runs the pipeline from this corrected text (architecture §4.12). The
/// previous transcript is carried so undo restores bit-for-bit.
class UpdateSessionTranscript extends EditOperation {
  const UpdateSessionTranscript({
    required this.oldTranscript,
    required this.newTranscript,
  });

  final String? oldTranscript;
  final String? newTranscript;

  @override
  String get type => 'UpdateSessionTranscript';

  @override
  Session apply(Session session) =>
      session.copyWith(cleanedTranscript: newTranscript);

  @override
  EditOperation inverse() => UpdateSessionTranscript(
        oldTranscript: newTranscript,
        newTranscript: oldTranscript,
      );

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'old_transcript': oldTranscript,
        'new_transcript': newTranscript,
      };
}

/// Adds a knowledge-graph node (architecture §4.8). User-added nodes carry no
/// AI confidence, so nothing is cleared.
class AddEntity extends EditOperation {
  const AddEntity({required this.entity});

  final GraphEntity entity;

  @override
  String get type => 'AddEntity';

  @override
  Session apply(Session session) {
    if (session.entities.any((e) => e.id == entity.id)) return session;
    return session.copyWith(entities: [...session.entities, entity]);
  }

  @override
  EditOperation inverse() => DeleteEntity(entity: entity);

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'entity': entity.toJson(),
      };
}

/// Renames (or retypes/updates) a graph node. The id is preserved so edges
/// never dangle, and the changed node's AI confidence is cleared (§4.7).
class RenameEntity extends EditOperation {
  const RenameEntity({
    required this.entityId,
    required this.oldEntity,
    required this.newEntity,
  });

  final String entityId;
  final GraphEntity oldEntity;
  final GraphEntity newEntity;

  @override
  String get type => 'RenameEntity';

  @override
  Session apply(Session session) {
    // A human edit clears the node's AI confidence (§4.7).
    final target = oldEntity.confidence != null && newEntity.confidence != null
        ? newEntity.copyWith(clearConfidence: true)
        : newEntity;
    final entities = [
      for (final e in session.entities)
        if (e.id == entityId) target else e,
    ];
    if (identical(entities, session.entities)) return session;
    return session.copyWith(entities: entities);
  }

  @override
  EditOperation inverse() => RenameEntity(
        entityId: entityId,
        oldEntity: newEntity,
        newEntity: oldEntity,
      );

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'entity_id': entityId,
        'old_entity': oldEntity.toJson(),
        'new_entity': newEntity.toJson(),
      };
}

/// Merges [source] into the target node: the source node disappears and every
/// edge touching it is rewired to the target (no dangling edges). The pre-merge
/// edges are carried so undo restores bit-for-bit.
class MergeEntities extends EditOperation {
  const MergeEntities({
    required this.source,
    required this.targetId,
    required this.mergedEdges,
  });

  final GraphEntity source;
  final String targetId;
  final List<GraphRelation> mergedEdges;

  @override
  String get type => 'MergeEntities';

  @override
  Session apply(Session session) {
    if (source.id == targetId) return session;
    if (!session.entities.any((e) => e.id == source.id)) return session;
    if (!session.entities.any((e) => e.id == targetId)) return session;
    final entities = [
      for (final e in session.entities)
        if (e.id != source.id)
          e.copyWith(clearConfidence: e.id == targetId),
    ];
    final relationships = <GraphRelation>[];
    for (final r in session.relationships) {
      if (r.sourceId != source.id && r.targetId != source.id) {
        relationships.add(r);
        continue;
      }
      final nextSourceId = r.sourceId == source.id ? targetId : r.sourceId;
      final nextTargetId = r.targetId == source.id ? targetId : r.targetId;
      if (nextSourceId == nextTargetId) continue; // self-loop dropped
      if (relationships.any((x) =>
          x.sourceId == nextSourceId && x.targetId == nextTargetId && x.type == r.type)) {
        continue; // duplicate after rewiring dropped
      }
      relationships.add(
        r.copyWith(
          sourceId: nextSourceId,
          targetId: nextTargetId,
          confidence: null,
        ),
      );
    }
    return session.copyWith(entities: entities, relationships: relationships);
  }

  @override
  EditOperation inverse() => SplitEntity(
        entity: source,
        targetId: targetId,
        preMergeEdges: mergedEdges,
      );

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'source': source.toJson(),
        'target_id': targetId,
        'merged_edges': [for (final e in mergedEdges) e.toJson()],
      };
}

/// Removes a graph node and its incident edges (no dangling edges). The exact
/// pre-state is carried so undo restores node + edges bit-for-bit.
class DeleteEntity extends EditOperation {
  const DeleteEntity({
    required this.entity,
    this.incidentEdges = const [],
  });

  final GraphEntity entity;
  final List<GraphRelation> incidentEdges;

  @override
  String get type => 'DeleteEntity';

  @override
  Session apply(Session session) {
    if (!session.entities.any((e) => e.id == entity.id)) return session;
    final removed = {entity.id};
    return session.copyWith(
      entities: [
        for (final e in session.entities)
          if (e.id != entity.id) e,
      ],
      relationships: [
        for (final r in session.relationships)
          if (!removed.contains(r.sourceId) && !removed.contains(r.targetId)) r,
      ],
    );
  }

  @override
  EditOperation inverse() => RestoreEntity(
        entity: entity,
        incidentEdges: incidentEdges,
      );

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'entity': entity.toJson(),
        'incident_edges': [for (final e in incidentEdges) e.toJson()],
      };
}

/// Adds a knowledge-graph edge. Skipped when an endpoint is missing (invariant:
/// edges never dangle) or when the exact edge already exists.
class AddRelationship extends EditOperation {
  const AddRelationship({required this.relationship});

  final GraphRelation relationship;

  @override
  String get type => 'AddRelationship';

  @override
  Session apply(Session session) {
    final hasSource =
        session.entities.any((e) => e.id == relationship.sourceId);
    final hasTarget =
        session.entities.any((e) => e.id == relationship.targetId);
    if (!hasSource || !hasTarget) return session;
    if (relationship.sourceId == relationship.targetId) return session;
    if (session.relationships.any((r) => r.id == relationship.id)) return session;
    if (session.relationships.any((r) =>
        r.sourceId == relationship.sourceId &&
        r.targetId == relationship.targetId &&
        r.type == relationship.type)) {
      return session;
    }
    return session.copyWith(
      relationships: [...session.relationships, relationship],
    );
  }

  @override
  EditOperation inverse() => DeleteRelationship(relationship: relationship);

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'relationship': relationship.toJson(),
      };
}

/// Removes a knowledge-graph edge.
class DeleteRelationship extends EditOperation {
  const DeleteRelationship({required this.relationship});

  final GraphRelation relationship;

  @override
  String get type => 'DeleteRelationship';

  @override
  Session apply(Session session) {
    if (!session.relationships.any((r) => r.id == relationship.id)) {
      return session;
    }
    return session.copyWith(
      relationships: [
        for (final r in session.relationships)
          if (r.id != relationship.id) r,
      ],
    );
  }

  @override
  EditOperation inverse() => AddRelationship(relationship: relationship);

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'relationship': relationship.toJson(),
      };
}

/// Changes an edge's type (and confidence); a human edit clears AI confidence
/// on the edge (§4.7).
class RelabelRelationship extends EditOperation {
  const RelabelRelationship({
    required this.relationshipId,
    required this.oldRelationship,
    required this.newRelationship,
  });

  final String relationshipId;
  final GraphRelation oldRelationship;
  final GraphRelation newRelationship;

  @override
  String get type => 'RelabelRelationship';

  @override
  Session apply(Session session) {
    if (!session.relationships.any((r) => r.id == relationshipId)) {
      return session;
    }
    // A human relabel clears the edge's AI confidence (§4.7).
    final target = oldRelationship.confidence != null &&
            newRelationship.confidence != null
        ? newRelationship.copyWith(confidence: null)
        : newRelationship;
    return session.copyWith(
      relationships: [
        for (final r in session.relationships)
          if (r.id == relationshipId) target else r,
      ],
    );
  }

  @override
  EditOperation inverse() => RelabelRelationship(
        relationshipId: relationshipId,
        oldRelationship: newRelationship,
        newRelationship: oldRelationship,
      );

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'relationship_id': relationshipId,
        'old_relationship': oldRelationship.toJson(),
        'new_relationship': newRelationship.toJson(),
      };
}

/// Inverse of [DeleteEntity]: restores a node and its incident edges exactly.
class RestoreEntity extends EditOperation {
  const RestoreEntity({required this.entity, required this.incidentEdges});

  final GraphEntity entity;
  final List<GraphRelation> incidentEdges;

  @override
  String get type => 'RestoreEntity';

  @override
  Session apply(Session session) {
    final entities = session.entities.any((e) => e.id == entity.id)
        ? session.entities
        : [...session.entities, entity];
    final relationships = [...session.relationships];
    for (final edge in incidentEdges) {
      if (relationships.any((r) => r.id == edge.id)) continue;
      if (!entities.any((e) => e.id == edge.sourceId)) continue;
      if (!entities.any((e) => e.id == edge.targetId)) continue;
      relationships.add(edge);
    }
    return session.copyWith(entities: entities, relationships: relationships);
  }

  @override
  EditOperation inverse() => DeleteEntity(
        entity: entity,
        incidentEdges: incidentEdges,
      );

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'entity': entity.toJson(),
        'incident_edges': [for (final e in incidentEdges) e.toJson()],
      };
}

/// Inverse of [MergeEntities]: restores the [entity] node and returns the
/// [preMergeEdges] to their original endpoints (undo restores bit-for-bit).
class SplitEntity extends EditOperation {
  const SplitEntity({
    required this.entity,
    required this.targetId,
    required this.preMergeEdges,
  });

  final GraphEntity entity;
  final String targetId;
  final List<GraphRelation> preMergeEdges;

  @override
  String get type => 'SplitEntity';

  @override
  Session apply(Session session) {
    if (session.entities.any((e) => e.id == entity.id)) return session;
    if (!session.entities.any((e) => e.id == targetId)) return session;
    final entities = [...session.entities, entity];
    final relationships = [...session.relationships];
    for (final edge in preMergeEdges) {
      final existing = relationships.any((r) => r.id == edge.id);
      final duplicate = relationships.any((r) =>
          r.sourceId == edge.sourceId &&
          r.targetId == edge.targetId &&
          r.type == edge.type);
      if (existing || duplicate) continue;
      relationships.add(edge);
    }
    return session.copyWith(entities: entities, relationships: relationships);
  }

  @override
  EditOperation inverse() => MergeEntities(
        source: entity,
        targetId: targetId,
        mergedEdges: preMergeEdges,
      );

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'entity': entity.toJson(),
        'target_id': targetId,
        'pre_merge_edges': [for (final e in preMergeEdges) e.toJson()],
      };
}
