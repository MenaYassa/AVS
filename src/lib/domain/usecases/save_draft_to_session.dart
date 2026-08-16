/// Builds edit operations to save a CommandDraft into a session.
///
/// The result is a list of [EditOperation] that can be applied sequentially
/// through the editing controller. This is a pure domain function — no side
/// effects — so it's fully testable.
library;

import 'package:uuid/uuid.dart';

import '../editing/edit_operations.dart';
import '../entities/command_draft.dart';
import '../entities/enums.dart';
import '../entities/session.dart';

/// Converts a [CommandDraft] into a list of edit operations that, when applied
/// to [session], incorporate the draft's content.
///
/// Behavior:
/// - If the draft has structured items: creates a new topic titled [draft.title]
///   (or "Command output" as fallback) with the items. The draft body becomes
///   the topic description.
/// - If the draft is body-only: adds a single `reference` item in a new topic
///   with the draft title and body.
List<EditOperation> buildSaveDraftOperations(
  Session session,
  CommandDraft draft,
) {
  final ops = <EditOperation>[];
  final topicId = const Uuid().v4();
  final topicTitle = draft.title.isNotEmpty ? draft.title : 'Command output';

  if (draft.hasItems) {
    // Structured items → new topic with typed items
    final items = draft.items
        .map(
          (di) => Item(
            id: const Uuid().v4(),
            type: di.type ?? ItemType.reference,
            title: di.title,
            description: di.body,
            priority: di.priority,
            confidence: di.confidence,
          ),
        )
        .toList();

    ops.add(AddTopic(
      topic: Topic(
        id: topicId,
        title: topicTitle,
        description: draft.body,
        position: session.topics.length,
        items: items,
      ),
      position: session.topics.length,
    ));
  } else {
    // Body-only draft → single reference item in a new topic
    final item = Item(
      id: const Uuid().v4(),
      type: ItemType.reference,
      title: topicTitle,
      description: draft.body,
    );

    ops.add(AddTopic(
      topic: Topic(
        id: topicId,
        title: topicTitle,
        description: '',
        position: session.topics.length,
        items: [item],
      ),
      position: session.topics.length,
    ));
  }

  return ops;
}