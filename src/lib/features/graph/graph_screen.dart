import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/enums.dart';
import '../../domain/entities/graph.dart';
import '../editing/editing_widgets.dart';
import 'graph_controller.dart';

/// Knowledge graph browser + editor (architecture §4.8, P4-D).
///
/// Renders the session's per-session subgraph: a canvas view of the nodes and
/// their edges plus a relationship list. Every change flows through
/// [GraphController] → the editing op-log (undoable, versioned, synced).
class GraphScreen extends ConsumerWidget {
  const GraphScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final graph = ref.watch(graphControllerProvider(sessionId));
    final ctrl = ref.read(graphControllerProvider(sessionId).notifier);

    ref.listen(graphControllerProvider(sessionId), (prev, next) {
      if (next.hasError && !(prev?.hasError ?? false)) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(next.error!)));
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Knowledge graph'),
        actions: [
          IconButton(
            tooltip: 'Add entity',
            icon: const Icon(Icons.add_box_outlined),
            onPressed: () => _addEntity(context, ctrl),
          ),
          IconButton(
            tooltip: 'Add relationship',
            icon: const Icon(Icons.hub_outlined),
            onPressed: graph.entities.length < 2
                ? null
                : () => _addRelationship(context, ctrl, graph),
          ),
        ],
      ),
      body: graph.busy && graph.entities.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  flex: 3,
                  child: graph.entities.isEmpty
                      ? _EmptyGraph(onAdd: () => _addEntity(context, ctrl))
                      : _GraphCanvas(
                          entities: graph.entities,
                          relationships: graph.relationships,
                          onNodeTap: (id) => _showNodeSheet(context, ctrl, graph, id),
                        ),
                ),
                const Divider(height: 1),
                Expanded(
                  flex: 2,
                  child: _RelationshipsPanel(
                    graph: graph,
                    onTap: (id) => _showRelationSheet(context, ctrl, graph, id),
                  ),
                ),
              ],
            ),
    );
  }

  Future<void> _addEntity(BuildContext context, GraphController ctrl) async {
    final name = await showTextEditor(
      context,
      title: 'Add entity',
      label: 'Name',
      initial: '',
    );
    if (name == null || name.isEmpty) return;
    if (!context.mounted) return;
    final type = await _pickEntityType(context, EntityType.idea);
    if (type == null) return;
    await ctrl.addEntity(name: name, type: type);
  }

  Future<void> _showNodeSheet(
    BuildContext context,
    GraphController ctrl,
    GraphState graph,
    String entityId,
  ) async {
    final entity = graph.entities.where((e) => e.id == entityId).firstOrNull;
    if (entity == null) return;
    final others =
        graph.entities.where((e) => e.id != entityId).toList(growable: false);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              title: Text(entity.name, style: Theme.of(context).textTheme.titleMedium),
              subtitle: Text(
                entity.type.wireName +
                    (entity.confidence != null
                        ? ' · AI confidence ${(entity.confidence! * 100).round()}%'
                        : ' · edited by you'),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('Rename'),
              onTap: () async {
                Navigator.of(context).pop();
                final value = await showTextEditor(
                  context,
                  title: 'Rename entity',
                  label: 'Name',
                  initial: entity.name,
                );
                if (value != null && value != entity.name) {
                  await ctrl.renameEntity(entity.id, value);
                }
              },
            ),
            if (others.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.merge_type),
                title: const Text('Merge into…'),
                onTap: () async {
                  Navigator.of(context).pop();
                  final target = await _pickEntity(context, graph, others);
                  if (target != null) {
                    await ctrl.mergeEntities(entity.id, target);
                  }
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete'),
              onTap: () async {
                Navigator.of(context).pop();
                await ctrl.deleteEntity(entity.id);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addRelationship(
    BuildContext context,
    GraphController ctrl,
    GraphState graph,
  ) async {
    final source = await _pickEntity(
      context,
      graph,
      graph.entities,
      title: 'From entity',
    );
    if (source == null) return;
    if (!context.mounted) return;
    final target = await _pickEntity(
      context,
      graph,
      graph.entities.where((e) => e.id != source).toList(),
      title: 'To entity',
    );
    if (target == null) return;
    if (!context.mounted) return;
    final type = await _pickRelationType(context, RelationType.relatedTo);
    if (type == null) return;
    await ctrl.addRelationship(sourceId: source, targetId: target, type: type);
  }

  Future<void> _showRelationSheet(
    BuildContext context,
    GraphController ctrl,
    GraphState graph,
    String relationshipId,
  ) async {
    final relation =
        graph.relationships.where((r) => r.id == relationshipId).firstOrNull;
    if (relation == null) return;
    String nameOf(String id) =>
        graph.entities.where((e) => e.id == id).firstOrNull?.name ?? id;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              title: Text(
                '${nameOf(relation.sourceId)} —${relation.type.wireName}— ${nameOf(relation.targetId)}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.label_outline),
              title: const Text('Change type'),
              onTap: () async {
                Navigator.of(context).pop();
                final type = await _pickRelationType(context, relation.type);
                if (type != null && type != relation.type) {
                  await ctrl.relabelRelationship(relation.id, type);
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete'),
              onTap: () async {
                Navigator.of(context).pop();
                await ctrl.deleteRelationship(relation.id);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<EntityType?> _pickEntityType(
    BuildContext context,
    EntityType initial,
  ) async {
    var selected = initial;
    final result = await showDialog<EntityType>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Entity type'),
        content: DropdownButtonFormField<EntityType>(
          initialValue: selected,
          items: [
            for (final t in EntityType.values)
              DropdownMenuItem(value: t, child: Text(t.wireName)),
          ],
          onChanged: (v) => selected = v ?? selected,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(selected),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return result;
  }

  Future<RelationType?> _pickRelationType(
    BuildContext context,
    RelationType initial,
  ) async {
    var selected = initial;
    final result = await showDialog<RelationType>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Relationship type'),
        content: DropdownButtonFormField<RelationType>(
          initialValue: selected,
          items: [
            for (final t in RelationType.values)
              DropdownMenuItem(value: t, child: Text(t.wireName)),
          ],
          onChanged: (v) => selected = v ?? selected,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(selected),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return result;
  }

  Future<String?> _pickEntity(
    BuildContext context,
    GraphState graph,
    List<GraphEntity> candidates, {
    String title = 'Pick entity',
  }) async {
    if (candidates.length == 1) return candidates.single.id;
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(title, style: Theme.of(context).textTheme.titleMedium),
            ),
            for (final e in candidates)
              ListTile(
                title: Text(e.name),
                onTap: () => Navigator.of(context).pop(e.id),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyGraph extends StatelessWidget {
  const _EmptyGraph({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.account_tree_outlined, size: 56, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text('No entities yet.', style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: const Text('Add entity'),
          ),
        ],
      ),
    );
  }
}

class _GraphCanvas extends StatelessWidget {
  const _GraphCanvas({
    required this.entities,
    required this.relationships,
    required this.onNodeTap,
  });

  final List<GraphEntity> entities;
  final List<GraphRelation> relationships;
  final ValueChanged<String> onNodeTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final positions = _layout(entities, size);
        final nodeSize = 44.0;
        final center = Offset(size.width / 2, size.height / 2);
        final theme = Theme.of(context);
        return Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _EdgePainter(
                  relationships: relationships,
                  positions: positions,
                  nodeSize: nodeSize,
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
            for (final e in entities)
              Positioned(
                left: positions[e.id]!.dx - nodeSize / 2,
                top: positions[e.id]!.dy - nodeSize / 2,
                child: GestureDetector(
                  onTap: () => onNodeTap(e.id),
                  child: Tooltip(
                    message: e.name,
                    child: Container(
                      width: nodeSize,
                      height: nodeSize,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _colorFor(e.type),
                        border: Border.all(
                          color: theme.colorScheme.onSurface,
                          width: 1,
                        ),
                      ),
                      child: Text(
                        _initial(e.name),
                        style: theme.textTheme.titleMedium!.copyWith(
                          color: theme.colorScheme.onPrimary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (positions.length == 1)
              Positioned(
                left: center.dx - 80,
                top: center.dy - nodeSize - 40,
                child: Text(
                  entities.single.name,
                  style: theme.textTheme.bodyMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        );
      },
    );
  }

  /// Deterministic radial layout: the most-connected node is the hub at the
  /// center, the rest orbit around it in name order.
  Map<String, Offset> _layout(List<GraphEntity> nodes, Size size) {
    final byId = {for (final e in nodes) e.id: e};
    final degree = <String, int>{};
    for (final e in nodes) {
      degree[e.id] = 0;
    }
    for (final r in relationships) {
      if (byId.containsKey(r.sourceId) && byId.containsKey(r.targetId)) {
        degree[r.sourceId] = (degree[r.sourceId] ?? 0) + 1;
        degree[r.targetId] = (degree[r.targetId] ?? 0) + 1;
      }
    }
    final sorted = [...nodes]..sort((a, b) {
        final byDegree = (degree[b.id] ?? 0).compareTo(degree[a.id] ?? 0);
        return byDegree != 0 ? byDegree : a.name.compareTo(b.name);
      });
    final center = Offset(size.width / 2, size.height / 2);
    if (sorted.length == 1) {
      return {sorted.single.id: center};
    }
    final radius = math.min(size.width, size.height) * 0.34;
    final positions = <String, Offset>{};
    positions[sorted.first.id] = center;
    for (var i = 1; i < sorted.length; i++) {
      final angle = (i - 1) / (sorted.length - 1) * 2 * math.pi - math.pi / 2;
      positions[sorted[i].id] = Offset(
        center.dx + radius * math.cos(angle),
        center.dy + radius * math.sin(angle),
      );
    }
    return positions;
  }

  String _initial(String name) =>
      name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();

  Color _colorFor(EntityType type) {
    switch (type) {
      case EntityType.person:
        return const Color(0xFF5C6BC0);
      case EntityType.project:
      case EntityType.organization:
        return const Color(0xFF26A69A);
      case EntityType.idea:
      case EntityType.concept:
        return const Color(0xFFAB47BC);
      case EntityType.task:
      case EntityType.decision:
        return const Color(0xFFEF5350);
      case EntityType.event:
      case EntityType.date:
        return const Color(0xFFFFA726);
      case EntityType.product:
      case EntityType.tool:
        return const Color(0xFF42A5F5);
      case EntityType.place:
        return const Color(0xFF8D6E63);
    }
  }
}

class _EdgePainter extends CustomPainter {
  _EdgePainter({
    required this.relationships,
    required this.positions,
    required this.nodeSize,
    required this.color,
  });

  final List<GraphRelation> relationships;
  final Map<String, Offset> positions;
  final double nodeSize;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final half = nodeSize / 2;
    for (final r in relationships) {
      final from = positions[r.sourceId];
      final to = positions[r.targetId];
      if (from == null || to == null) continue;
      final direction = to - from;
      if (direction.distance < 1) continue;
      final unit = direction / direction.distance;
      final start = from + unit * (half + 2);
      final end = to - unit * (half + 2);
      canvas.drawLine(start, end, paint);
      _drawArrowHead(canvas, end, unit, color);
    }
  }

  void _drawArrowHead(Canvas canvas, Offset tip, Offset unit, Color color) {
    final arrowPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final side = Offset(-unit.dy, unit.dx);
    const headSize = 8.0;
    final back = tip - unit * headSize;
    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(back.dx + side.dx * headSize / 2, back.dy + side.dy * headSize / 2)
      ..lineTo(back.dx - side.dx * headSize / 2, back.dy - side.dy * headSize / 2)
      ..close();
    canvas.drawPath(path, arrowPaint);
  }

  @override
  bool shouldRepaint(_EdgePainter oldDelegate) =>
      oldDelegate.relationships != relationships ||
      oldDelegate.positions != positions ||
      oldDelegate.color != color ||
      oldDelegate.nodeSize != nodeSize;
}

class _RelationshipsPanel extends StatelessWidget {
  const _RelationshipsPanel({required this.graph, required this.onTap});

  final GraphState graph;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (graph.relationships.isEmpty) {
      return Center(
        child: Text(
          'No relationships yet.',
          style: theme.textTheme.bodyMedium!.copyWith(color: theme.colorScheme.outline),
        ),
      );
    }
    String nameOf(String id) =>
        graph.entities.where((e) => e.id == id).firstOrNull?.name ?? id;
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: graph.relationships.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final r = graph.relationships[index];
        return ListTile(
          dense: true,
          leading: const Icon(Icons.hub_outlined),
          title: Text(
            '${nameOf(r.sourceId)} → ${nameOf(r.targetId)}',
            style: theme.textTheme.bodySmall,
          ),
          subtitle: Text(
            '${r.type.wireName}'
            '${r.confidence != null ? ' · ${(r.confidence! * 100).round()}%' : ''}',
            style: theme.textTheme.labelSmall,
          ),
          onTap: () => onTap(r.id),
        );
      },
    );
  }
}
