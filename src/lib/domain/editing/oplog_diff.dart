import '../entities/session.dart';
import 'edit_operations.dart';

/// The wire shape of an outbox diff (architecture §4.13 "diffs, not
/// documents", §5.3).
///
/// A diff carries the [base] snapshot the edits were recorded against (so the
/// conflict resolver can translate base-relative positions onto the current
/// cloud state) plus the applied [batches] in application order. Together they
/// are lossless: replaying `batches` onto a state identical to [base] yields
/// the editing device's exact local state.
class OplogDiff {
  const OplogDiff({
    required this.sessionId,
    required this.base,
    required this.batches,
    this.emittedAt,
  });

  final String sessionId;

  /// The session as it was before the first unsynced edit.
  final Session base;

  /// Applied operations (batches in application order).
  final List<List<EditOperation>> batches;

  final DateTime? emittedAt;

  Map<String, dynamic> toJson() => {
        'session_id': sessionId,
        'base': base.toCanonicalJson(),
        'batches': [
          for (final batch in batches)
            [for (final op in batch) op.toJson()],
        ],
        'emitted_at': emittedAt?.toIso8601String(),
      };

  factory OplogDiff.fromJson(Map<String, dynamic> json) => OplogDiff(
        sessionId: json['session_id'] as String,
        base: Session.fromCanonicalJson(
          json['base'] as Map<String, dynamic>,
          userId: json['session_id'] as String,
        ),
        batches: [
          for (final batch in (json['batches'] as List<dynamic>? ?? const []))
            [
              for (final op in (batch as List<dynamic>))
                EditOperation.fromJson(op as Map<String, dynamic>),
            ],
        ],
        emittedAt: DateTime.tryParse(json['emitted_at'] as String? ?? ''),
      );
}
