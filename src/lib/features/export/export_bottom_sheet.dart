import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/session.dart';
import '../../domain/repositories.dart';
import 'export_controller.dart';
import 'session_exporter.dart';

/// Bottom sheet for selecting an export format and sharing a session
/// (spec §20, architecture §3.3).
class ExportBottomSheet extends ConsumerWidget {
  const ExportBottomSheet({
    super.key,
    required this.session,
  });

  final Session session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text(
              'Export Session',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('Markdown'),
            subtitle: const Text('Best for notes apps'),
            onTap: () => _export(context, ref, ExportFormat.markdown),
          ),
          ListTile(
            leading: const Icon(Icons.code),
            title: const Text('JSON'),
            subtitle: const Text('Machine-readable canonical form'),
            onTap: () => _export(context, ref, ExportFormat.json),
          ),
          ListTile(
            leading: const Icon(Icons.text_snippet_outlined),
            title: const Text('Plain Text'),
            subtitle: const Text('Simple text outline'),
            onTap: () => _export(context, ref, ExportFormat.plainText),
          ),
          ListTile(
            leading: const Icon(Icons.picture_as_pdf),
            title: const Text('PDF'),
            subtitle: const Text('Formatted document'),
            onTap: () => _export(context, ref, ExportFormat.pdf),
          ),
          ListTile(
            leading: const Icon(Icons.copy),
            title: const Text('Copy to Clipboard'),
            subtitle: const Text('Copy Markdown to clipboard'),
            onTap: () => _copyToClipboard(context, ref),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Future<void> _export(
    BuildContext context,
    WidgetRef ref,
    ExportFormat format,
  ) async {
    Navigator.pop(context);
    final tags = await ref
        .read(tagRepositoryProvider)
        .getTagsForSession(session.id);
    if (!context.mounted) return;
    await ref.read(exportControllerProvider).export(
          context,
          session: session,
          tags: tags,
          format: format,
        );
  }

  Future<void> _copyToClipboard(
    BuildContext context,
    WidgetRef ref,
  ) async {
    Navigator.pop(context);
    final tags = await ref
        .read(tagRepositoryProvider)
        .getTagsForSession(session.id);
    await ref.read(exportControllerProvider).copyToClipboard(
          session: session,
          tags: tags,
        );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Copied to clipboard')),
      );
    }
  }
}