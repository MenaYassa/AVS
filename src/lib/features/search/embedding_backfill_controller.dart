import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logging/app_logger.dart';
import '../../domain/entities/semantic_search_result.dart';
import '../../domain/entities/session.dart';
import '../../domain/repositories.dart';

/// Backfill state for the §6.1 semantic index (§6.1 follow-up): sessions that
/// completed analysis before the `embedding` stage shipped have no on-device
/// vector. The user can trigger a best-effort backfill that ships their text to
/// the engine and persists the returned vectors locally.
class EmbeddingBackfillStatus {
  const EmbeddingBackfillStatus({
    required this.missing,
    required this.inProgress,
    required this.embedded,
    this.error,
  });

  /// Analyzed sessions (ready/edited/synced) with no local embedding yet.
  final int missing;

  /// Count embedded by the last (or current) backfill run.
  final int embedded;

  final bool inProgress;
  final String? error;

  bool get complete => missing == 0 && !inProgress;

  EmbeddingBackfillStatus copyWith({
    int? missing,
    int? embedded,
    bool? inProgress,
    String? error,
    bool clearError = false,
  }) {
    return EmbeddingBackfillStatus(
      missing: missing ?? this.missing,
      embedded: embedded ?? this.embedded,
      inProgress: inProgress ?? this.inProgress,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Backfills on-device embeddings for pre-embedding sessions (§6.1). The
/// engine is the only place models run (architecture §2), so the app ships
/// session text and stores the returned vectors via `EmbeddingRepository`.
final embeddingBackfillControllerProvider =
    AsyncNotifierProvider<EmbeddingBackfillController, EmbeddingBackfillStatus>(
        EmbeddingBackfillController.new);

class EmbeddingBackfillController
    extends AsyncNotifier<EmbeddingBackfillStatus> {
  static const _batchSize = 10;

  @override
  Future<EmbeddingBackfillStatus> build() async {
    final missing = await _missingCount();
    return EmbeddingBackfillStatus(
      missing: missing,
      inProgress: false,
      embedded: 0,
    );
  }

  Future<int> _missingCount() async =>
      (await ref
              .read(embeddingRepositoryProvider)
              .sessionsWithoutLocalEmbedding())
          .length;

  /// Best-effort backfill: never throws — engine/db failures surface as
  /// [EmbeddingBackfillStatus.error] and leave the app usable.
  Future<void> backfill() async {
    if (state.value?.inProgress ?? false) return;

    final ids = await ref
        .read(embeddingRepositoryProvider)
        .sessionsWithoutLocalEmbedding();
    if (ids.isEmpty) {
      state = AsyncData(EmbeddingBackfillStatus(
        missing: 0,
        inProgress: false,
        embedded: 0,
      ));
      return;
    }

    state = AsyncData(EmbeddingBackfillStatus(
      missing: ids.length,
      inProgress: true,
      embedded: 0,
    ));

    var embedded = 0;
    for (final batch in _chunks(ids, _batchSize)) {
      final sessions = <Session>[];
      for (final id in batch) {
        final session = await ref.read(databaseProvider).getSession(id);
        if (session != null) sessions.add(session);
      }
      if (sessions.isEmpty) continue;

      final EngineEmbedSessions result;
      try {
        result = await ref
            .read(engineGatewayProvider)
            .embedSessions([for (final s in sessions) (sessionId: s.id, text: _composeText(s))]);
      } catch (e, st) {
        Log.e('Embedding backfill failed', e, st);
        state = AsyncData(EmbeddingBackfillStatus(
          missing: ids.length,
          inProgress: false,
          embedded: embedded,
          error: e is AppFailure ? e.message : 'Embedding service unavailable',
        ));
        return;
      }

      final embeddings = ref.read(embeddingRepositoryProvider);
      for (final entry in result.embeddings) {
        await embeddings.upsertSessionEmbedding(
          sessionId: entry.sessionId,
          scope: 'local',
          contentRef: entry.dimension.toString(),
          vector: entry.embedding,
        );
      }
      embedded += result.embeddings.length;
    }

    final remaining = await _missingCount();
    state = AsyncData(EmbeddingBackfillStatus(
      missing: remaining,
      inProgress: false,
      embedded: embedded,
    ));
  }

  /// Composes the same content the engine's `EmbeddingStage` embeds for fresh
  /// analysis: title, summary, topic titles, and item content (architecture
  /// §5.1 canonical shape; item `description` carries the body locally).
  static String _composeText(Session session) {
    final parts = <String>[
      if (session.title != null && session.title!.isNotEmpty) session.title!,
      if (session.summary != null && session.summary!.isNotEmpty)
        session.summary!,
      for (final topic in session.topics) ...[
        topic.title,
        for (final item in topic.items) ...[
          item.title,
          if (item.description.isNotEmpty) item.description,
        ],
      ],
    ];
    return parts.join(' | ');
  }

  static List<List<String>> _chunks(List<String> ids, int size) {
    final chunks = <List<String>>[];
    for (var i = 0; i < ids.length; i += size) {
      chunks.add(ids.sublist(i, i + size > ids.length ? ids.length : i + size));
    }
    return chunks;
  }
}
