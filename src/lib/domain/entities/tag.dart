/// A tag attached to sessions (spec §19).
class Tag {
  const Tag({required this.id, required this.userId, required this.name, this.color});

  final String id;
  final String userId;
  final String name;
  final String? color;

  factory Tag.fromJson(Map<String, dynamic> json) => Tag(
        id: json['id'] as String,
        userId: json['user_id'] as String,
        name: json['name'] as String,
        color: json['color'] as String?,
      );
}

/// Join row between sessions and tags.
class SessionTag {
  const SessionTag({required this.sessionId, required this.tagId});

  final String sessionId;
  final String tagId;
}
