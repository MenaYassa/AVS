/// Editable draft screen (architecture §4.11, spec §23).
///
/// Lets the user review and edit an AI command draft before saving it into
/// the session or exporting it (§5.5).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/entities/command_draft.dart';
import '../../domain/entities/enums.dart';
import '../../domain/repositories.dart';
import '../../domain/usecases/save_draft_to_session.dart';
import '../editing/editing_controller.dart';
import '../plugins/plugins_controller.dart';

/// Route argument for opening a draft.
class DraftScreenArgs {
  const DraftScreenArgs({required this.sessionId, required this.draftId});
  final String sessionId;
  final String draftId;
}

class DraftScreen extends ConsumerStatefulWidget {
  const DraftScreen({super.key, required this.args});

  final DraftScreenArgs args;

  @override
  ConsumerState<DraftScreen> createState() => _DraftScreenState();
}

class _DraftScreenState extends ConsumerState<DraftScreen> {
  late TextEditingController _titleController;
  late TextEditingController _bodyController;
  late List<_DraftItemRow> _itemRows;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController();
    _bodyController = TextEditingController();
    _itemRows = [];
    _loadDraft();
  }

  Future<void> _loadDraft() async {
    final draft = await ref
        .read(draftRepositoryProvider)
        .getDraft(widget.args.draftId);
    if (draft != null && mounted) {
      setState(() {
        _titleController.text = draft.title;
        _bodyController.text = draft.body;
        _itemRows = draft.items
            .map((di) => _DraftItemRow.fromDraftItem(di))
            .toList();
      });
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  void _markDirty() => setState(() {});

  Future<void> _saveToSession() async {
    final session = await ref
        .read(databaseProvider)
        .getSession(widget.args.sessionId);
    if (session == null) {
      _showSnack('Session not found');
      return;
    }

    final draft = CommandDraft(
      id: widget.args.draftId,
      sessionId: widget.args.sessionId,
      command: '', // command not needed for save
      title: _titleController.text,
      body: _bodyController.text,
      items: _itemRows
          .map(
            (r) => DraftItem(
              title: r.titleController.text,
              body: r.bodyController.text,
              type: r.type,
              priority: r.priority,
              confidence: r.confidence,
            ),
          )
          .toList(),
    );

    final ops = buildSaveDraftOperations(session, draft);
    final editing = ref.read(editingControllerProvider(widget.args.sessionId).notifier);

    for (final op in ops) {
      await editing.apply(op);
    }

    // Delete the draft after saving
    await ref.read(draftRepositoryProvider).deleteDraft(widget.args.draftId);

    if (mounted) {
      context.go('/session/${widget.args.sessionId}');
      _showSnack('Saved to session');
    }
  }

  Future<void> _deleteDraft() async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Delete draft?'),
            content: const Text('This draft will be permanently removed.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    await ref.read(draftRepositoryProvider).deleteDraft(widget.args.draftId);
    if (mounted) {
      context.go('/session/${widget.args.sessionId}');
    }
  }

  void _showSnack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Map<String, dynamic> _currentDraftJson() => {
        'title': _titleController.text,
        'body': _bodyController.text,
        'items': _itemRows
            .map(
              (r) => {
                'title': r.titleController.text,
                'body': r.bodyController.text,
                if (r.type != null) 'type': r.type!.name,
                if (r.priority != null) 'priority': r.priority!.name,
                if (r.confidence != null) 'confidence': r.confidence,
              },
            )
            .toList(),
      };

  Future<void> _pushToPlugin(String kind) async {
    final statuses = ref.read(pluginsProvider).valueOrNull ?? const [];
    final target = statuses.where((s) => s.kind == kind).firstOrNull;
    if (target == null) {
      _showSnack('Plugin not available');
      return;
    }
    try {
      final receipt = await ref
          .read(pluginsProvider.notifier)
          .pushDraft(kind, draft: _currentDraftJson());
      if (!mounted) return;
      final where = receipt.targetUrl != null
          ? ' → ${receipt.targetUrl}'
          : '';
      _showSnack('Pushed to ${target.displayName}$where');
    } on Exception catch (e) {
      if (mounted) _showSnack('Push failed: $e');
    }
  }

  void _addItem() {
    setState(() {
      _itemRows.add(_DraftItemRow.empty());
      _markDirty();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canPop = Navigator.of(context).canPop();
    final connectedPlugins = (ref.watch(pluginsProvider).valueOrNull ?? const [])
        .where((s) => s.connected)
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Draft'),
        leading: canPop
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => context.go('/session/${widget.args.sessionId}'),
              )
            : null,
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Push to plugin',
            icon: const Icon(Icons.ios_share),
            onSelected: _pushToPlugin,
            itemBuilder: (context) {
              if (connectedPlugins.isEmpty) {
                return const [
                  PopupMenuItem<String>(
                    enabled: false,
                    child: Text('No connected plugins (see Settings)'),
                  ),
                ];
              }
              return [
                for (final t in connectedPlugins)
                  PopupMenuItem(
                    value: t.kind,
                    child: Text('Push to ${t.displayName}'),
                  ),
              ];
            },
          ),
          IconButton(
            tooltip: 'Delete draft',
            icon: const Icon(Icons.delete_outline),
            onPressed: _deleteDraft,
          ),
          FilledButton(
            onPressed: _saveToSession,
            child: const Text('Save to session'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _titleController,
            decoration: const InputDecoration(
              labelText: 'Title',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => _markDirty(),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _bodyController,
            decoration: const InputDecoration(
              labelText: 'Body',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
            maxLines: 8,
            onChanged: (_) => _markDirty(),
          ),
          if (_itemRows.isNotEmpty) ...[
            const SizedBox(height: 24),
            Row(
              children: [
                Text('Structured items',
                    style: theme.textTheme.titleMedium),
                const Spacer(),
                TextButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('Add item'),
                  onPressed: _addItem,
                ),
              ],
            ),
            const SizedBox(height: 8),
            ..._itemRows.asMap().entries.map((e) => _ItemCard(
                  index: e.key,
                  row: e.value,
                  onRemove: () => setState(() {
                    _itemRows.removeAt(e.key);
                    _markDirty();
                  }),
                  onChange: _markDirty,
                )),
          ],
        ],
      ),
    );
  }
}

