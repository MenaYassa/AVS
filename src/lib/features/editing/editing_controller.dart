import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logging/app_logger.dart';
import '../../domain/editing/edit_operations.dart';
import '../../domain/editing/operation_log.dart';
import '../../domain/entities/session.dart';
import '../../domain/repositories.dart';
import '../../domain/usecases/edit_session.dart';

/// User-visible editing status for one session (architecture §3.4).
///
/// The controller is the single mutation path: every user edit goes through
/// [apply], every undo/redo through [undo]/[redo], and each successful
/// mutation bumps [EditingState.revision] so the session detail re-reads the
/// (persisted) session from the database and re-renders.
class EditingState {
  const EditingState({
    this.canUndo = false,
    this.canRedo = false,
    this.busy = false,
    this.revision = 0,
    this.appliedCount = 0,
    this.error,
  });

  final bool canUndo;
  final bool canRedo;
  final bool busy;

  /// Bumped after every persisted edit; used to re-read the session.
  final int revision;

  /// Count of committed edit batches (applies only — undo/redo don't count).
  /// Version history uses it to snapshot each debounced edit batch (§4.6).
  final int appliedCount;
  final String? error;

  bool get hasError => error != null;

  EditingState copyWith({
    bool? canUndo,
    bool? canRedo,
    bool? busy,
    int? revision,
    int? appliedCount,
    String? error,
    bool clearError = false,
  }) {
    return EditingState(
      canUndo: canUndo ?? this.canUndo,
      canRedo: canRedo ?? this.canRedo,
      busy: busy ?? this.busy,
      revision: revision ?? this.revision,
      appliedCount: appliedCount ?? this.appliedCount,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Per-session edit coordinator over the op-log (architecture §3.2, §3.4).
final editingControllerProvider =
    NotifierProvider.family<EditingController, EditingState, String>(
  EditingController.new,
);

final editSessionProvider = Provider<EditSession>((ref) {
  return EditSession(
    ref.watch(databaseProvider),
    ref.watch(editLogRepositoryProvider),
  );
});

class EditingController extends FamilyNotifier<EditingState, String> {
  OperationLog? _log;

  @override
  EditingState build(String sessionId) {
    _loadLog();
    return const EditingState();
  }

  OperationLog get _currentLog => _log ??= OperationLog();

  /// Reloads the persisted op-log so the UI reflects the true undo/redo
  /// position (called on startup and after a failed mutation).
  Future<void> _loadLog() async {
    try {
      final log = await ref.read(editLogRepositoryProvider).getLog(arg);
      _log = log ?? OperationLog();
      state = state.copyWith(
        canUndo: _log!.canUndo,
        canRedo: _log!.canRedo,
        busy: false,
        clearError: true,
      );
    } catch (e, st) {
      Log.e('Failed to load edit log', e, st);
    }
  }

  /// Applies [op] to the current session via the op-log and persists both the
  /// session and the log (the single mutation path, architecture §3.4).
  Future<void> apply(EditOperation op) async {
    final session = await _session();
    if (session == null) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      final result = await ref.read(editSessionProvider).apply(
            session: session,
            log: _currentLog,
            op: op,
          );
      _log = result.log;
      _markCommitted(fromApply: true);
    } catch (e, st) {
      Log.e('Failed to apply edit', e, st);
      state = state.copyWith(
        busy: false,
        error: 'Could not save the edit.',
      );
      await _loadLog();
    }
  }

  Future<void> undo() async {
    final session = await _session();
    if (session == null) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      final result = await ref.read(editSessionProvider).undo(
            session: session,
            log: _currentLog,
          );
      _log = result.log;
      _markCommitted();
    } catch (e, st) {
      Log.e('Failed to undo edit', e, st);
      state = state.copyWith(
        busy: false,
        error: 'Could not undo.',
      );
      await _loadLog();
    }
  }

  Future<void> redo() async {
    final session = await _session();
    if (session == null) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      final result = await ref.read(editSessionProvider).redo(
            session: session,
            log: _currentLog,
          );
      _log = result.log;
      _markCommitted();
    } catch (e, st) {
      Log.e('Failed to redo edit', e, st);
      state = state.copyWith(
        busy: false,
        error: 'Could not redo.',
      );
      await _loadLog();
    }
  }

  /// Clears the log for this session (e.g. after a re-run replaces content).
  Future<void> resetLog() async {
    _log = OperationLog();
    try {
      await ref.read(editLogRepositoryProvider).saveLog(arg, _log!);
    } catch (e, st) {
      Log.e('Failed to reset edit log', e, st);
    }
    state = state.copyWith(
      canUndo: false,
      canRedo: false,
      busy: false,
      clearError: true,
    );
  }

  void _markCommitted({bool fromApply = false}) {
    state = state.copyWith(
      canUndo: _log!.canUndo,
      canRedo: _log!.canRedo,
      busy: false,
      revision: state.revision + 1,
      appliedCount: fromApply ? state.appliedCount + 1 : state.appliedCount,
      clearError: true,
    );
  }

  Future<Session?> _session() => ref.read(databaseProvider).getSession(arg);
}
