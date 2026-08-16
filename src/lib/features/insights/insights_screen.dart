import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/entities/insight.dart';
import '../settings/intelligence_controller.dart';
import 'insights_controller.dart';

/// Cross-session intelligence screen (architecture §4.9, spec §19).
///
/// Lists deterministic insight statements ("You've discussed X in N
/// sessions") computed by the engine from this device's session descriptors.
/// Every insight displays its provenance: tapping a source chip opens the
/// session it was derived from. Opt-in only — nothing is computed or shipped
/// until the user enables cross-session insights.
class InsightsScreen extends ConsumerStatefulWidget {
  const InsightsScreen({super.key});

  @override
  ConsumerState<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends ConsumerState<InsightsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final settings = await ref.read(intelligenceSettingsProvider.future);
        if (!settings.enableInsights) return;
        final state = ref.read(insightsControllerProvider);
        if (!state.isRunning && state.result == null) {
          ref.read(insightsControllerProvider.notifier).refresh();
        }
      } catch (_) {
        // Settings unavailable: default off, user can enable from the gate.
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(intelligenceSettingsProvider);
    final enabled = settings.valueOrNull?.enableInsights ?? false;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Insights'),
        actions: [
          if (enabled)
            IconButton(
              tooltip: 'Regenerate',
              icon: const Icon(Icons.refresh),
              onPressed: () =>
                  ref.read(insightsControllerProvider.notifier).refresh(),
            ),
        ],
      ),
      body: enabled
          ? const _InsightsBody()
          : _OptInGate(
              onChanged: (value) => ref
                  .read(intelligenceSettingsProvider.notifier)
                  .setEnableInsights(value),
            ),
    );
  }
}

class _InsightsBody extends ConsumerWidget {
  const _InsightsBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(insightsControllerProvider);
    final theme = Theme.of(context);

    if (state.isRunning) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Looking across your sessions…'),
          ],
        ),
      );
    }
    if (state.phase == InsightsPhase.failed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                state.error ?? 'Insights failed.',
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.error),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () =>
                    ref.read(insightsControllerProvider.notifier).refresh(),
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }
    final result = state.result;
    if (result == null || result.insights.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'No insights yet.\n\n'
                'Generate statements like "You\'ve discussed X in N sessions" '
                'from the topics and entities shared across your sessions.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () =>
                    ref.read(insightsControllerProvider.notifier).refresh(),
                icon: const Icon(Icons.auto_awesome),
                label: const Text('Generate insights'),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: result.insights.length,
      itemBuilder: (context, i) => _InsightCard(insight: result.insights[i]),
    );
  }
}

class _InsightCard extends StatelessWidget {
  const _InsightCard({required this.insight});

  final Insight insight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = insight.sessionCount;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  switch (insight.kind) {
                    InsightKind.tag => Icons.tag,
                    InsightKind.person => Icons.person_outline,
                    InsightKind.project => Icons.assignment_outlined,
                    InsightKind.task => Icons.check_circle_outline,
                    InsightKind.decision => Icons.gavel_outlined,
                    InsightKind.entity => Icons.hub_outlined,
                  },
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    insight.statement,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Chip(
                  label: Text('$count session${count == 1 ? '' : 's'}'),
                  visualDensity: VisualDensity.compact,
                ),
                Chip(
                  label: Text(
                    '${(insight.confidence * 100).round()}% confidence',
                  ),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('Sources', style: theme.textTheme.labelMedium),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final source in insight.sources)
                  ActionChip(
                    label: Text(source.title, overflow: TextOverflow.ellipsis),
                    visualDensity: VisualDensity.compact,
                    onPressed: () =>
                        context.go('/sessions/${source.sessionId}'),
                  ),
              ],
            ),
            if (insight.sources.any((s) => s.snippet != null)) ...[
              const SizedBox(height: 8),
              for (final source in insight.sources)
                if (source.snippet != null && source.snippet!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '“${source.snippet}”',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Opt-in gate: nothing is computed or shipped until the user enables
/// cross-session intelligence (architecture §4.9, §12).
class _OptInGate extends StatelessWidget {
  const _OptInGate({required this.onChanged});

  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.auto_awesome, color: theme.colorScheme.primary),
                    const SizedBox(height: 12),
                    Text(
                      'Cross-session insights',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Enable to spot topics and entities that recur across your '
                      'sessions, e.g. "You\'ve discussed Benchmark Platform in 3 '
                      'sessions" — each statement links back to the source '
                      'sessions it was derived from.\n\n'
                      'Insights run on this device\'s data only and are opt-in. '
                      'Turn them off any time; nothing is shared unless you '
                      'generate insights.',
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Enable insights'),
                      value: true,
                      onChanged: onChanged,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
