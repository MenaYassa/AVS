import '../entities/session.dart';
import 'edit_operations.dart';

/// The undo/redo-aware mutation log (architecture §3.4, §4.6).
///
/// Operations are appended in batches (a continuous drag or typing burst
/// coalesces into a single entry). `undo`/`redo` move the cursor and return
/// the batch to invert/replay. The log is serializable so it can be persisted
/// locally and emitted as a diff (§3.4, §4.13).
class OperationLog {
  OperationLog({
    List<List<EditOperation>>? batches,
    int? cursor,
    int? syncWatermark,
  })  : _batches = batches ?? <List<EditOperation>>[],
        _cursor = cursor ?? 0,
        _syncWatermark = syncWatermark ?? 0;

  final List<List<EditOperation>> _batches;
  int _cursor;

  /// Index of the first batch the sync layer has already emitted (§4.13).
  /// Only moves forward; a successful sync advances it to [cursor].
  int _syncWatermark;

  /// All committed batches (for diff emission).
  List<List<EditOperation>> get batches => List.unmodifiable(_batches);

  /// The batches currently applied (everything before the cursor).
  List<List<EditOperation>> get appliedBatches => List.unmodifiable(
        _batches.take(_cursor),
      );

  List<EditOperation> get appliedOps => [
        for (final batch in appliedBatches)
          for (final op in batch) op,
      ];

  bool get canUndo => _cursor > 0;
  bool get canRedo => _cursor < _batches.length;
  int get batchCount => _batches.length;
  int get cursor => _cursor;

  /// Index of the first not-yet-synced batch (architecture §4.13).
  int get syncWatermark => _syncWatermark;

  /// True when the applied state differs from the last synced state.
  bool get hasUnsyncedEdits => _cursor != _syncWatermark;

  /// The batches (in application order) that bring the synced state to the
  /// current applied state — the lossless diff the sync engine pushes.
  ///
  /// - `cursor >= watermark`: the normal case, the applied-but-unsynced tail.
  /// - `cursor < watermark`: an undo rewound the cursor below the sync point,
  ///   so the emitted diff is the inverse of the batches that were synced and
  ///   then un-done (the cloud state must converge backwards).
  List<List<EditOperation>> unsyncedDelta() {
    if (_cursor >= _syncWatermark) {
      return [
        for (final batch in _batches.sublist(_syncWatermark, _cursor)) batch,
      ];
    }
    return [
      for (var i = _syncWatermark - 1; i >= _cursor; i--)
        [for (final op in _batches[i].reversed) op.inverse()],
    ];
  }

  /// Records that the current applied state has been synced.
  void markSynced() => _syncWatermark = _cursor;

  /// True when a continuous batch is open and not yet committed.
  bool get hasOpenBatch => _open != null;

  /// Convenience for callers that don't need batching: append a single op.
  OperationLog apply(EditOperation op) {
    _commit([op]);
    return this;
  }

  /// Open a continuous batch (e.g. while dragging / typing). Nested opens are
  /// collapsed. Returns the group id of the current open batch.
  int? _open;

  void beginBatch() {
    if (_open != null) return;
    // A new edit invalidates any redo tail.
    _batches.removeRange(_cursor, _batches.length);
    _open = _batches.length;
  }

  /// Records into the open batch (no-op when none is open).
  void record(EditOperation op) {
    if (_open == null) return;
    if (_open == _batches.length) {
      // First record of a fresh open batch: append an empty slot.
      _batches.add(<EditOperation>[]);
    }
    _batches[_open!] = [..._batches[_open!], op];
    // A batch is part of the applied tail while open.
    _cursor = _batches.length;
  }

  /// Commits the open batch as a single undo/redo entry.
  void endBatch() {
    if (_open == null) return;
    _open = null;
    _cursor = _batches.length;
  }

  /// Records an operation into the log and returns the resulting session.
  Session applyOp(Session session, EditOperation op) {
    final next = op.apply(session);
    _commit([op]);
    return next;
  }

  /// Records a continuous batch and returns the resulting session.
  Session applyBatch(Session session, List<EditOperation> ops) {
    var next = session;
    for (final op in ops) {
      next = op.apply(next);
    }
    _commit(ops);
    return next;
  }

  void _commit(List<EditOperation> ops) {
    if (ops.isEmpty) return;
    // Trim any redo tail before appending.
    _batches.removeRange(_cursor, _batches.length);
    _batches.add(ops);
    _cursor = _batches.length;
  }

  /// Moves the cursor back one batch; returns the batch whose inverses must be
  /// applied to reach the previous state (empty when nothing to undo).
  List<EditOperation> undo() {
    if (_cursor == 0) return const [];
    _cursor--;
    return _batches[_cursor];
  }

  /// Moves the cursor forward one batch; returns the batch to re-apply
  /// (empty when nothing to redo).
  List<EditOperation> redo() {
    if (_cursor >= _batches.length) return const [];
    return _batches[_cursor++];
  }

  /// Canonical JSON: batches plus the undo/redo cursor, so a persisted log is
  /// restored with the same undo/redo position. Mirrors the wire contract in
  /// architecture §5.3 (outbox diff emission).
  Map<String, dynamic> toJson() => {
        'batches': [
          for (final batch in _batches)
            [for (final op in batch) op.toJson()],
        ],
        'cursor': _cursor,
        'sync_watermark': _syncWatermark,
      };

  factory OperationLog.fromJson(Map<String, dynamic>? json) {
    if (json == null) return OperationLog();
    return OperationLog(
      batches: [
        for (final batch in (json['batches'] as List<dynamic>? ?? const []))
          [
            for (final op in (batch as List<dynamic>))
              EditOperation.fromJson(op as Map<String, dynamic>),
          ],
      ],
      cursor: (json['cursor'] as num?)?.toInt() ?? 0,
      syncWatermark: (json['sync_watermark'] as num?)?.toInt() ?? 0,
    );
  }
}
