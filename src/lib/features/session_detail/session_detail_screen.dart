import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../domain/editing/edit_operations.dart';
import '../../domain/entities/enums.dart';
import '../../domain/entities/session.dart';
import '../../domain/entities/tag.dart';
import '../../domain/repositories.dart';
import '../analysis/analysis_controller.dart';
import '../chat/chat_sheet.dart';
import '../commands/command_bus_controller.dart';
import '../commands/command_catalog.dart';
import '../commands/draft_screen.dart';
import '../editing/editing_controller.dart';
import '../editing/editing_widgets.dart';
import '../graph/graph_screen.dart';
import '../organization/organization_controller.dart';
import '../playback/playback_controller.dart';
import '../settings/intelligence_controller.dart';
import '../settings/memory_controller.dart';
import '../export/export_bottom_sheet.dart';
import '../sync/sync_controller.dart';
import '../tags/tags_controller.dart';
import '../versioning/version_controller.dart';
import '../versioning/version_history_screen.dart';
import 'related_sessions_controller.dart';

final sessionProvider =
    FutureProvider.family<Session?, String>((ref, id) async {
  // Re-read after sync passes, analysis state changes, every committed edit
  // (the editing controller bumps a revision per persisted mutation), and
  // every version commit/restore.
  ref.watch(syncControllerProvider);
  ref.watch(analysisControllerProvider(id));
  ref.watch(editingControllerProvider(id));
  ref.watch(versioningControllerProvider(id));
  return ref.watch(databaseProvider).getSession(id);
});

/// Session detail: title, summary, analysis progress, topics, items, and the
/// editing affordances for ready sessions (spec §14, architecture §3.4).
class SessionDetailScreen extends ConsumerWidget {
  const SessionDetailScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider(sessionId));
    final analysis = ref.watch(analysisControllerProvider(sessionId));
    ref.watch(versioningControllerProvider(sessionId));

    ref.listen(editingControllerProvider(sessionId), (prev, next) {
      if (next.hasError && !(prev?.hasError ?? false)) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(next.error!)));
      }
      // Each committed edit batch becomes its own version (§4.6).
      if (next.appliedCount != (prev?.appliedCount ?? 0)) {
        ref.read(versioningControllerProvider(sessionId).notifier)
            .commitEditBatch();
      }
    });

    ref.listen(commandBusControllerProvider(sessionId), (prev, next) {
      if (prev == null || prev.lastDraftId != next.lastDraftId) {
        if (next.lastDraftId != null) {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => DraftScreen(
                args: DraftScreenArgs(
                  sessionId: sessionId,
                  draftId: next.lastDraftId!,
                ),
              ),
            ),
          );
        }
      }
    });

    final canOpenHistory =
        session.valueOrNull?.status == SessionStatus.ready;
    final org = ref.read(organizationControllerProvider);
    final current = session.valueOrNull;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Session'),
        actions: [
          if (current != null && !current.deleted) ...[
            IconButton(
              tooltip:
                  current.favorite ? 'Remove from favorites' : 'Add to favorites',
              icon: Icon(
                current.favorite ? Icons.star : Icons.star_border,
                color: current.favorite
                    ? Theme.of(context).colorScheme.tertiary
                    : null,
              ),
              onPressed: () => org.toggleFavorite(current),
            ),
            IconButton(
              tooltip: current.archived ? 'Unarchive' : 'Archive',
              icon: Icon(
                current.archived
                    ? Icons.unarchive_outlined
                    : Icons.archive_outlined,
              ),
              onPressed: () => org.toggleArchive(current),
            ),
            IconButton(
              tooltip: current.pinned ? 'Unpin' : 'Pin',
              icon: Icon(
                current.pinned ? Icons.push_pin : Icons.push_pin_outlined,
              ),
              onPressed: () => org.togglePin(current),
            ),
            PopupMenuButton<String>(
              tooltip: 'More',
              onSelected: (value) {
                if (value == 'trash') {
                  org.trash(current);
                  context.go('/');
                } else if (value == 'memory') {
                  ref
                      .read(memorySkipProvider(current.id).notifier)
                      .toggle();
                } else if (value == 'export') {
                  showModalBottomSheet<void>(
                    context: context,
                    builder: (_) => ExportBottomSheet(session: current),
                  );
                }
              },
              itemBuilder: (_) => [
                if (ref
                        .watch(intelligenceSettingsProvider)
                        .valueOrNull
                        ?.enableMemory ??
                    false)
                  CheckedPopupMenuItem(
                    value: 'memory',
                    checked:
                        ref.watch(memorySkipProvider(current.id)).valueOrNull ??
                            false,
                    child: const Text('Use AI memory for this session'),
                  ),
                const PopupMenuItem(
                  value: 'export',
                  child: Text('Export'),
                ),
                const PopupMenuItem(value: 'trash', child: Text('Move to trash')),
              ],
            ),
          ] else if (current?.deleted ?? false)
            IconButton(
              tooltip: 'Restore from trash',
              icon: const Icon(Icons.restore),
              onPressed: () {
                org.restore(current!);
                context.go('/');
              },
            ),
          if (canOpenHistory)
            IconButton(
              icon: const Icon(Icons.history),
              tooltip: 'Version history',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => VersionHistoryScreen(sessionId: sessionId),
                ),
              ),
            ),
          if (canOpenHistory)
            IconButton(
              icon: const Icon(Icons.account_tree_outlined),
              tooltip: 'Knowledge graph',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => GraphScreen(sessionId: sessionId),
                ),
              ),
            ),
          if (canOpenHistory)
            IconButton(
              icon: const Icon(Icons.chat_bubble_outline),
              tooltip: 'Ask about this session',
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                useSafeArea: true,
                builder: (_) => ChatSheet(sessionId: sessionId),
              ),
            ),
          if (canOpenHistory)
            IconButton(
              icon: const Icon(Icons.auto_awesome_outlined),
              tooltip: 'AI tools',
              onPressed: () => _showCommandPalette(context, ref),
            ),
        ],
      ),
      body: session.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Could not load session: $e')),
        data: (s) => s == null
            ? const Center(child: Text('Session not found'))
            : _SessionView(
                sessionId: sessionId,
                session: s,
                analysis: analysis,
                onAnalyze: () =>
                    ref.read(analysisControllerProvider(sessionId).notifier)
                        .analyze(),
                onRetry: () =>
                    ref.read(analysisControllerProvider(sessionId).notifier)
                        .analyze(),
                onCancel: () =>
                    ref.read(analysisControllerProvider(sessionId).notifier)
                        .cancel(),
              ),
      ),
    );
  }

  void _showCommandPalette(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _CommandPalette(sessionId: sessionId),
    );
  }
}

