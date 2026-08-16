import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/logging/app_logger.dart';
import '../../domain/entities/session.dart';
import '../../domain/entities/session_version.dart';
import '../../domain/entities/enums.dart';
import '../../domain/repositories.dart';
import '../../domain/versioning/session_diff.dart';
import '../editing/editing_controller.dart';

/// Version-history status for one session (architecture §4.6).
class VersioningState {
  const VersioningState({
    this.versions = const [],
    this.selectedVersionNo,
    this.busy = false,
    this.error,
  });

  /// Ascending version number order; the last entry is the current head.
  final List<SessionVersion> versions;
  final int? selectedVersionNo;
  final bool busy;
  final String? error;

  bool get hasError => error != null;

  VersioningState copyWith({
    List<SessionVersion>? versions,
    int? selectedVersionNo,
    bool? busy,
    String? error,
    bool clearError = false,
    bool clearSelection = false,
  }) {
    return VersioningState(
      versions: versions ?? this.versions,
      selectedVersionNo:
          clearSelection ? null : (selectedVersionNo ?? this.selectedVersionNo),
      busy: busy ?? this.busy,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Per-session version coordinator: commits commit points (§4.6) and applies
/// restores. Commits are serialized so rapid edit batches coalesce into
/// sequential versions without races.
final versioningControllerProvider =
    NotifierProvider.family<VersioningController, VersioningState, String>(
  VersioningController.new,
);

class VersioningController extends FamilyNotifier<VersioningState, String> {
  bool _loaded = false;
  Future<void> _chain = Future.value();

  @override
  VersioningState build(String sessionId) {
    _init();
    return const VersioningState();
  }

  /// Runs [op] atomically against other versioning mutations (async mutex).
  Future<T> _serialized<T>(Future<T> Function() op) {
    final result = _chain.then((_) => op());
    _chain = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<void> _init() => _serialized(() async {
        await _loadOnce();
        if (state.versions.isEmpty) {
          await _commitInitialIfNeeded();
        }
      });

  Future<void> _loadOnce() async {
    if (_loaded) return;
    try {
      final versions = await ref.read(versionRepositoryProvider).getVersions(arg);
      _loaded = true;
      state = state.copyWith(versions: versions, clearError: true);
    } catch (e, st) {
      Log.e('Failed to load version history', e, st);
      state = state.copyWith(error: 'Could not load version history.');
    }
  }

  /// Snapshot commit points as they happen: the editing controller bumps
  /// `appliedCount` per committed batch; the session detail screen calls this
  /// on every change so each batch lands as its own version.
  Future<void> commitEditBatch() => _serialized(() async {
        if (!_loaded) await _loadOnce();
        final target = _currentAppliedCount;
        while (_lastApplied < target) {
          await _commitOnce();
          _lastApplied++;
        }
      });

  int get _currentAppliedCount =>
      ref.read(editingControllerProvider(arg)).appliedCount;

  int _lastApplied = 0;

  /// Commit point for prompt re-runs (§4.6): after analysis applies a (new)
  /// canonical session, snapshot it. The first successful analysis lands as V1
  /// ("AI output"); a re-analysis that changed content appends a version.
  Future<void> commitAnalysisResult() => _serialized(() async {
        if (!_loaded) await _loadOnce();
        await _commitOnce(reason: 'Re-analyzed with new prompts');
      });

  Future<void> _commitOnce({String? reason}) async {
    final session = await _session();
    if (session == null) return;

    if (state.versions.isEmpty) {
      await _commitInitialIfNeeded();
      return;
    }
    final latest = state.versions.last;
    if (_contentEqual(latest.snapshot, session)) return;
    final summary = summarizeDiff(diffSessions(latest.snapshot, session));
    await _commit(
      snapshot: session,
      reason: reason ?? 'Edited: ${summary ?? 'content'}',
    );
  }

  /// V1 = the initial AI output. Skipped until the session is ready and has
  /// real content, so half-analyzed sessions never get snapshotted.
  Future<void> _commitInitialIfNeeded() async {
    final session = await _session();
    if (session == null) return;
    if (session.status != SessionStatus.ready) return;
    if (session.topics.isEmpty &&
        session.summary == null &&
        session.title == null) {
      return;
    }
    await _commit(snapshot: session, reason: 'AI output');
  }

  Future<void> _commit({
    required Session snapshot,
    required String reason,
  }) async {
    try {
      final version = await ref.read(versionRepositoryProvider).commit(
            SessionVersion(
              id: const Uuid().v4(),
              sessionId: arg,
              versionNo: (state.versions.isEmpty ? 0 : state.versions.last.versionNo) + 1,
              snapshot: snapshot,
              promptVersions: snapshot.promptVersions,
              changeReason: reason,
              createdAt: DateTime.now().toUtc(),
            ),
          );
      state = state.copyWith(
        versions: [...state.versions, version],
        busy: false,
        clearError: true,
      );
    } catch (e, st) {
      Log.e('Failed to commit version', e, st);
      state = state.copyWith(
        busy: false,
        error: 'Could not save the version.',
      );
    }
  }

  /// Restores [versionNo]: its snapshot becomes the working copy (overlaid on
  /// the live session for audio/transcript/user fields) and a new "restored
  /// from v{n}" version records the restore (§4.6). The edit log is cleared so
  /// undo can never cross into pre-restore history.
  Future<Session?> restore(int versionNo) => _serialized(() async {
        if (!_loaded) await _loadOnce();
        final target =
            state.versions.where((v) => v.versionNo == versionNo).firstOrNull;
        if (target == null) return null;
        final live = await _session();
        if (live == null) return null;

        state = state.copyWith(busy: true, clearError: true);
        try {
          final restored = live.copyWith(
            title: target.snapshot.title,
            summary: target.snapshot.summary,
            alternativeTitles: target.snapshot.alternativeTitles,
            summaryConfidence: target.snapshot.summaryConfidence,
            extractionConfidence: target.snapshot.extractionConfidence,
            promptVersions: target.snapshot.promptVersions,
            status: SessionStatus.ready,
            topics: target.snapshot.topics,
            entities: target.snapshot.entities,
            relationships: target.snapshot.relationships,
            updatedAt: DateTime.now().toUtc(),
            clearError: true,
          );
          await ref.read(databaseProvider).updateSession(restored);
          await _commit(snapshot: restored, reason: 'Restored from v$versionNo');
          await ref.read(editingControllerProvider(arg).notifier).resetLog();
          return restored;
        } finally {
          state = state.copyWith(busy: false);
        }
      });

  void select(int? versionNo) {
    state = state.copyWith(selectedVersionNo: versionNo);
  }

  Future<Session?> _session() => ref.read(databaseProvider).getSession(arg);

  /// Content equality used to skip no-op commits. Compares the knowledge
  /// content (title/summary/topics via the diff) plus prompt provenance, and
  /// deliberately ignores timestamps/user/audio fields that are not knowledge.
  bool _contentEqual(Session a, Session b) =>
      mapEquals(a.promptVersions, b.promptVersions) &&
      diffSessions(a, b).isEmpty;
}
