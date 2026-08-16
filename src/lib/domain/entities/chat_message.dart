/// One message in a per-session AI chat (architecture §4.11, spec §17).
///
/// `role` is `user` (the question, persisted before the job runs) or
/// `assistant` (the engine's grounded answer, persisted on job success).
/// Assistant messages carry citations + confidence + prompt provenance.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.sessionId,
    required this.role,
    required this.content,
    this.citations = const [],
    this.confidence,
    this.promptVersions = const {},
    this.createdAt,
  });

  final String id;
  final String sessionId;
  final ChatRole role;
  final String content;

  /// Source strings the engine cited for an assistant answer
  /// (`[transcript]`, `[summary]`, `[topic: "…"]`, `[item: "…"]`).
  final List<String> citations;

  /// How well the session context supported the answer, in [0, 1].
  final double? confidence;

  /// Prompt asset versions used to produce the answer (§4.3 provenance).
  final Map<String, dynamic> promptVersions;
  final DateTime? createdAt;

  bool get isUser => role == ChatRole.user;

  ChatMessage copyWith({
    List<String>? citations,
    double? confidence,
  }) {
    return ChatMessage(
      id: id,
      sessionId: sessionId,
      role: role,
      content: content,
      citations: citations ?? this.citations,
      confidence: confidence ?? this.confidence,
      promptVersions: promptVersions,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'session_id': sessionId,
        'role': role.name,
        'content': content,
        'citations': citations,
        if (confidence != null) 'confidence': confidence,
        'prompt_versions': promptVersions,
        'created_at': createdAt?.toIso8601String(),
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: json['id'] as String,
        sessionId: json['session_id'] as String,
        role: ChatRole.values
                .where((r) => r.name == json['role'])
                .firstOrNull ??
            ChatRole.user,
        content: json['content'] as String? ?? '',
        citations: (json['citations'] as List<dynamic>? ?? const [])
            .cast<String>(),
        confidence: (json['confidence'] as num?)?.toDouble(),
        promptVersions:
            (json['prompt_versions'] as Map<String, dynamic>?) ?? const {},
        createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
      );
}

/// Who authored a chat message.
enum ChatRole { user, assistant }