class _CommandPalette extends ConsumerStatefulWidget {
  const _CommandPalette({required this.sessionId});
  final String sessionId;

  @override
  ConsumerState<_CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends ConsumerState<_CommandPalette> {
  @override
  Widget build(BuildContext context) {
    final bus = ref.watch(commandBusControllerProvider(widget.sessionId));

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Text('AI tools', style: Theme.of(context).textTheme.titleLarge),
                const Spacer(),
                if (bus.isProcessing)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                for (final entry in commandsByCategory.entries) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      _categoryLabel(entry.key),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ),
                  ...entry.value.map((cmd) => ListTile(
                        leading: Icon(cmd.icon),
                        title: Text(cmd.label),
                        subtitle: Text(cmd.description),
                        enabled: !bus.isProcessing,
                        onTap: bus.isProcessing
                            ? null
                            : () async {
                                Navigator.pop(context);
                                await ref
                                    .read(
                                      commandBusControllerProvider(
                                        widget.sessionId,
                                      ).notifier,
                                    )
                                    .runCommand(cmd.name);
                                // When the command succeeds, the controller
                                // sets lastDraftId; we'll push the draft screen
                                // via a listener on the controller.
                              },
                      )),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _categoryLabel(CommandCategory c) {
    return switch (c) {
      CommandCategory.summary => 'Summarize',
      CommandCategory.rewrite => 'Rewrite',
      CommandCategory.extract => 'Extract',
      CommandCategory.document => 'Documents',
      CommandCategory.plan => 'Plan',
    };
  }
}

class _SessionView extends ConsumerWidget {
  const _SessionView({
    required this.sessionId,
    required this.session,
    required this.analysis,
    required this.onAnalyze,
    required this.onRetry,
    required this.onCancel,
  });

  final String sessionId;
  final Session session;
  final AnalysisState analysis;
  final VoidCallback onAnalyze;
  final VoidCallback onRetry;
  final VoidCallback onCancel;

