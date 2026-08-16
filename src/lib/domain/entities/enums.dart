/// Domain enums for the AI Knowledge Companion.
///
/// Mirrors the canonical data model in architecture §5.1 and the lifecycle
/// state machine in architecture §4.5.
library;

/// Session lifecycle state machine (architecture §4.5).
enum SessionStatus {
  recording,
  uploading,
  transcribing,
  cleaning,
  analyzing,
  validating,
  ready,
  edited,
  synced,
  failed,
  cancelled;

  bool get isTerminal => this == failed || this == cancelled;

  bool get isProcessing =>
      this == uploading ||
      this == transcribing ||
      this == cleaning ||
      this == analyzing ||
      this == validating;

  /// Parses the engine's `session_status` wire value (architecture §4.5);
  /// `null` for non-session kinds (e.g. a `transcribe` job).
  static SessionStatus? fromWire(String? value) {
    if (value == null) return null;
    return SessionStatus.values.where((s) => s.name == value).firstOrNull;
  }
}

/// Item type taxonomy (spec §10).
enum ItemType {
  idea,
  task,
  decision,
  question,
  problem,
  risk,
  goal,
  event,
  reminder,
  reference,
  observation,
  opportunity,
  actionItem;

  static ItemType? fromWire(String? value) {
    if (value == null) return null;
    return ItemType.values.where((t) => t.name == value).firstOrNull;
  }
}

enum Priority {
  low,
  medium,
  high;

  static Priority? fromWire(String? value) {
    if (value == null) return null;
    return Priority.values.where((p) => p.name == value).firstOrNull;
  }
}

/// Engine job kinds (architecture §4.2, §7.1).
enum JobKind { transcribe, analyze, rewrite, chat, command, insights }

/// Engine job lifecycle.
enum JobStatus {
  queued,
  running,
  succeeded,
  failed,
  cancelled;

  bool get isTerminal => this == failed || this == cancelled;

  bool get isRunning => this == queued || this == running;
}

/// Provider setting kinds (spec §7, §18).
enum ProviderKind { stt, llm }

/// Knowledge graph node types (architecture §4.8). Mirrors the canonical
/// `entity_type` enum in `session.schema.json`.
enum EntityType {
  person,
  project,
  organization,
  idea,
  task,
  decision,
  event,
  product,
  tool,
  place,
  concept,
  date;

  /// Wire value (snake_case) as used by the engine contract; identical to the
  /// Dart name for these single-word values but kept for uniformity.
  String get wireName => name;

  static EntityType? fromWire(String? value) {
    if (value == null) return null;
    return EntityType.values.where((t) => t.wireName == value).firstOrNull;
  }
}

/// Knowledge graph edge types (architecture §4.8). Mirrors the canonical
/// `relationship_type` enum in `session.schema.json`. Wire values are
/// snake_case (`participates_in`, `depends_on`, `assigned_to`).
enum RelationType {
  participatesIn,
  leads,
  discusses,
  dependsOn,
  assignedTo,
  relatedTo;

  /// Wire value (snake_case) as used by the engine contract.
  String get wireName {
    final buffer = StringBuffer();
    for (var i = 0; i < name.length; i++) {
      final c = name[i];
      if (i > 0 && c.toUpperCase() == c) buffer.write('_');
      buffer.write(c.toLowerCase());
    }
    return buffer.toString();
  }

  static RelationType? fromWire(String? value) {
    if (value == null) return null;
    return RelationType.values.where((t) => t.wireName == value).firstOrNull;
  }
}
