import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/repositories.dart';
import '../../domain/usecases/manage_sessions.dart';
import '../analysis/analysis_controller.dart';
import '../auth/auth_controller.dart';

/// Manual-note capture (architecture §4.12, universal input): the note travels
/// as text (no recording, no STT) and the pipeline starts at cleanup. Saving
/// creates a local session draft, kicks off analysis, and lands on the session
/// detail screen where progress + the canonical result show.
class NoteEditorScreen extends ConsumerStatefulWidget {
  const NoteEditorScreen({super.key});

  @override
  ConsumerState<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

class _NoteEditorScreenState extends ConsumerState<NoteEditorScreen> {
  final _titleController = TextEditingController();
  final _textController = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _titleController.dispose();
    _textController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final text = _textController.text;
    if (text.trim().isEmpty || _saving) return;
    setState(() => _saving = true);
    try {
      final userId = ref.read(authControllerProvider).valueOrNull;
      final session = await StartNoteSession(ref.read(databaseProvider))(
        userId: userId,
        text: text,
        title: _titleController.text,
      );
      // Fail-safe: any setup error surfaces in the analysis controller as a
      // retryable failure rather than blocking navigation.
      ref.read(analysisControllerProvider(session.id).notifier)
          .analyzeNote(text, title: _titleController.text);
      if (mounted) context.go('/sessions/${session.id}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save the note.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('New note')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _titleController,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Title (optional)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _textController,
            minLines: 8,
            maxLines: null,
            textCapitalization: TextCapitalization.sentences,
            keyboardType: TextInputType.multiline,
            decoration: const InputDecoration(
              labelText: 'Note',
              hintText: 'Write what is on your mind…',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const ValueKey('save-note'),
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.auto_awesome),
            label: const Text('Save & analyze'),
          ),
          const SizedBox(height: 8),
          Text(
            'Your note is analyzed into topics, tasks, and knowledge — same '
            'pipeline as a recording, minus the audio.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