  bool get _canAnalyze =>
      session.audioPath != null &&
      session.topics.isEmpty &&
      session.promptVersions.isEmpty;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final editing = ref.watch(editingControllerProvider(sessionId));
    final canEdit = session.status == SessionStatus.ready;
    final ctrl = ref.read(editingControllerProvider(sessionId).notifier);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                session.title ?? 'Untitled',
                style: theme.textTheme.headlineSmall,
              ),
            ),
            if (canEdit)
              IconButton(
                icon: const Icon(Icons.edit_outlined),
                tooltip: 'Edit title',
                onPressed: () async {
                  final value = await showTextEditor(
                    context,
                    title: 'Edit title',
                    label: 'Title',
                    initial: session.title ?? '',
                  );
                  if (value == null || value == (session.title ?? '')) return;
                  await ctrl.apply(UpdateSessionTitle(
                    oldTitle: session.title,
                    newTitle: value,
                  ));
                },
              ),
          ],
        ),
        if (session.alternativeTitles.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final alt in session.alternativeTitles)
                Chip(
                  label: Text(alt, style: theme.textTheme.labelSmall),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        _MetadataRow(session: session),
        if (session.audioPath != null || session.audioRemoteUrl != null) ...[
          const SizedBox(height: 12),
          _AudioCard(
            sessionId: sessionId,
            audioPath: session.audioPath,
            audioRemoteUrl: session.audioRemoteUrl,
          ),
        ],
        const SizedBox(height: 12),
        _SessionTagsSection(sessionId: sessionId),
        if (session.summary != null) ...[
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(session.summary!, style: theme.textTheme.bodyMedium)),
              if (canEdit)
                IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: 'Edit summary',
                  visualDensity: VisualDensity.compact,
                  onPressed: () async {
                    final value = await showTextEditor(
                      context,
                      title: 'Edit summary',
                      label: 'Summary',
                      initial: session.summary ?? '',
                    );
                    if (value == null || value == session.summary) return;
                    await ctrl.apply(UpdateSessionSummary(
                      oldSummary: session.summary,
                      newSummary: value,
                    ));
                  },
                ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        Text('Status: ${session.status.name}', style: theme.textTheme.bodySmall),
        const SizedBox(height: 12),
        if (analysis.isProcessing)
          _ProgressCard(
            label: analysis.stageLabel ?? _statusLabel(analysis.status),
            onCancel: onCancel,
          )
        else if (analysis.phase == AnalysisPhase.failed)
          _FailureCard(error: analysis.error, onRetry: onRetry)
        else if (_canAnalyze)
          _AnalyzeCard(onAnalyze: onAnalyze),
        if (canEdit) ...[
          const SizedBox(height: 8),
          _EditToolbar(
            canUndo: editing.canUndo,
            canRedo: editing.canRedo,
            busy: editing.busy,
            onUndo: ctrl.undo,
            onRedo: ctrl.redo,
            onAddTopic: () async {
              final title = await showTextEditor(
                context,
                title: 'New topic',
                label: 'Topic title',
                initial: '',
              );
              if (title == null || title.isEmpty) return;
              await ctrl.apply(AddTopic(
                topic: Topic(
                  id: const Uuid().v4(),
                  title: title,
                  position: session.topics.length,
                ),
                position: session.topics.length,
              ));
            },
          ),
          const SizedBox(height: 8),
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: session.topics.length,
            onReorderItem: (oldIndex, newIndex) {
              if (newIndex == oldIndex) return;
              ctrl.apply(ReorderTopic(
                topicId: session.topics[oldIndex].id,
                from: oldIndex,
                to: newIndex,
              ));
            },
            itemBuilder: (context, index) => Padding(
              key: ValueKey('topic-${session.topics[index].id}'),
              padding: const EdgeInsets.only(bottom: 8),
              child: _TopicCard(
                sessionId: sessionId,
                topic: session.topics[index],
                allTopics: session.topics,
                index: index,
                canEdit: true,
              ),
            ),
          ),
        ] else if (session.topics.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: session.topics.map((t) => _TopicCard(
                  sessionId: sessionId,
                  topic: t,
                  allTopics: session.topics,
                  index: 0,
                  canEdit: false,
                  initiallyExpanded: true,
                )).toList(),
          ),
        ],
        if (session.originalTranscript != null ||
            session.cleanedTranscript != null) ...[
          const SizedBox(height: 16),
          _TranscriptCard(
            sessionId: sessionId,
            original: session.originalTranscript,
            cleaned: session.cleanedTranscript,
            canEdit: canEdit,
          ),
        ],
        const SizedBox(height: 16),
        _RelatedSessionsCard(sessionId: sessionId),
      ],
    );
  }

  String _statusLabel(SessionStatus? status) {
    if (status == null) return 'Starting analysis…';
    return switch (status) {
      SessionStatus.uploading => 'Uploading',
      SessionStatus.transcribing => 'Transcribing',
      SessionStatus.cleaning => 'Cleaning up',
      SessionStatus.analyzing => 'Analyzing',
      SessionStatus.validating => 'Validating',
      _ => status.name,
    };
  }
}

