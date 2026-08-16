import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/session_version.dart';
import '../../domain/versioning/session_diff.dart';
import 'version_controller.dart';

/// Version history picker + diff preview + restore (architecture §4.6).
class VersionHistoryScreen extends ConsumerWidget {
  const VersionHistoryScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final versioning = ref.watch(versioningControllerProvider(sessionId));
    final ctrl = ref.read(versioningControllerProvider(sessionId).notifier);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Version history')),
      body: versioning.versions.isEmpty
          ? Center(
              child: Text(
                'No versions yet.',
                style: theme.textTheme.bodyMedium,
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: ListView.builder(
                    itemCount: versioning.versions.length,
                    itemBuilder: (context, index) {
                      final items = versioning.versions;
                      final version = items[items.length - 1 - index];
                      final prev = index == items.length - 1
                          ? null
                          : items[items.length - 2 - index];
                      return _VersionTile(
                        version: version,
                        previous: prev,
                        isCurrent: version.versionNo == items.last.versionNo,
                        isSelected:
                            versioning.selectedVersionNo == version.versionNo,
                        onTap: () => ctrl.select(
                          versioning.selectedVersionNo == version.versionNo
                              ? null
                              : version.versionNo,
                        ),
                      );
                    },
                  ),
                ),
                if (versioning.selectedVersionNo != null)
                  _DiffPane(
                    versionNo: versioning.selectedVersionNo!,
                    entries: _diffFor(
                      versioning.versions,
                      versioning.selectedVersionNo!,
                    ),
                  ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: versioning.selectedVersionNo == null ||
                                versioning.busy
                            ? null
                            : () => _restore(context, ctrl,
                                versioning.selectedVersionNo!),
                        icon: const Icon(Icons.history),
                        label: Text(
                          versioning.busy
                              ? 'Restoring…'
                              : versioning.selectedVersionNo == null
                                  ? 'Select a version to restore'
                                  : 'Restore v${versioning.selectedVersionNo}',
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Future<void> _restore(BuildContext context, VersioningController ctrl,
      int versionNo) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Restore v$versionNo?'),
        content: const Text(
            'The current content will be replaced. The restore itself is '
            'saved as a new version, so nothing is permanently lost.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final restored = await ctrl.restore(versionNo);
    if (restored == null || !context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text('Restored v$versionNo as a new version.')),
      );
    Navigator.of(context).pop();
  }

  List<SessionDiffEntry> _diffFor(
      List<SessionVersion> versions, int versionNo) {
    final index = versions.indexWhere((v) => v.versionNo == versionNo);
    if (index <= 0) return const [];
    return diffSessions(versions[index - 1].snapshot, versions[index].snapshot);
  }
}

class _VersionTile extends StatelessWidget {
  const _VersionTile({
    required this.version,
    required this.previous,
    required this.isCurrent,
    required this.isSelected,
    required this.onTap,
  });

  final SessionVersion version;
  final SessionVersion? previous;
  final bool isCurrent;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = <String>[
      _format(version.createdAt),
      if (isCurrent) 'current',
    ].join(' · ');
    return ListTile(
      selected: isSelected,
      leading: CircleAvatar(
        radius: 18,
        child: Text('v${version.versionNo}'),
      ),
      title: Text(
        version.changeReason ?? 'Version ${version.versionNo}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(subtitle, style: theme.textTheme.bodySmall),
      trailing: Icon(
        isSelected ? Icons.expand_less : Icons.expand_more,
      ),
      onTap: onTap,
    );
  }

  String _format(DateTime? when) {
    if (when == null) return '—';
    final local = when.toLocal();
    final now = DateTime.now();
    final diff = now.difference(local);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}

/// What changed in the selected version, rendered as a readable list
/// (architecture §4.6 diff view).
class _DiffPane extends StatelessWidget {
  const _DiffPane({required this.versionNo, required this.entries});

  final int versionNo;
  final List<SessionDiffEntry> entries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.dividerColor)),
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      ),
      child: entries.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'v$versionNo is the initial version — no previous content to compare.',
                style: theme.textTheme.bodyMedium,
              ),
            )
          : ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text(
                    'What changed in v$versionNo',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                for (final entry in entries) _DiffRow(entry: entry),
              ],
            ),
    );
  }
}

class _DiffRow extends StatelessWidget {
  const _DiffRow({required this.entry});

  final SessionDiffEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, color) = switch (entry.kind) {
      DiffKind.titleChanged => (Icons.title, theme.colorScheme.primary),
      DiffKind.summaryChanged =>
        (Icons.notes_outlined, theme.colorScheme.primary),
      DiffKind.topicAdded => (Icons.add_box_outlined, Colors.green.shade600),
      DiffKind.topicRemoved => (Icons.indeterminate_check_box_outlined, Colors.red.shade400),
      DiffKind.topicRenamed => (Icons.drive_file_rename_outline, theme.colorScheme.tertiary),
      DiffKind.topicMoved => (Icons.swap_vert, theme.colorScheme.tertiary),
      DiffKind.itemAdded => (Icons.add, Colors.green.shade600),
      DiffKind.itemRemoved => (Icons.remove_circle_outline, Colors.red.shade400),
      DiffKind.itemMoved => (Icons.swap_vert, theme.colorScheme.tertiary),
      DiffKind.itemEdited => (Icons.edit_outlined, theme.colorScheme.tertiary),
      DiffKind.entityAdded =>
        (Icons.account_tree_outlined, Colors.green.shade600),
      DiffKind.entityRemoved =>
        (Icons.account_tree_outlined, Colors.red.shade400),
      DiffKind.entityEdited => (Icons.account_tree_outlined, theme.colorScheme.tertiary),
      DiffKind.relationshipAdded =>
        (Icons.hub_outlined, Colors.green.shade600),
      DiffKind.relationshipRemoved =>
        (Icons.hub_outlined, Colors.red.shade400),
      DiffKind.relationshipEdited => (Icons.hub_outlined, theme.colorScheme.tertiary),
    };

    final detail = <String>[
      entry.label,
      if (entry.detail != null && entry.detail!.isNotEmpty)
        entry.kind == DiffKind.titleChanged ||
                entry.kind == DiffKind.summaryChanged ||
                entry.kind == DiffKind.topicRenamed ||
                entry.kind == DiffKind.itemEdited
            ? '"${entry.before ?? ''}" → "${entry.after ?? ''}"'
            : entry.detail!,
    ].join(': ');

    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: Icon(icon, size: 18, color: color),
      title: Text(detail, maxLines: 2, overflow: TextOverflow.ellipsis),
    );
  }
}
