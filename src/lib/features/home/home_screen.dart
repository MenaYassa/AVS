import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/entities/enums.dart';
import '../../domain/entities/session.dart';
import '../../domain/repositories.dart';
import '../../data/sync/sync_engine.dart';
import '../auth/auth_controller.dart';
import '../capture/document_capture_controller.dart';
import '../capture/document_capture_sheet.dart';
import '../organization/organization_controller.dart';
import '../recording/recording_controller.dart';
import '../sync/sync_controller.dart';

/// Home: large record button, recent sessions, quick stats (spec §5).
enum HomeFilter { all, favorites, archived, trash }

final homeFilterProvider =
    NotifierProvider<HomeFilterNotifier, HomeFilter>(HomeFilterNotifier.new);

class HomeFilterNotifier extends Notifier<HomeFilter> {
  @override
  HomeFilter build() => HomeFilter.all;

  void set(HomeFilter filter) => state = filter;
}

final homeSessionsProvider = StreamProvider<List<Session>>((ref) {
  final filter = ref.watch(homeFilterProvider);
  // Trash is the only tab that surfaces deleted sessions.
  final includeDeleted = filter == HomeFilter.trash;
  final stream =
      ref.watch(databaseProvider).watchSessions(includeDeleted: includeDeleted);
  return stream.map((sessions) => _filterForTab(sessions, filter));
});