/// Session detail extras (spec §14, roadmap §4.2): created date, duration,
/// word count, language.
class _MetadataRow extends StatelessWidget {
  const _MetadataRow({required this.session});

  final Session session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parts = <String>[
      if (session.createdAt != null) _date(session.createdAt!),
      if (session.durationSec != null) _duration(session.durationSec!),
      if (session.wordCount != null) '${session.wordCount} words',
      if (session.language != null) session.language!,
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      children: [
        for (final part in parts)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _iconFor(part),
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(part, style: theme.textTheme.bodySmall),
            ],
          ),
      ],
    );
  }

  IconData _iconFor(String part) {
    if (part.contains('words')) return Icons.text_fields_outlined;
    if (part.contains(':')) return Icons.timer_outlined;
    return Icons.calendar_today_outlined;
  }

  String _date(DateTime d) {
    final local = d.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  }

  String _duration(double sec) {
    final minutes = sec ~/ 60;
    final seconds = (sec % 60).round();
    return '${minutes}m ${seconds}s';
  }
}

/// Playback for a session's recording (spec §16, roadmap §4.3): play/pause,
/// seek slider, playback speed, and delete-recording. Local `audioPath` wins
/// over the cloud `audioRemoteUrl`. Backed by the app-scoped playback
/// controller so audio keeps playing across screens.
class _AudioCard extends ConsumerStatefulWidget {
  const _AudioCard({
    required this.sessionId,
    required this.audioPath,
    required this.audioRemoteUrl,
  });

  final String sessionId;
  final String? audioPath;
  final String? audioRemoteUrl;

  @override
  ConsumerState<_AudioCard> createState() => _AudioCardState();
}

class _AudioCardState extends ConsumerState<_AudioCard> {
  String? get _source => widget.audioPath ?? widget.audioRemoteUrl;

  String _fmt(Duration? d) {
    if (d == null) return '0:00';
    final m = d.inMinutes.toString();
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete recording?'),
        content: const Text(
          'The raw audio will be removed. Transcripts and notes stay.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final path = widget.audioPath;
    if (path != null) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {
        // File may already be gone; still clear the reference.
      }
    }
    await ref
        .read(playbackControllerProvider.notifier)
        .stopForSession(widget.sessionId);
    final session = await ref.read(databaseProvider).getSession(widget.sessionId);
    if (session != null) {
      await ref.read(databaseProvider).updateSession(session.copyWith(
            clearAudioPath: true,
            updatedAt: DateTime.now().toUtc(),
          ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final playback = ref.watch(playbackControllerProvider);
    final source = _source;
    if (source == null) return const SizedBox.shrink();

    final current = playback.isCurrent(widget.sessionId, source);
    final playing = current && playback.playing;
    final duration = current ? playback.duration : null;
    final position = current ? playback.position : null;
    final maxMs = (duration?.inMilliseconds ?? 1).clamp(1, 1 << 62);
    final valueMs = (position?.inMilliseconds ?? 0).clamp(0, maxMs);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: playing ? 'Pause' : 'Play',
                  iconSize: 40,
                  icon: Icon(
                    playing ? Icons.pause_circle : Icons.play_circle,
                    color: theme.colorScheme.primary,
                  ),
                  onPressed: current && playback.loading
                      ? null
                      : () => ref
                          .read(playbackControllerProvider.notifier)
                          .toggle(widget.sessionId, source),
                ),
                const SizedBox(width: 4),
                Text(
                  '${_fmt(position)} / ${_fmt(duration)}',
                  style: theme.textTheme.bodySmall,
                ),
                const Spacer(),
                _SpeedMenu(
                  speed: current ? playback.speed : 1.0,
                  onChanged: (s) => ref
                      .read(playbackControllerProvider.notifier)
                      .setSpeed(s),
                ),
                IconButton(
                  tooltip: 'Delete recording',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _delete,
                ),
              ],
            ),
            Slider(
              value: valueMs.toDouble(),
              max: maxMs.toDouble(),
              onChanged: current
                  ? (v) => ref
                      .read(playbackControllerProvider.notifier)
                      .seek(Duration(milliseconds: v.round()))
                  : null,
            ),
            if (current && playback.error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  playback.error!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SpeedMenu extends StatelessWidget {
  const _SpeedMenu({required this.speed, required this.onChanged});

  static const _options = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  final double speed;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopupMenuButton<double>(
      tooltip: 'Playback speed',
      initialValue: speed,
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final option in _options)
          PopupMenuItem(value: option, child: Text('${option}x')),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.speed, size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 4),
            Text('${speed}x', style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}

/// Session tags: auto (AI) + manual, color-coded (spec §19, roadmap §4.2).
class _SessionTagsSection extends ConsumerWidget {
  const _SessionTagsSection({required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tags = ref.watch(sessionTagsProvider(sessionId));
    final tagsAsync = tags.valueOrNull ?? const <Tag>[];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Flexible(
          child: tagsAsync.isEmpty
              ? Text('No tags', style: theme.textTheme.bodySmall)
              : Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final tag in tagsAsync) _TagChip(sessionId: sessionId, tag: tag),
                  ],
                ),
        ),
        IconButton(
          tooltip: 'Add tag',
          icon: const Icon(Icons.sell_outlined),
          onPressed: () => _addTag(context, ref),
        ),
      ],
    );
  }

  Future<void> _addTag(BuildContext context, WidgetRef ref) async {
    final name = await showTextEditor(
      context,
      title: 'New tag',
      label: 'Tag name',
      initial: '',
    );
    if (name == null || name.trim().isEmpty) return;
    final ctrl = ref.read(tagsControllerProvider);
    final tag = await ctrl.ensureTag(name);
    await ctrl.attach(sessionId, tag.id);
  }
}

