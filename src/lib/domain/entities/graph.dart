import 'enums.dart';

/// A per-session knowledge subgraph (architecture §4.8): the session's nodes
/// plus the edges between them.
class SessionGraph {
  const SessionGraph({
    this.entities = const [],
    this.relationships = const [],
  });

  final List<GraphEntity> entities;
  final List<GraphRelation> relationships;

  SessionGraph copyWith({
    List<GraphEntity>? entities,
    List<GraphRelation>? relationships,
  }) =>
      SessionGraph(
        entities: entities ?? this.entities,
        relationships: relationships ?? this.relationships,
      );

  Map<String, dynamic> toJson() => {
        'entities': [for (final e in entities) e.toJson()],
        'relationships': [for (final r in relationships) r.toJson()],
      };

  /// Canonical (contract) shape used in version snapshots and cloud sync.
  Map<String, dynamic> toCanonicalJson() => {
        'entities': [for (final e in entities) e.toCanonicalJson()],
        'relationships': [
          for (final r in relationships) r.toCanonicalJson(),
        ],
      };

  factory SessionGraph.fromCanonicalJson(Map<String, dynamic> json) =>
      SessionGraph(
        entities: [
          for (final e in (json['entities'] as List<dynamic>? ?? const []))
            GraphEntity.fromCanonicalJson(e as Map<String, dynamic>),
        ],
        relationships: [
          for (final r
              in (json['relationships'] as List<dynamic>? ?? const []))
            GraphRelation.fromCanonicalJson(r as Map<String, dynamic>),
        ],
      );
}

/// A knowledge graph node (architecture §4.8).
class GraphEntity {
  const GraphEntity({
    required this.id,
    required this.userId,
    required this.type,
    required this.name,
    this.canonicalName,
    this.aliases = const [],
    this.confidence,
  });

  final String id;
  final String userId;
  final EntityType type;
  final String name;
  final String? canonicalName;
  final List<String> aliases;

  /// Internal confidence 0..1; never authoritative (architecture §4.7).
  final double? confidence;

  GraphEntity copyWith({
    String? name,
    String? canonicalName,
    List<String>? aliases,
    EntityType? type,
    double? confidence,
    bool clearCanonicalName = false,
    bool clearConfidence = false,
  }) {
    return GraphEntity(
      id: id,
      userId: userId,
      type: type ?? this.type,
      name: name ?? this.name,
      canonicalName:
          clearCanonicalName ? null : (canonicalName ?? this.canonicalName),
      aliases: aliases ?? this.aliases,
      confidence: clearConfidence ? null : (confidence ?? this.confidence),
    );
  }

  bool contentEquals(GraphEntity other) =>
      type == other.type &&
      name == other.name &&
      canonicalName == other.canonicalName &&
      confidence == other.confidence;

  Map<String, dynamic> toJson() => {
        'id': id,
        'user_id': userId,
        'type': type.wireName,
        'name': name,
        if (canonicalName != null) 'canonical_name': canonicalName,
        'aliases': aliases,
        if (confidence != null) 'confidence': confidence,
      };

  factory GraphEntity.fromJson(Map<String, dynamic> json) => GraphEntity(
        id: json['id'] as String,
        userId: json['user_id'] as String? ?? '',
        type: EntityType.fromWire(json['type'] as String?) ?? EntityType.idea,
        name: json['name'] as String,
        canonicalName: json['canonical_name'] as String?,
        aliases: (json['aliases'] as List<dynamic>? ?? const []).cast<String>(),
        confidence: (json['confidence'] as num?)?.toDouble(),
      );

  /// Canonical (contract) shape without app-only fields like `user_id`.
  Map<String, dynamic> toCanonicalJson() => {
        'id': id,
        'type': type.wireName,
        'name': name,
        'aliases': aliases,
        if (confidence != null) 'confidence': confidence,
      };

  factory GraphEntity.fromCanonicalJson(Map<String, dynamic> json) =>
      GraphEntity(
        id: json['id'] as String,
        userId: '',
        type: EntityType.fromWire(json['type'] as String?) ?? EntityType.idea,
        name: json['name'] as String,
        aliases: (json['aliases'] as List<dynamic>? ?? const []).cast<String>(),
        confidence: (json['confidence'] as num?)?.toDouble(),
      );
}

/// A knowledge graph edge (architecture §4.8).
class GraphRelation {
  const GraphRelation({
    required this.id,
    required this.userId,
    required this.sourceId,
    required this.targetId,
    required this.type,
    this.weight = 1.0,
    this.confidence,
    this.sessionId,
  });

  final String id;
  final String userId;
  final String sourceId;
  final String targetId;
  final RelationType type;
  final double weight;
  final double? confidence;
  final String? sessionId;

  GraphRelation copyWith({
    String? sourceId,
    String? targetId,
    RelationType? type,
    double? weight,
    double? confidence,
    bool clearConfidence = false,
  }) {
    return GraphRelation(
      id: id,
      userId: userId,
      sourceId: sourceId ?? this.sourceId,
      targetId: targetId ?? this.targetId,
      type: type ?? this.type,
      weight: weight ?? this.weight,
      confidence: clearConfidence ? null : (confidence ?? this.confidence),
      sessionId: sessionId,
    );
  }

  bool contentEquals(GraphRelation other) =>
      sourceId == other.sourceId &&
      targetId == other.targetId &&
      type == other.type &&
      weight == other.weight &&
      confidence == other.confidence;

  Map<String, dynamic> toJson() => {
        'id': id,
        'user_id': userId,
        'source_id': sourceId,
        'target_id': targetId,
        'type': type.wireName,
        'weight': weight,
        if (confidence != null) 'confidence': confidence,
        if (sessionId != null) 'session_id': sessionId,
      };

  factory GraphRelation.fromJson(Map<String, dynamic> json) => GraphRelation(
        id: json['id'] as String,
        userId: json['user_id'] as String? ?? '',
        sourceId: json['source_id'] as String,
        targetId: json['target_id'] as String,
        type: RelationType.fromWire(json['type'] as String?) ??
            RelationType.relatedTo,
        weight: (json['weight'] as num?)?.toDouble() ?? 1.0,
        confidence: (json['confidence'] as num?)?.toDouble(),
        sessionId: json['session_id'] as String?,
      );

  /// Canonical (contract) shape without app-only fields.
  Map<String, dynamic> toCanonicalJson() => {
        'id': id,
        'source_id': sourceId,
        'target_id': targetId,
        'type': type.wireName,
        'weight': weight,
        if (confidence != null) 'confidence': confidence,
      };

  factory GraphRelation.fromCanonicalJson(Map<String, dynamic> json) =>
      GraphRelation(
        id: json['id'] as String,
        userId: '',
        sourceId: json['source_id'] as String,
        targetId: json['target_id'] as String,
        type: RelationType.fromWire(json['type'] as String?) ??
            RelationType.relatedTo,
        weight: (json['weight'] as num?)?.toDouble() ?? 1.0,
        confidence: (json['confidence'] as num?)?.toDouble(),
      );
}
