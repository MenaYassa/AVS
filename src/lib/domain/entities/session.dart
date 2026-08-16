import 'enums.dart';
import 'graph.dart';

/// A knowledge item inside a topic (architecture §5.1).
class Item {
  const Item({
    required this.id,
    required this.type,
    required this.title,
    this.description = '',
    this.position = 0,
    this.priority,
    this.timestampSec,
    this.confidence,
  });

  final String id;
  final ItemType type;
  final String title;
  final String description;
  final int position;
  final Priority? priority;
  final double? timestampSec;

  /// Internal confidence 0..1; never authoritative (architecture §4.7).
  final double? confidence;

  Item copyWith({
    String? type,
    String? title,
    String? description,
    int? position,
    Priority? priority,
    double? timestampSec,
    double? confidence,
    bool clearPriority = false,
    bool clearTimestamp = false,
    bool clearConfidence = false,
  }) {
    return Item(
      id: id,
      type: ItemType.values.firstWhere((t) => t.name == (type ?? this.type.name)),
      title: title ?? this.title,
      description: description ?? this.description,
      position: position ?? this.position,
      priority: clearPriority ? null : (priority ?? this.priority),
      timestampSec: clearTimestamp ? null : (timestampSec ?? this.timestampSec),
      confidence: clearConfidence ? null : (confidence ?? this.confidence),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'position': position,
        'title': title,
        'description': description,
        if (priority != null) 'priority': priority!.name,
        if (timestampSec != null) 'timestamp_sec': timestampSec,
        if (confidence != null) 'confidence': confidence,
      };

  factory Item.fromJson(Map<String, dynamic> json) => Item(
        id: json['id'] as String,
        type: ItemType.fromWire(json['type'] as String?) ?? ItemType.idea,
        title: json['title'] as String? ?? '',
        description: json['description'] as String? ?? '',
        position: (json['position'] as num?)?.toInt() ?? 0,
        priority: Priority.fromWire(json['priority'] as String?),
        timestampSec: (json['timestamp_sec'] as num?)?.toDouble(),
        confidence: (json['confidence'] as num?)?.toDouble(),
      );
}

/// A topic containing items (architecture §5.1).
class Topic {
  const Topic({
    required this.id,
    required this.title,
    required this.position,
    this.description = '',
    this.confidence,
    List<Item>? items,
  }) : items = items ?? const [];

  final String id;
  final String title;
  final String description;
  final int position;
  final double? confidence;
  final List<Item> items;