class _TagChip extends ConsumerWidget {
  const _TagChip({required this.sessionId, required this.tag});

  final String sessionId;
  final Tag tag;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final background = _tagColor(tag.color, theme);
    return Chip(
      label: Text(tag.name, style: theme.textTheme.labelSmall),
      backgroundColor: background,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      onDeleted: () =>
          ref.read(tagsControllerProvider).detach(sessionId, tag.id),
    );
  }

  Color _tagColor(String? color, ThemeData theme) {
    if (color == null) return theme.colorScheme.surfaceContainerHighest;
    return Color(int.tryParse(color.replaceFirst('#', ''), radix: 16) != null
                ? 0xFF000000 | int.parse(color.replaceFirst('#', ''), radix: 16)
                : 0)
        .withValues(alpha: 0.18);
  }
}

class _EditToolbar extends StatelessWidget {
  const _EditToolbar({
    required this.canUndo,
    required this.canRedo,
    required this.busy,
    required this.onUndo,
    required this.onRedo,
    required this.onAddTopic,
  });

  final bool canUndo;
  final bool canRedo;
  final bool busy;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onAddTopic;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.undo),
          tooltip: 'Undo',
          onPressed: canUndo && !busy ? onUndo : null,
        ),
        IconButton(
          icon: const Icon(Icons.redo),
          tooltip: 'Redo',
          onPressed: canRedo && !busy ? onRedo : null,
        ),
        const Spacer(),
        FilledButton.tonalIcon(
          onPressed: busy ? null : onAddTopic,
          icon: const Icon(Icons.add),
          label: const Text('Add topic'),
        ),
      ],
    );
  }
}

class _AnalyzeCard extends StatelessWidget {
  const _AnalyzeCard({required this.onAnalyze});

  final VoidCallback onAnalyze;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.auto_awesome_outlined),
        title: const Text('Not analyzed yet'),
        subtitle: const Text('Turn this recording into organized knowledge.'),
        trailing: FilledButton(
          onPressed: onAnalyze,
          child: const Text('Analyze'),
        ),
      ),
    );
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.label, required this.onCancel});

  final String label;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(label, style: theme.textTheme.titleSmall)),
                TextButton(
                  onPressed: onCancel,
                  child: const Text('Cancel'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const LinearProgressIndicator(minHeight: 4),
          ],
        ),
      ),
    );
  }
}

class _FailureCard extends StatelessWidget {
  const _FailureCard({required this.error, required this.onRetry});

  final String? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: ListTile(
        leading: Icon(Icons.error_outline, color: theme.colorScheme.error),
        title: Text(error ?? 'Analysis failed.'),
        trailing: FilledButton(onPressed: onRetry, child: const Text('Retry')),
      ),
    );
  }
}

