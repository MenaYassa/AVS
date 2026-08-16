/// Cross-session intelligence results (architecture §4.9, spec §19).
///
/// Each insight is a deterministic clustering statement (e.g. *"You've
/// discussed Benchmark Platform in 3 sessions"*) that records its source
/// sessions — `sources` is the provenance that makes every claim explainable
/// and tappable back to the sessions it was derived from.
class Insight {
  const Insight({
    required this.kind,
    required this.label,
    required this.sessionCount,
    this.mentionCount = 0,
    required this.confidence,
    required this.statement,
    required this.sources,
  });

  /// The clustering axis: shared entity or shared tag.
  final InsightKind kind;
  final String label;
  final int sessionCount;
  final int mentionCount;

  /// Deterministic evidence strength in [0, 1], derived from how many
  /// distinct sessions share the label.
  final double confidence;
  final String statement;

  /// Source sessions, sorted by title (the provenance).
  final List<InsightSource> sources;

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'label': label,
        'session_count': sessionCount,
        'mention_count': mentionCount,
        'confidence': confidence,
        'statement': statement,
        'sources': sources.map((s) => s.toJson()).toList(),
      };

  factory Insight.fromJson(Map<String, dynamic> json) => Insight(
        kind: InsightKind.values
                .where((k) => k.name == json['kind'])
                .firstOrNull ??
            InsightKind.entity,
        label: json['label'] as String? ?? '',
        sessionCount: json['session_count'] as int? ?? 0,
        mentionCount: json['mention_count'] as int? ?? 0,
        confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
        statement: json['statement'] as String? ?? '',
        sources: (json['sources'] as List<dynamic>? ?? const [])
            .map((s) => InsightSource.fromJson(s as Map<String, dynamic>))
            .toList(),
      );
}

/// One session an insight was derived from (provenance, §4.9).
class InsightSource {
  const InsightSource({required this.sessionId, required this.title, this.snippet});

  final String sessionId;
  final String title;

  /// A short excerpt from that session containing the clustered label.
  final String? snippet;

  Map<String, dynamic> toJson() => {
        'session_id': sessionId,
        'title': title,
        if (snippet != null) 'snippet': snippet,
      };

  factory InsightSource.fromJson(Map<String, dynamic> json) => InsightSource(
        sessionId: json['session_id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        snippet: json['snippet'] as String?,
      );
}

/// The clustering axis for an insight.
enum InsightKind { entity, tag, person, project, task, decision }

/// The full result of an insights job (`insights.schema.json`).
class InsightResult {
  const InsightResult({
    required this.insights,
    this.generatedAt,
    this.totalSessions = 0,
  });

  final List<Insight> insights;
  final DateTime? generatedAt;
  final int totalSessions;

  factory InsightResult.fromJson(Map<String, dynamic> json) => InsightResult(
        insights: (json['insights'] as List<dynamic>? ?? const [])
            .map((i) => Insight.fromJson(i as Map<String, dynamic>))
            .toList(),
        generatedAt: DateTime.tryParse(json['generated_at'] as String? ?? ''),
        totalSessions: json['total_sessions'] as int? ?? 0,
      );
}
