import 'session.dart';

/// An immutable snapshot of a session's knowledge at a commit point
/// (architecture §4.6). V1 is the initial AI output; every debounced edit
/// batch, prompt re-run, and restore appends a version. The snapshot is the
/// canonical Session JSON; the cloud stores the same with diffs computed on
/// demand.
class SessionVersion {
  const SessionVersion({
    required this.id,
    required this.sessionId,
    required this.versionNo,
    required this.snapshot,
    this.promptVersions = const {},
    this.changeReason,
    this.createdAt,
  });

  final String id;
  final String sessionId;
  final int versionNo;

  /// The knowledge content at this commit point. `userId` is not part of the
  /// canonical snapshot, so restore overlays it from the live session.
  final Session snapshot;
  final Map<String, dynamic> promptVersions;
  final String? changeReason;
  final DateTime? createdAt;

  SessionVersion copyWith({
    String? id,
    String? sessionId,
    int? versionNo,
    Session? snapshot,
    Map<String, dynamic>? promptVersions,
    String? changeReason,
    DateTime? createdAt,
    bool clearChangeReason = false,
  }) {
    return SessionVersion(
      id: id ?? this.id,
      sessionId: sessionId ?? this.sessionId,
      versionNo: versionNo ?? this.versionNo,
      snapshot: snapshot ?? this.snapshot,
      promptVersions: promptVersions ?? this.promptVersions,
      changeReason:
          clearChangeReason ? null : (changeReason ?? this.changeReason),
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