  Topic copyWith({
    String? title,
    String? description,
    int? position,
    double? confidence,
    List<Item>? items,
    bool clearConfidence = false,
  }) {
    return Topic(
      id: id,
      title: title ?? this.title,
      description: description ?? this.description,
      position: position ?? this.position,
      confidence: clearConfidence ? null : (confidence ?? this.confidence),
      items: items ?? this.items,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'position': position,
        'title': title,
        'description': description,
        if (confidence != null) 'confidence': confidence,
        'items': items.map((i) => i.toJson()).toList(),
      };

  factory Topic.fromJson(Map<String, dynamic> json) => Topic(
        id: json['id'] as String,
        title: json['title'] as String? ?? '',
        description: json['description'] as String? ?? '',
        position: (json['position'] as num?)?.toInt() ?? 0,
        confidence: (json['confidence'] as num?)?.toDouble(),
        items: (json['items'] as List<dynamic>? ?? const [])
            .map((e) => Item.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// A knowledge session (architecture §5.1, §4.5).
class Session {
  const Session({
    required this.id,
    required this.userId,
    this.title,
    this.alternativeTitles = const [],
    this.summary,
    this.summaryConfidence,
    this.extractionConfidence,
    this.language,
    this.status = SessionStatus.recording,
    this.durationSec,
    this.wordCount,
    this.originalTranscript,
    this.cleanedTranscript,
    this.audioPath,
    this.audioRemoteUrl,
    this.promptVersions = const {},
    this.favorite = false,
    this.archived = false,
    this.deleted = false,
    this.pinned = false,
    this.lastError,
    this.createdAt,
    this.updatedAt,
    this.topics = const [],
    this.entities = const [],
    this.relationships = const [],
  });

  final String id;
  final String userId;
  final String? title;
  final List<String> alternativeTitles;
  final String? summary;
  final double? summaryConfidence;
  final double? extractionConfidence;
  final String? language;
  final SessionStatus status;
  final double? durationSec;
  final int? wordCount;
  final String? originalTranscript;
  final String? cleanedTranscript;
  final String? audioPath;
  final String? audioRemoteUrl;
  final Map<String, dynamic> promptVersions;
  final bool favorite;
  final bool archived;
  final bool deleted;
  final bool pinned;
  final String? lastError;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final List<Topic> topics;

  /// Per-session knowledge-graph subgraph (architecture §4.8): the entities
  /// this session mentions and the edges between them. Rides the canonical
  /// JSON so versions, diffs, edits, and sync all cover the graph.
  final List<GraphEntity> entities;
  final List<GraphRelation> relationships;

  Session copyWith({
    String? title,
    List<String>? alternativeTitles,
    String? summary,
    double? summaryConfidence,
    double? extractionConfidence,
    String? language,
    SessionStatus? status,
    double? durationSec,
    int? wordCount,
    String? originalTranscript,
    String? cleanedTranscript,
    String? audioPath,
    String? audioRemoteUrl,
    Map<String, dynamic>? promptVersions,
    bool? favorite,
    bool? archived,
    bool? deleted,
    bool? pinned,
    String? lastError,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<Topic>? topics,
    List<GraphEntity>? entities,
    List<GraphRelation>? relationships,
    bool clearTitle = false,
    bool clearSummary = false,
    bool clearAudioPath = false,
    bool clearError = false,
  }) {
    return Session(
      id: id,
      userId: userId,
      title: clearTitle ? null : (title ?? this.title),
      alternativeTitles: alternativeTitles ?? this.alternativeTitles,
      summary: clearSummary ? null : (summary ?? this.summary),
      summaryConfidence: summaryConfidence ?? this.summaryConfidence,
      extractionConfidence:
          extractionConfidence ?? this.extractionConfidence,
      language: language ?? this.language,
      status: status ?? this.status,
      durationSec: durationSec ?? this.durationSec,
      wordCount: wordCount ?? this.wordCount,
      originalTranscript: originalTranscript ?? this.originalTranscript,
      cleanedTranscript: cleanedTranscript ?? this.cleanedTranscript,
      audioPath: clearAudioPath ? null : (audioPath ?? this.audioPath),
      audioRemoteUrl: audioRemoteUrl ?? this.audioRemoteUrl,
      promptVersions: promptVersions ?? this.promptVersions,
      favorite: favorite ?? this.favorite,
      archived: archived ?? this.archived,
      deleted: deleted ?? this.deleted,
      pinned: pinned ?? this.pinned,
      lastError: clearError ? null : (lastError ?? this.lastError),
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      topics: topics ?? this.topics,
      entities: entities ?? this.entities,
      relationships: relationships ?? this.relationships,
    );
  }

  Map<String, dynamic> toCanonicalJson() => {
        'schema_version': 1,
        'session': {
          'id': id,
          'title': title,
          'alternative_titles': alternativeTitles,
          'summary': summary,
          'summary_confidence': summaryConfidence,
          'extraction_confidence': extractionConfidence,
          'language': language,
          'status': status.name,
          'created_at': createdAt?.toIso8601String(),
          'duration_sec': durationSec,
          'word_count': wordCount,
          'favorite': favorite,
          'archived': archived,
          'deleted': deleted,
          'pinned': pinned,
          'prompt_versions': promptVersions,
          'topics': topics.map((t) => t.toJson()).toList(),
          'entities': entities.map((e) => e.toCanonicalJson()).toList(),
          'relationships':
              relationships.map((r) => r.toCanonicalJson()).toList(),
        },
      };

  factory Session.fromCanonicalJson(
    Map<String, dynamic> json, {
    required String userId,
    String? audioPath,
    String? originalTranscript,
    DateTime? createdAt,
  }) {
    final s = json['session'] as Map<String, dynamic>;
    return Session(
      id: s['id'] as String,
      userId: userId,
      title: s['title'] as String?,
      alternativeTitles: (s['alternative_titles'] as List<dynamic>? ?? const [])
          .cast<String>(),
      summary: s['summary'] as String?,
      summaryConfidence: (s['summary_confidence'] as num?)?.toDouble(),
      extractionConfidence: (s['extraction_confidence'] as num?)?.toDouble(),
      language: s['language'] as String?,
      status: SessionStatus.values
              .where((e) => e.name == s['status'])
              .firstOrNull ??
          SessionStatus.ready,
      createdAt: createdAt ?? DateTime.tryParse(s['created_at'] as String? ?? ''),
      promptVersions: (s['prompt_versions'] as Map<String, dynamic>?) ?? const {},
      favorite: s['favorite'] as bool? ?? false,
      archived: s['archived'] as bool? ?? false,
      deleted: s['deleted'] as bool? ?? false,
      pinned: s['pinned'] as bool? ?? false,
      topics: (s['topics'] as List<dynamic>? ?? const [])
          .map((e) => Topic.fromJson(e as Map<String, dynamic>))
          .toList(),
      entities: (s['entities'] as List<dynamic>? ?? const [])
          .map((e) => GraphEntity.fromCanonicalJson(e as Map<String, dynamic>))
          .toList(),
      relationships: (s['relationships'] as List<dynamic>? ?? const [])
          .map(
              (e) => GraphRelation.fromCanonicalJson(e as Map<String, dynamic>))
          .toList(),
      audioPath: audioPath,
      originalTranscript: originalTranscript,
    );
  }
}
