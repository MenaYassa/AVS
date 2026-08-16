import 'enums.dart';

/// One structured item inside an AI command draft (architecture §4.11).
///
/// Mirrors the canonical Draft item in `draft.schema.json`: `type` reuses the
/// canonical session item type so a draft can be mapped back onto session
/// topics/items when the user saves it.
class DraftItem {
  const DraftItem({
    required this.title,
    this.body = '',
    this.type,
    this.priority,
    this.confidence,
  });

  final String title;
  final String body;
  final ItemType? type;
  final Priority? priority;
  final double? confidence;

  DraftItem copyWith({
    String? title,
    String? body,
    ItemType? type,
    Priority? priority,
    double? confidence,
  }) {
    return DraftItem(
      title: title ?? this.title,
      body: body ?? this.body,
      type: type ?? this.type,
      priority: priority ?? this.priority,
      confidence: confidence ?? this.confidence,
    );
  }

  Map<String, dynamic> toJson() => {
        'title': title,
        'body': body,
        if (type != null) 'type': type!.name,
        if (priority != null) 'priority': priority!.name,
        if (confidence != null) 'confidence': confidence,
      };

  factory DraftItem.fromJson(Map<String, dynamic> json) => DraftItem(
        title: json['title'] as String? ?? '',
        body: json['body'] as String? ?? '',
        type: ItemType.fromWire(json['type'] as String?),
        priority: Priority.fromWire(json['priority'] as String?),
        confidence: (json['confidence'] as num?)?.toDouble(),
      );
}

/// Editable output of an AI command (architecture §4.11, spec §23).
///
/// Every command produces a Draft (`draft.schema.json`): a title, a body, and
/// optional structured items. Drafts are never auto-applied — the user edits
/// them and decides whether to save them into the session.
class CommandDraft {
  const CommandDraft({
    required this.id,
    required this.sessionId,
    required this.command,
    required this.title,
    required this.body,
    this.items = const [],
    this.promptVersions = const {},
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String sessionId;

  /// Engine command name (`engine/app/commands/names.py`).
  final String command;
  final String title;
  final String body;
  final List<DraftItem> items;

  /// Prompt asset versions used to produce this draft (§4.3 provenance).
  final Map<String, dynamic> promptVersions;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get hasItems => items.isNotEmpty;

  CommandDraft copyWith({
    String? title,
    String? body,
    List<DraftItem>? items,
    DateTime? updatedAt,
  }) {
    return CommandDraft(
      id: id,
      sessionId: sessionId,
      command: command,
      title: title ?? this.title,
      body: body ?? this.body,
      items: items ?? this.items,
      promptVersions: promptVersions,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'session_id': sessionId,
        'command': command,
        'title': title,
        'body': body,
        'items': items.map((i) => i.toJson()).toList(),
        'prompt_versions': promptVersions,
        'created_at': createdAt?.toIso8601String(),
        'updated_at': updatedAt?.toIso8601String(),
      };

  factory CommandDraft.fromJson(Map<String, dynamic> json) => CommandDraft(
        id: json['id'] as String,
        sessionId: json['session_id'] as String,
        command: json['command'] as String,
        title: json['title'] as String? ?? '',
        body: json['body'] as String? ?? '',
        items: (json['items'] as List<dynamic>? ?? const [])
            .map((e) => DraftItem.fromJson(e as Map<String, dynamic>))
            .toList(),
        promptVersions:
            (json['prompt_versions'] as Map<String, dynamic>?) ?? const {},
        createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
        updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? ''),
      );

  /// Parses the engine `result` of a command job into a draft for [sessionId].
  /// The result shape is `{command, session_id, prompt_versions, draft}`.
  factory CommandDraft.fromJobResult(
    Map<String, dynamic> result, {
    required String id,
    required String sessionId,
  }) {
    final draft = result['draft'] as Map<String, dynamic>? ?? const {};
    return CommandDraft(
      id: id,
      sessionId: sessionId,
      command: result['command'] as String? ?? '',
      title: draft['title'] as String? ?? '',
      body: draft['body'] as String? ?? '',
      items: (draft['items'] as List<dynamic>? ?? const [])
          .map((e) => DraftItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      promptVersions:
          (result['prompt_versions'] as Map<String, dynamic>?) ?? const {},
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    );
  }
}