class _DraftItemRow {
  _DraftItemRow({
    required this.titleController,
    required this.bodyController,
    this.type,
    this.priority,
    this.confidence,
  });

  final TextEditingController titleController;
  final TextEditingController bodyController;
  final ItemType? type;
  final Priority? priority;
  final double? confidence;

  factory _DraftItemRow.fromDraftItem(DraftItem di) => _DraftItemRow(
        titleController: TextEditingController(text: di.title),
        bodyController: TextEditingController(text: di.body),
        type: di.type,
        priority: di.priority,
        confidence: di.confidence,
      );

  factory _DraftItemRow.empty() => _DraftItemRow(
        titleController: TextEditingController(),
        bodyController: TextEditingController(),
      );

  void dispose() {
    titleController.dispose();
    bodyController.dispose();
  }
}

class _ItemCard extends ConsumerStatefulWidget {
  const _ItemCard({
    required this.index,
    required this.row,
    required this.onRemove,
    required this.onChange,
  });

  final int index;
  final _DraftItemRow row;
  final VoidCallback onRemove;
  final VoidCallback onChange;

  @override
  ConsumerState<_ItemCard> createState() => _ItemCardState();
}

class _ItemCardState extends ConsumerState<_ItemCard> {
  ItemType? _type;
  Priority? _priority;
  double? _confidence;

  @override
  void initState() {
    super.initState();
    _type = widget.row.type;
    _priority = widget.row.priority;
    _confidence = widget.row.confidence;
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: widget.row.titleController,
                    decoration: const InputDecoration(
                      labelText: 'Item title',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (_) => widget.onChange(),
                  ),
                ),
                IconButton(
                  tooltip: 'Remove item',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: widget.onRemove,
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: widget.row.bodyController,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              maxLines: 3,
              onChanged: (_) => widget.onChange(),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                DropdownButtonFormField<ItemType?>(
                  value: _type,
                  decoration: const InputDecoration(
                    labelText: 'Type',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('(none)')),
                    ...ItemType.values.map(
                      (t) => DropdownMenuItem(value: t, child: Text(t.name)),
                    ),
                  ],
                  onChanged: (v) => setState(() {
                    _type = v;
                    widget.onChange();
                  }),
                ),
                DropdownButtonFormField<Priority?>(
                  value: _priority,
                  decoration: const InputDecoration(
                    labelText: 'Priority',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('(none)')),
                    ...Priority.values.map(
                      (p) => DropdownMenuItem(value: p, child: Text(p.name)),
                    ),
                  ],
                  onChanged: (v) => setState(() {
                    _priority = v;
                    widget.onChange();
                  }),
                ),
                TextFormField(
                  initialValue: _confidence?.toStringAsFixed(2),
                  decoration: const InputDecoration(
                    labelText: 'Confidence (0-1)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (v) {
                    final parsed = double.tryParse(v);
                    if (parsed != null && parsed >= 0 && parsed <= 1) {
                      setState(() => _confidence = parsed);
                      widget.onChange();
                    }
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}