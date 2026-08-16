import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logging/app_logger.dart';
import '../../domain/editing/edit_operations.dart';
import '../../domain/entities/enums.dart';
import '../../domain/entities/graph.dart';
import '../../domain/entities/graph_ids.dart';
import '../../domain/repositories.dart';
import '../editing/editing_controller.dart';

/// UI state for one session's knowledge graph (architecture §4.8).
class GraphState {
  const GraphState({
    this.entities = const [],
    this.relationships = const [],
    this.busy = false,
    this.error,
  });

  final List<GraphEntity> entities;
  final List<GraphRelation> relationships;
  final bool busy;
  final String? error;

  bool get hasError => error != null;

  GraphState copyWith({
    List<GraphEntity>? entities,
    List<GraphRelation>? relationships,
    bool? busy,
    String? error,
    bool clearError = false,
  }) {
    return GraphState(
      entities: entities ?? this.entities,
      relationships: relationships ?? this.relationships,
      busy: busy ?? this.busy,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

final graphControllerProvider =
    NotifierProvider.family<GraphController, GraphState, String>(
  GraphController.new,
);

/// Per-session knowledge graph coordinator. Every mutation goes through the
/// editing op-log (the single mutation path), so graph edits are undoable,
/// versioned, and sync as lossless diffs (§4.6, §4.8, §4.13).
class GraphController extends FamilyNotifier<GraphState, String> {
  @override
  GraphState build(String sessionId) {
    _load();
    return const GraphState();
  }

  GraphEntity? _entityById(String id) =>
      state.entities.where((e) => e.id == id).firstOrNull;

  GraphRelation? _relationById(String id) =>
      state.relationships.where((r) => r.id == id).firstOrNull;

  Future<void> _load() async {
    try {
      final graph = await ref.read(graphRepositoryProvider).getSubgraph(arg);
      state = state.copyWith(
        entities: graph.entities,
        relationships: graph.relationships,
      );
    } catch (e, st) {
      Log.e('Failed to load graph', e, st);
      state = state.copyWith(
        error: 'Could not load the knowledge graph.',
      );
    }
  }

  Future<void> _apply(EditOperation op) async {
    state = state.copyWith(busy: true, clearError: true);
    try {
      await ref.read(editingControllerProvider(arg).notifier).apply(op);
      await _load();
    } catch (e, st) {
      Log.e('Failed to apply graph edit', e, st);
      state = state.copyWith(
        busy: false,
        error: 'Could not save the graph change.',
      );
    }
  }

  /// Adds a node with a deterministic id (same real-world name maps to the
  /// same id across sessions). Deduped case-insensitively.
  Future<void> addEntity({
    required String name,
    required EntityType type,
    String? canonicalName,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final normalized = trimmed.toLowerCase();
    if (state.entities
        .any((e) => e.name.toLowerCase() == normalized)) {
      return;
    }
    await _apply(AddEntity(
      entity: GraphEntity(
        id: graphEntityId(trimmed),
        userId: '',
        type: type,
        name: trimmed,
        canonicalName: canonicalName,
      ),
    ));
  }

  Future<void> renameEntity(String entityId, String newName) async {
    final current = _entityById(entityId);
    if (current == null) return;
    final trimmed = newName.trim();
    if (trimmed.isEmpty || trimmed == current.name) return;
    await _apply(RenameEntity(
      entityId: entityId,
      oldEntity: current,
      newEntity: current.copyWith(name: trimmed),
    ));
  }

  Future<void> mergeEntities(String sourceId, String targetId) async {
    final source = _entityById(sourceId);
    if (source == null || _entityById(targetId) == null) return;
    if (sourceId == targetId) return;
    final incident = state.relationships
        .where((r) => r.sourceId == sourceId || r.targetId == sourceId)
        .toList();
    await _apply(MergeEntities(
      source: source,
      targetId: targetId,
      mergedEdges: incident,
    ));
  }

  Future<void> deleteEntity(String entityId) async {
    final current = _entityById(entityId);
    if (current == null) return;
    final incident = state.relationships
        .where((r) => r.sourceId == entityId || r.targetId == entityId)
        .toList();
    await _apply(DeleteEntity(entity: current, incidentEdges: incident));
  }

  Future<void> addRelationship({
    required String sourceId,
    required String targetId,
    required RelationType type,
  }) async {
    if (sourceId == targetId) return;
    if (_entityById(sourceId) == null || _entityById(targetId) == null) return;
    final relation = GraphRelation(
      id: graphRelationshipId(
        sessionId: arg,
        sourceId: sourceId,
        targetId: targetId,
        type: type.wireName,
      ),
      userId: '',
      sourceId: sourceId,
      targetId: targetId,
      type: type,
      sessionId: arg,
    );
    await _apply(AddRelationship(relationship: relation));
  }

  Future<void> relabelRelationship(
    String relationshipId,
    RelationType type,
  ) async {
    final current = _relationById(relationshipId);
    if (current == null || current.type == type) return;
    await _apply(RelabelRelationship(
      relationshipId: relationshipId,
      oldRelationship: current,
      newRelationship: current.copyWith(type: type, clearConfidence: true),
    ));
  }

  Future<void> deleteRelationship(String relationshipId) async {
    final current = _relationById(relationshipId);
    if (current == null) return;
    await _apply(DeleteRelationship(relationship: current));
  }
}
