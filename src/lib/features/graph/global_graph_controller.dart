import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/graph.dart';
import '../../domain/repositories.dart';

/// One node in the global graph browser (architecture §6.2): an entity plus the
/// sessions that mention it, so the user can see how knowledge spans sessions.
class GlobalGraphNode {
  const GlobalGraphNode({
    required this.entity,
    required this.sessionIds,
    required this.sessionTitles,
  });

  final GraphEntity entity;
  final List<String> sessionIds;
  final List<String> sessionTitles;

  int get sessionCount => sessionIds.length;
}

/// Global knowledge-graph browse state (spec §28 Phase 6, architecture §4.8):
/// every entity across all sessions, ranked by how many sessions mention it.
/// Tap-through reaches a session's per-session graph (§6.2 part 1).
final globalGraphControllerProvider =
    AsyncNotifierProvider<GlobalGraphController, List<GlobalGraphNode>>(
        GlobalGraphController.new);

class GlobalGraphController extends AsyncNotifier<List<GlobalGraphNode>> {
  @override
  Future<List<GlobalGraphNode>> build() => _load();

  Future<List<GlobalGraphNode>> _load() async {
    final graph = ref.read(graphRepositoryProvider);
    final entities = await graph.getEntities();
    if (entities.isEmpty) return const [];

    final sessions = await ref.read(databaseProvider).watchSessions().first;
    final titles = {for (final s in sessions) s.id: s.title ?? 'Untitled session'};

    final nodes = <GlobalGraphNode>[];
    for (final entity in entities) {
      final sessionIds = await graph.sessionIdsForEntity(entity.id);
      if (sessionIds.isEmpty) continue;
      nodes.add(GlobalGraphNode(
        entity: entity,
        sessionIds: sessionIds,
        sessionTitles: [
          for (final id in sessionIds)
            if (titles[id] != null) titles[id]!,
        ],
      ));
    }
    nodes.sort((a, b) {
      final byCount = b.sessionCount.compareTo(a.sessionCount);
      return byCount != 0
          ? byCount
          : a.entity.name.toLowerCase().compareTo(b.entity.name.toLowerCase());
    });
    return nodes;
  }
}
