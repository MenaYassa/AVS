import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/entities/enums.dart';
import 'global_graph_controller.dart';

/// Global knowledge-graph browse (architecture §4.8, §6.2 part 1): every
/// entity across all sessions, ranked by how many sessions mention it. Tapping
/// an entity opens the first session's per-session graph (or a picker when it
/// spans several).
class GlobalGraphScreen extends ConsumerStatefulWidget {
  const GlobalGraphScreen({super.key});

  @override
  ConsumerState<GlobalGraphScreen> createState() => _GlobalGraphScreenState();
}

class _GlobalGraphScreenState extends ConsumerState<GlobalGraphScreen> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final nodes = ref.watch(globalGraphControllerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Knowledge map'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () =>
                ref.refresh(globalGraphControllerProvider.notifier).build(),
          ),
        ],
      ),
      body: nodes.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Could not load the graph: $e')),
        data: (all) {
          if (all.isEmpty) {
            return const Center(child: Text('No shared knowledge yet'));
          }
          final visible = _filter.trim().isEmpty
              ? all
              : [
                  for (final n in all)
                    if (n.entity.name.toLowerCase().contains(_filter.trim().toLowerCase()))
                      n,
                ];
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: TextField(
                  decoration: const InputDecoration(
                    hintText: 'Filter entities…',
                    prefixIcon: Icon(Icons.search),
                    isDense: true,
                  ),
                  onChanged: (value) => setState(() => _filter = value),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: visible.length,
                  itemBuilder: (context, i) {
                    final node = visible[i];
                    return ListTile(
                      leading: CircleAvatar(
                        child: Icon(_iconFor(node.entity.type), size: 20),
                      ),
                      title: Text(node.entity.name),
                      subtitle: Text(
                        node.sessionCount == 1
                            ? 'In ${node.sessionTitles.firstOrNull ?? '1 session'}'
                            : 'In ${node.sessionCount} sessions',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: node.sessionCount > 1
                          ? Icon(
                              Icons.chat_bubble_outline,
                              size: 18,
                              color: theme.colorScheme.onSurfaceVariant,
                            )
                          : null,
                      onTap: () => _open(context, node),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _open(BuildContext context, GlobalGraphNode node) async {
    if (node.sessionIds.isEmpty) return;
    if (node.sessionIds.length == 1) {
      context.push('/graph/${node.sessionIds.first}');
      return;
    }
    final theme = Theme.of(context);
    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '${node.entity.name} appears in:',
                style: theme.textTheme.titleSmall,
              ),
            ),
            for (var i = 0; i < node.sessionIds.length; i++)
              ListTile(
                leading: const Icon(Icons.mic_none_outlined),
                title: Text(
                  node.sessionTitles[i],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.of(context).pop(node.sessionIds[i]),
              ),
          ],
        ),
      ),
    );
    if (selected != null) {
      if (context.mounted) context.push('/graph/$selected');
    }
  }

  static IconData _iconFor(EntityType type) => switch (type) {
        EntityType.person => Icons.person_outline,
        EntityType.project => Icons.assignment_outlined,
        EntityType.organization => Icons.business_outlined,
        EntityType.idea => Icons.lightbulb_outline,
        EntityType.task => Icons.check_circle_outline,
        EntityType.decision => Icons.gavel_outlined,
        EntityType.event => Icons.event_outlined,
        EntityType.product => Icons.inventory_2_outlined,
        EntityType.tool => Icons.build_outlined,
        EntityType.place => Icons.place_outlined,
        EntityType.concept => Icons.psychology_outlined,
        EntityType.date => Icons.calendar_today_outlined,
      };
}