List<Session> _filterForTab(List<Session> sessions, HomeFilter filter) {
  final visible = sessions.where((s) {
    return switch (filter) {
      HomeFilter.all => !s.deleted,
      HomeFilter.favorites => s.favorite && !s.deleted && !s.archived,
      HomeFilter.archived => s.archived && !s.deleted,
      HomeFilter.trash => s.deleted,
    };
  }).toList();
  // Pinned sessions float to the top (§4.2 "pinned sessions").
  visible.sort((a, b) {
    if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
    final at = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final bt = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    return bt.compareTo(at);
  });
  return visible;
}

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider).valueOrNull;
    final sessions = ref.watch(homeSessionsProvider);
    final rec = ref.watch(recordingControllerProvider);
    final sync = ref.watch(syncControllerProvider);
    final filter = ref.watch(homeFilterProvider);
    final org = ref.read(organizationControllerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Knowledge'),
        actions: [
          IconButton(
            tooltip: 'Knowledge map',
            icon: const Icon(Icons.hub_outlined),
            onPressed: () => context.go('/graph'),
          ),
          IconButton(
            tooltip: 'Insights',
            icon: const Icon(Icons.auto_awesome_outlined),
            onPressed: () => context.go('/insights'),
          ),
          IconButton(
            tooltip: 'Search',
            icon: const Icon(Icons.search),
            onPressed: () => context.go('/search'),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.go('/settings'),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.read(syncControllerProvider.notifier).syncNow(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            _RecordCard(
              isRecording: rec.isRecording,
              isPaused: rec.isPaused,
              duration: rec.duration,
              waveform: rec.waveform,
              error: rec.error,
              onPressed: () => rec.isActive
                  ? ref.read(recordingControllerProvider.notifier).stop()
                  : ref.read(recordingControllerProvider.notifier).start(),
              onTogglePause: () => rec.isPaused
                  ? ref.read(recordingControllerProvider.notifier).resume()
                  : ref.read(recordingControllerProvider.notifier).pause(),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('write-note'),
                    onPressed: () => context.go('/note/new'),
                    icon: const Icon(Icons.edit_note_outlined),
                    label: const Text('Write a note'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('import-document'),
                    onPressed: () => _importDocument(context, ref),
                    icon: const Icon(Icons.file_upload_outlined),
                    label: const Text('Import image/PDF'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _FilterBar(
              filter: filter,
              onSelected: (f) => ref.read(homeFilterProvider.notifier).set(f),
            ),
            const SizedBox(height: 16),
            Text('Recent Sessions',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (auth == null) ...[
              _SignInPrompt(onPressed: () => _signIn(ref)),
              const SizedBox(height: 12),
            ] else ...[
              _SyncStatusBar(sync: sync),
              const SizedBox(height: 12),
            ],
            if (sessions.isLoading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (sessions.hasError)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Could not load sessions: ${sessions.error}'),
              )
            else if (sessions.value!.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_emptyMessage(filter)),
              )
            else
              ...sessions.value!.map((s) => _SessionTile(
                    session: s,
                    inTrash: filter == HomeFilter.trash,
                    onTap: () => context.go('/sessions/${s.id}'),
                    onToggleFavorite: () => org.toggleFavorite(s),
                    onToggleArchive: () => org.toggleArchive(s),
                    onTogglePin: () => org.togglePin(s),
                    onTrash: () => org.trash(s),
                    onRestore: () => org.restore(s),
                    onPurge: () => org.purge(s),
                  )),
          ],
        ),
      ),
    );
  }

  String _emptyMessage(HomeFilter filter) => switch (filter) {
        HomeFilter.all => 'No sessions yet. Tap the mic and think out loud.',
        HomeFilter.favorites => 'No favorites yet. Star a session to find it here.',
        HomeFilter.archived => 'Nothing archived. Archive sessions to declutter.',
        HomeFilter.trash => 'Trash is empty.',
      };

  Future<void> _signIn(WidgetRef ref) async {
    await ref.read(authControllerProvider.notifier).signInWithGoogle();
    // Push pending local changes and pull the cloud on sign-in (§4.13).
    ref.read(syncControllerProvider.notifier).syncNow();
  }

  /// Universal input, document capture (§4.12): pick an image/PDF, import it
  /// into a session, and land on its detail screen where analysis progresses.
  Future<void> _importDocument(BuildContext context, WidgetRef ref) async {
    final kind = await showDocumentCaptureSheet(context);
    if (kind == null) return;
    final session = await ref
        .read(documentCaptureControllerProvider.notifier)
        .capture(kind);
    if (session == null) return;
    if (context.mounted) context.go('/sessions/${session.id}');
  }
}

class _RecordCard extends StatelessWidget {
  const _RecordCard({
    required this.isRecording,
    required this.isPaused,
    required this.duration,
    required this.waveform,
    required this.error,
    required this.onPressed,
    required this.onTogglePause,
  });

  final bool isRecording;
  final bool isPaused;
  final Duration duration;
  final List<double> waveform;
  final String? error;
  final VoidCallback onPressed;
  final VoidCallback onTogglePause;

  String get _fmt {
    final m = duration.inMinutes.toString().padLeft(2, '0');
    final s = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final active = isRecording || isPaused;
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            if (active)
              _Waveform(samples: waveform, color: colors.primary)
            else
              const SizedBox(height: 40),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (active) ...[
                  IconButton(
                    onPressed: onTogglePause,
                    tooltip: isPaused ? 'Resume recording' : 'Pause recording',
                    icon: Icon(
                      isPaused
                          ? Icons.play_circle_outline
                          : Icons.pause_circle_outline,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                IconButton(
                  onPressed: onPressed,
                  iconSize: 72,
                  tooltip: active ? 'Stop recording' : 'Start recording',
                  icon: Icon(
                    active ? Icons.stop_circle_outlined : Icons.mic,
                    color: active ? colors.error : colors.primary,
                  ),
                ),
                if (active) const SizedBox(width: 56),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _label(),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(error!, style: TextStyle(color: colors.error)),
            ],
          ],
        ),
      ),
    );
  }

  String _label() {
    if (!isRecording && !isPaused) return 'Start Recording';
    final state = isPaused ? 'Paused' : 'Recording…';
    return '$state  $_fmt';
  }
}

/// Simple live waveform: a row of vertical bars whose heights follow the
/// rolling amplitude samples (latest on the right).
class _Waveform extends StatelessWidget {
  const _Waveform({required this.samples, required this.color});

  final List<double> samples;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const ValueKey('record-waveform'),
      height: 40,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (final sample in samples)
            Container(
              width: 3,
              height: 4 + (sample.clamp(0.0, 1.0)) * 34,
              margin: const EdgeInsets.symmetric(horizontal: 1.5),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(1.5),
              ),
            ),
        ],
      ),
    );
  }
}

/// Live sync status while signed in: in-flight indicator, last-run summary,
/// or the latest failure (architecture §4.13).
class _SyncStatusBar extends StatelessWidget {
  const _SyncStatusBar({required this.sync});