/// Original vs cleaned transcript reader + editing + re-run (spec §15,
/// architecture §4.5, §4.12). Editing goes through the op-log so it is
/// undoable, versioned, and syncs as a diff; re-run submits a transcript
/// analysis job (STT skipped).
class _TranscriptCard extends ConsumerStatefulWidget {
  const _TranscriptCard({
    required this.sessionId,
    required this.original,
    required this.cleaned,
    required this.canEdit,
  });

  final String sessionId;
  final String? original;
  final String? cleaned;
  final bool canEdit;

  @override
  ConsumerState<_TranscriptCard> createState() => _TranscriptCardState();
}

class _TranscriptCardState extends ConsumerState<_TranscriptCard> {
  bool _showCleaned = true;

  Future<void> _edit(BuildContext context) async {
    final value = await showTranscriptEditor(
      context,
      initial: widget.cleaned ?? '',
    );
    if (value == null || value == (widget.cleaned ?? '')) return;
    await ref
        .read(editingControllerProvider(widget.sessionId).notifier)
        .apply(UpdateSessionTranscript(
          oldTranscript: widget.cleaned,
          newTranscript: value,
        ));
  }

  void _reanalyze(WidgetRef ref) {
    ref
        .read(analysisControllerProvider(widget.sessionId).notifier)
        .analyzeTranscript(widget.cleaned ?? '');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final both = widget.original != null && widget.cleaned != null;
    final text = _showCleaned ? widget.cleaned : widget.original;
    final label = _showCleaned ? 'Cleaned transcript' : 'Original transcript';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.transcribe_outlined,
                    size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(label, style: theme.textTheme.titleSmall),
                ),
                if (both)
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(
                          value: false, label: Text('Original'), icon: Icon(Icons.undo)),
                      ButtonSegment(
                          value: true, label: Text('Cleaned'), icon: Icon(Icons.auto_fix_high)),
                    ],
                    selected: {_showCleaned},
                    onSelectionChanged: (selection) =>
                        setState(() => _showCleaned = selection.first),
                    showSelectedIcon: false,
                  ),
              ],
            ),
            if (text != null) ...[
              const SizedBox(height: 8),
              SelectableText(
                text,
                style: theme.textTheme.bodyMedium,
              ),
            ],
            if (widget.canEdit && widget.cleaned != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Edit'),
                    onPressed: () => _edit(context),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.auto_awesome, size: 18),
                    label: const Text('Re-analyze'),
                    onPressed: () => _reanalyze(ref),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RelatedSessionsCard extends ConsumerWidget {
  const _RelatedSessionsCard({required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final related = ref.watch(relatedSessionsProvider(sessionId));

    return related.maybeWhen(
      data: (hits) {
        if (hits.isEmpty) return const SizedBox.shrink();
        return Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Related sessions', style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                for (final hit in hits)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: const Icon(Icons.account_tree_outlined, size: 20),
                    title: Text(
                      hit.title?.isNotEmpty == true
                          ? hit.title!
                          : 'Untitled session',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: hit.summary == null || hit.summary!.isEmpty
                        ? null
                        : Text(
                            hit.summary!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                    trailing: Text(
                      '${(hit.similarity * 100).round()}%',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    onTap: () => context.go('/sessions/${hit.sessionId}'),
                  ),
              ],
            ),
          ),
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }
}

class _TopicCard extends ConsumerStatefulWidget {
  const _TopicCard({
    required this.sessionId,
    required this.topic,
    required this.allTopics,
    required this.index,
    required this.canEdit,    this.initiallyExpanded = false,
  });

  final String sessionId;
  final Topic topic;
  final List<Topic> allTopics;
  final int index;
  final bool canEdit;
  final bool initiallyExpanded;

  @override
  ConsumerState<_TopicCard> createState() => _TopicCardState();
}

class _TopicCardState extends ConsumerState<_TopicCard> {
  late bool _expanded = widget.initiallyExpanded;

  Topic get topic => widget.topic;
  List<Topic> get allTopics => widget.allTopics;
  int get index => widget.index;
  bool get canEdit => widget.canEdit;
  String get sessionId => widget.sessionId;

  @override
  Widget build(BuildContext context) {
    final ctrl = ref.read(editingControllerProvider(sessionId).notifier);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          ListTile(
            onTap: () => _toggle(),
            leading: canEdit
                ? ReorderableDragStartListener(
                    index: index,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Icon(Icons.drag_handle),
                    ),
                  )
                : null,
            title: Text(topic.title),
            subtitle: topic.description.isEmpty ? null : Text(topic.description),
            trailing: canEdit
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PopupMenuButton<String>(
                        tooltip: 'Topic actions',
                        onSelected: (action) => _onMenu(context, ctrl, action),
                        itemBuilder: (context) => [
                          const PopupMenuItem(value: 'rename', child: Text('Rename')),
                          if (topic.items.isNotEmpty)
                            const PopupMenuItem(value: 'split', child: Text('Split…')),
                          if (allTopics.length > 1)
                            const PopupMenuItem(value: 'merge', child: Text('Merge into…')),
                          if (index > 0)
                            const PopupMenuItem(value: 'up', child: Text('Move up')),
                          if (index < allTopics.length - 1)
                            const PopupMenuItem(value: 'down', child: Text('Move down')),
                          const PopupMenuItem(value: 'delete', child: Text('Delete')),
                        ],
                      ),
                      IconButton(
                        icon: Icon(
                          _expanded ? Icons.expand_less : Icons.expand_more,
                        ),
                        tooltip: _expanded ? 'Collapse' : 'Expand',
                        onPressed: _toggle,
                      ),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final item in topic.items)
                    _ItemTile(
                      sessionId: sessionId,
                      topic: topic,
                      item: item,
                      allTopics: allTopics,
                      canEdit: canEdit,
                    ),
                  if (canEdit)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.add),
                      title: const Text('Add item'),
                      onTap: () async {
                        final result = await showItemEditor(
                          context,
                          item: Item(id: '', type: ItemType.task, title: ''),
                        );
                        if (result == null || result.title.isEmpty) return;
                        await ctrl.apply(InsertItem(
                          topicId: topic.id,
                          position: topic.items.length,
                          item: Item(
                            id: const Uuid().v4(),
                            type: ItemType.values
                                    .where((t) => t.name == result.type)
                                    .firstOrNull ??
                                ItemType.task,
                            title: result.title,
                            description: result.description,
                          ),
                        ));
                      },
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  void _toggle() => setState(() => _expanded = !_expanded);

  Future<void> _onMenu(
      BuildContext context, EditingController ctrl, String action) async {
    switch (action) {
      case 'rename':
        final value = await showTextEditor(
          context,
          title: 'Rename topic',
          label: 'Topic title',
          initial: topic.title,
        );
        if (value == null || value == topic.title) return;
        await ctrl.apply(RenameTopic(
          topicId: topic.id,
          oldTitle: topic.title,
          newTitle: value,
        ));
      case 'split':
        final ids = await showSplitDialog(context, topic: topic);
        if (ids == null || ids.isEmpty) return;
        if (!context.mounted) return;
        final movedItems = [
          for (final item in topic.items)
            if (ids.contains(item.id)) item,
        ];
        final title = await showTextEditor(
          context,
          title: 'New topic',
          label: 'Topic title',
          initial: '${topic.title} (2)',
        );
        if (!mounted) return;
        if (title == null || title.isEmpty) return;
        await ctrl.apply(SplitTopic(
          targetId: topic.id,
          sourceId: const Uuid().v4(),
          title: title,
          description: '',
          position: index + 1,
          movedItems: movedItems,
        ));
      case 'merge':
        final targetId = await showTopicPicker(
          context,
          title: 'Merge "${topic.title}" into…',
          topics: allTopics,
          excludedId: topic.id,
        );
        if (targetId == null) return;
        final target = allTopics.where((t) => t.id == targetId).firstOrNull;
        if (target == null) return;
        // Number source items from the target's length so the merge appends.
        final source = topic.copyWith(items: [
          for (var i = 0; i < topic.items.length; i++)
            topic.items[i].copyWith(position: target.items.length + i),
        ]);
        await ctrl.apply(MergeTopics(source: source, targetId: targetId));
      case 'up':
        await ctrl.apply(ReorderTopic(
          topicId: topic.id,
          from: index,
          to: index - 1,
        ));
      case 'down':
        await ctrl.apply(ReorderTopic(
          topicId: topic.id,
          from: index,
          to: index + 1,
        ));
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Delete topic?'),
            content: Text('"${topic.title}" and its items will be removed.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (ok ?? false) {
          await ctrl.apply(DeleteTopic(topic: topic));
        }
    }
  }
}

class _ItemTile extends ConsumerWidget {
  const _ItemTile({
    required this.sessionId,
    required this.topic,
    required this.item,
    required this.allTopics,
    required this.canEdit,
  });

  final String sessionId;
  final Topic topic;
  final Item item;
  final List<Topic> allTopics;
  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctrl = ref.read(editingControllerProvider(sessionId).notifier);
    return ListTile(
      dense: true,
      leading: Icon(_iconFor(item.type)),
      title: Text(item.title),
      subtitle: item.description.isEmpty ? null : Text(item.description),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _hints(),
          if (canEdit)
            PopupMenuButton<String>(
              tooltip: 'Item actions',
              onSelected: (action) => _onMenu(context, ctrl, action),
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'edit', child: Text('Edit')),
                if (allTopics.length > 1)
                  const PopupMenuItem(value: 'move', child: Text('Move to…')),
                const PopupMenuItem(value: 'priority', child: Text('Priority…')),
                const PopupMenuItem(value: 'confidence', child: Text('Confidence…')),
                const PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
        ],
      ),
    );
  }

  Widget _hints() {
    final lowConfidence = item.confidence != null && item.confidence! < 0.7;
    if (item.priority == null && !lowConfidence) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (item.priority != null)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Tooltip(
              message: 'Priority: ${item.priority!.name}',
              child: _priorityIcon(item.priority!),
            ),
          ),
        if (lowConfidence)
          const Tooltip(
            message: 'Low confidence — verify this item',
            child: Icon(Icons.help_outline, size: 16),
          ),
      ],
    );
  }

  Future<void> _onMenu(
      BuildContext context, EditingController ctrl, String action) async {
    switch (action) {
      case 'edit':
        final result = await showItemEditor(context, item: item);
        if (result == null || result.title == item.title && result.description == item.description && result.type == item.type.name) {
          return;
        }
        if (result.title != item.title || result.description != item.description) {
          await ctrl.apply(UpdateItemText(
            topicId: topic.id,
            itemId: item.id,
            oldTitle: item.title,
            oldDescription: item.description,
            newTitle: result.title,
            newDescription: result.description,
            oldConfidence: item.confidence,
          ));
        }
        if (result.type != item.type.name) {
          await ctrl.apply(ChangeItemType(
            topicId: topic.id,
            itemId: item.id,
            oldType: item.type.name,
            newType: result.type,
            oldConfidence: item.confidence,
          ));
        }
      case 'move':
        final targetId = await showTopicPicker(
          context,
          title: 'Move to…',
          topics: allTopics,
          excludedId: topic.id,
        );
        if (targetId == null) return;
        final target = allTopics.where((t) => t.id == targetId).firstOrNull;
        await ctrl.apply(MoveItem(
          fromTopicId: topic.id,
          toTopicId: targetId,
          position: target?.items.length ?? 0,
          originalPosition: item.position,
          item: item,
        ));
      case 'priority':
        final result = await showPriorityDialog(context, item.priority);
        final resolved = resolvePriority(result, item.priority);
        if (resolved == null) return;
        await ctrl.apply(SetItemPriority(
          topicId: topic.id,
          itemId: item.id,
          oldPriority: item.priority?.name,
          newPriority:
              resolved.cleared ? null : resolved.priority!.name,
        ));
      case 'confidence':
        final value = await showConfidenceDialog(context, item.confidence);
        if (value == null) return;
        final newValue = value.isNaN ? null : value;
        if (newValue == item.confidence) return;
        await ctrl.apply(SetItemConfidence(
          topicId: topic.id,
          itemId: item.id,
          oldConfidence: item.confidence,
          newConfidence: newValue,
        ));
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Delete item?'),
            content: Text('"${item.title}" will be removed.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (ok ?? false) {
          await ctrl.apply(DeleteItem(topicId: topic.id, item: item));
        }
    }
  }

  Widget _priorityIcon(Priority priority) {
    switch (priority) {
      case Priority.high:
        return Icon(Icons.flag, size: 16, color: Colors.red.shade400);
      case Priority.medium:
        return Icon(Icons.flag_outlined, size: 16, color: Colors.orange.shade400);
      case Priority.low:
        return Icon(Icons.outlined_flag, size: 16, color: Colors.grey.shade500);
    }
  }

  IconData _iconFor(dynamic type) {
    switch (type.toString()) {
      case 'task':
        return Icons.check_circle_outline;
      case 'idea':
        return Icons.lightbulb_outline;
      case 'decision':
        return Icons.gavel_outlined;
      case 'question':
        return Icons.question_mark_outlined;
      case 'event':
        return Icons.event_outlined;
      case 'reminder':
        return Icons.alarm_outlined;
      case 'reference':
        return Icons.link_outlined;
      default:
        return Icons.circle_outlined;
    }
  }
}
