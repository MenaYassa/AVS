/// AI memory context builder (architecture §4.9, spec §19).
///
/// Builds the opt-in, token-budgeted block of related-session context the
/// engine's analysis and chat prompts receive via `options.memory`. Each
/// descriptor is a compact digest (title, summary, open tasks) of another
/// session and is tagged with its source `session_id` so every downstream
/// answer stays traceable. Privacy: nothing leaves the device unless AI memory
/// is enabled, and a session can opt out via the session detail menu.
library;

import '../../domain/entities/enums.dart';
import '../../domain/entities/session.dart';
import '../../domain/entities/tag.dart';
import '../insights/insights_controller.dart';

/// How many related sessions may ride into one memory block.
const int kMaxMemoryEntries = 8;

/// Compact memory descriptor for one source session — the shape the engine's
/// `normalize_memory` accepts (`engine/app/memory.py`).
Map<String, dynamic> sessionToMemoryDescriptor(Session session) => {
      'session_id': session.id,
      'title': session.title ?? '',
      'summary': session.summary ?? '',
      'open_tasks': [
        for (final topic in session.topics)
          for (final item in topic.items)
            if (item.type == ItemType.task || item.type == ItemType.actionItem)
              item.title,
      ],
    };

/// Ranks the analyzed library for relatedness to [currentSessionId] — shared
/// tags first, then shared entities — and returns up to [kMaxMemoryEntries]
/// compact descriptors (deterministic; empty when nothing is related).
Future<List<Map<String, dynamic>>> buildMemoryContext({
  required List<Session> sessions,
  required String currentSessionId,
  required Future<List<Tag>> Function(String sessionId) tagsFor,
}) async {
  final current = sessions.where((s) => s.id == currentSessionId).firstOrNull;
  if (current == null) return const [];

  final currentEntities = current.entities.map((e) => e.name).toSet();
  final currentTags =
      (await tagsFor(currentSessionId)).map((t) => t.name).toSet();

  final scored = <(Session, int)>[];
  for (final candidate in sessions) {
    if (candidate.id == currentSessionId) continue;
    if (!isAnalyzedForInsights(candidate)) continue;
    final candidateTags =
        (await tagsFor(candidate.id)).map((t) => t.name).toSet();
    final candidateEntities = candidate.entities.map((e) => e.name).toSet();
    final score = candidateTags.intersection(currentTags).length +
        candidateEntities.intersection(currentEntities).length;
    if (score > 0) scored.add((candidate, score));
  }
  scored.sort((a, b) {
    final byScore = b.$2.compareTo(a.$2);
    if (byScore != 0) return byScore;
    return a.$1.id.compareTo(b.$1.id);
  });

  return [
    for (final (session, _) in scored.take(kMaxMemoryEntries))
      sessionToMemoryDescriptor(session),
  ];
}

/// Resolves the memory block to attach to an analysis or chat job for
/// [sessionId]: `[]` when AI memory is off, the session opts out, or nothing
/// is related — which the engine treats identically to a memory-less run.
///
/// Read at submission time (no cached provider) so toggles and per-session
/// skips always take effect on the next job. Dependencies are injected so it
/// works identically from controllers (a `Ref`) and tests (a container).
Future<List<Map<String, dynamic>>> memoryForSession({
  required bool enableMemory,
  required Future<bool> Function() readSkip,
  required Future<List<Session>> Function() readSessions,
  required Future<List<Tag>> Function(String sessionId) tagsFor,
  required String sessionId,
}) async {
  if (!enableMemory) return const [];
  final skip = await readSkip();
  if (skip) return const [];

  final sessions = await readSessions();
  return buildMemoryContext(
    sessions: sessions,
    currentSessionId: sessionId,
    tagsFor: tagsFor,
  );
}