  final AsyncValue<SyncRunResult> sync;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (sync.isLoading) {
      return Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text('Syncing…', style: theme.textTheme.bodySmall),
        ],
      );
    }
    if (sync.hasError) {
      return Text(
        'Sync failed: ${sync.error}',
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.error),
      );
    }
    final run = sync.valueOrNull;
    if (run?.completedAt == null) return const SizedBox.shrink();
    final time = run!.completedAt!.toLocal();
    final hm = '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';
    final parts = <String>[
      if (run.pushed > 0) 'pushed ${run.pushed}',
      if (run.pulled > 0) 'pulled ${run.pulled}',
      if (run.deleted > 0) 'deleted ${run.deleted}',
      if (run.failed > 0) '${run.failed} failed',
    ];
    final summary = parts.isEmpty ? '' : ' · ${parts.join(' · ')}';
    return Text(
      'Synced at $hm$summary',
      style: theme.textTheme.bodySmall,
    );
  }
}

class _SignInPrompt extends StatelessWidget {
  const _SignInPrompt({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.cloud_off_outlined),
        title: const Text('Signed out'),
        subtitle: const Text('Sign in with Google to sync your knowledge.'),
        trailing: TextButton(onPressed: onPressed, child: const Text('Sign in')),
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.filter, required this.onSelected});

  final HomeFilter filter;
  final ValueChanged<HomeFilter> onSelected;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<HomeFilter>(
      segments: const [
        ButtonSegment(value: HomeFilter.all, label: Text('All')),
        ButtonSegment(value: HomeFilter.favorites, label: Text('Favorites')),
        ButtonSegment(value: HomeFilter.archived, label: Text('Archived')),
        ButtonSegment(value: HomeFilter.trash, label: Text('Trash')),
      ],
      selected: {filter},
      onSelectionChanged: (selection) => onSelected(selection.first),
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({
    required this.session,
    required this.inTrash,
    required this.onTap,
    required this.onToggleFavorite,
    required this.onToggleArchive,
    required this.onTogglePin,
    required this.onTrash,
    required this.onRestore,
    required this.onPurge,
  });

  final Session session;
  final bool inTrash;
  final VoidCallback onTap;
  final VoidCallback onToggleFavorite;
  final VoidCallback onToggleArchive;
  final VoidCallback onTogglePin;
  final VoidCallback onTrash;
  final VoidCallback onRestore;
  final VoidCallback onPurge;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final ready = session.status == SessionStatus.ready;
    return Card(
      child: ListTile(
        onTap: onTap,
        leading: session.pinned
            ? const Icon(Icons.push_pin, size: 20)
            : null,
        title: Row(
          children: [
            Flexible(
              child: Text(session.title ?? 'Untitled',
                  overflow: TextOverflow.ellipsis),
            ),
            if (!ready) ...[
              const SizedBox(width: 8),
              _StatusChip(status: session.status),
            ],
          ],
        ),
        subtitle: Text(_subtitle()),
        trailing: inTrash
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Restore',
                    icon: const Icon(Icons.restore),
                    onPressed: onRestore,
                  ),
                  IconButton(
                    tooltip: 'Delete forever',
                    icon: Icon(Icons.delete_forever_outlined,
                        color: colors.error),
                    onPressed: onPurge,
                  ),
                ],
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: session.favorite
                        ? 'Remove from favorites'
                        : 'Add to favorites',
                    icon: Icon(
                      session.favorite ? Icons.star : Icons.star_border,
                      color: session.favorite ? colors.tertiary : null,
                    ),
                    onPressed: onToggleFavorite,
                  ),
                  IconButton(
                    tooltip: session.archived ? 'Unarchive' : 'Archive',
                    icon: Icon(
                      session.archived
                          ? Icons.unarchive_outlined
                          : Icons.archive_outlined,
                    ),
                    onPressed: onToggleArchive,
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'More',
                    onSelected: (value) {
                      switch (value) {
                        case 'pin':
                          onTogglePin();
                        case 'trash':
                          onTrash();
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'pin',
                        child: Text(session.pinned ? 'Unpin' : 'Pin'),
                      ),
                      const PopupMenuItem(
                        value: 'trash',
                        child: Text('Move to trash'),
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }

  String _subtitle() {
    final d = session.createdAt?.toLocal();
    if (d == null) return session.summary ?? '';
    final date = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return session.summary ?? date;
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final SessionStatus status;

  @override
  Widget build(BuildContext context) {
    return Chip(
      label: Text(status.name),
      visualDensity: VisualDensity.compact,
    );
  }
}
