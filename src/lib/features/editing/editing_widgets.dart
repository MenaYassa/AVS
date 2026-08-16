import 'package:flutter/material.dart';

import '../../domain/entities/enums.dart';
import '../../domain/entities/session.dart';

/// Shared editing dialogs for session detail (architecture §3.4). Pure UI:
/// the caller turns the result into an [EditOperation].

/// Single-field text editor (title, summary, topic rename, item text).
Future<String?> showTextEditor(
  BuildContext context, {
  required String title,
  required String label,
  required String initial,
  String? hint,
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(labelText: label, hintText: hint),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

/// Multiline transcript editor (spec §15). Returns the trimmed text.
Future<String?> showTranscriptEditor(
  BuildContext context, {
  required String initial,
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Edit transcript'),
      content: SizedBox(
        width: 480,
        height: 360,
        child: TextField(
          controller: controller,
          autofocus: true,
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          decoration: const InputDecoration(
            hintText: 'Correct the transcript, then re-run analysis.',
            alignLabelWithHint: true,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

/// Topic editor: title + optional description. Returns the new values.
Future<({String title, String description})?> showTopicEditor(
  BuildContext context, {
  required String initialTitle,
  required String initialDescription,
}) {
  final title = TextEditingController(text: initialTitle);
  final description = TextEditingController(text: initialDescription);
  return showDialog<({String title, String description})>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Edit topic'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: title,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Topic title'),
          ),
          TextField(
            controller: description,
            decoration: const InputDecoration(labelText: 'Description (optional)'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop((
            title: title.text.trim(),
            description: description.text.trim(),
          )),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

/// Item editor: title, description, type. Returns the new values.
Future<({String title, String description, String type})?> showItemEditor(
  BuildContext context, {
  required Item item,
}) {
  final title = TextEditingController(text: item.title);
  final description = TextEditingController(text: item.description);
  var type = item.type.name;
  return showDialog<({String title, String description, String type})>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Edit item'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: title,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Item title'),
          ),
          TextField(
            controller: description,
            decoration: const InputDecoration(labelText: 'Description (optional)'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: type,
            decoration: const InputDecoration(labelText: 'Type'),
            items: [
              for (final t in ItemType.values)
                DropdownMenuItem(value: t.name, child: Text(t.name)),
            ],
            onChanged: (value) {
              if (value != null) type = value;
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop((
            title: title.text.trim(),
            description: description.text.trim(),
            type: type,
          )),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

/// Pick one of [topics] (excluding [excludedId]). Returns the chosen topic id.
Future<String?> showTopicPicker(
  BuildContext context, {
  required String title,
  required List<Topic> topics,
  String? excludedId,
}) {
  final candidates = topics.where((t) => t.id != excludedId).toList();
  if (candidates.isEmpty) return Future.value();
  return showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(title),
      children: [
        for (final t in candidates)
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(t.id),
            child: Text(t.title),
          ),
      ],
    ),
  );
}

/// Pick which items to split out of [topic]. Returns the chosen item ids, or
/// `null` when cancelled.
Future<List<String>?> showSplitDialog(
  BuildContext context, {
  required Topic topic,
}) {
  final selected = <String>[];
  return showDialog<List<String>>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Split items into a new topic'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final item in topic.items)
                CheckboxListTile(
                  value: selected.contains(item.id),
                  title: Text(item.title),
                  dense: true,
                  onChanged: (checked) => setState(() {
                    if (checked ?? false) {
                      selected.add(item.id);
                    } else {
                      selected.remove(item.id);
                    }
                  }),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: selected.isEmpty
                ? null
                : () => Navigator.of(context).pop(List.of(selected)),
            child: const Text('Split'),
          ),
        ],
      ),
    ),
  );
}

/// Priority picker. Returns `null` on cancel; use [Priority?] result where a
/// cleared flag needs distinguishing from cancel via a sentinel.
Future<Object?> showPriorityDialog(BuildContext context, Priority? current) {
  return showDialog<Object?>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Priority'),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.of(context).pop(Priority.high),
          child: const Text('High'),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.of(context).pop(Priority.medium),
          child: const Text('Medium'),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.of(context).pop(Priority.low),
          child: const Text('Low'),
        ),
        if (current != null)
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(_cleared),
            child: const Text('Clear'),
          ),
      ],
    ),
  );
}

const _cleared = Object();

/// Confidence picker. Returns a value in 0..1 or [double.nan] to clear, or
/// null on cancel.
Future<double?> showConfidenceDialog(BuildContext context, double? current) {
  return showDialog<double>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Confidence'),
      children: [
        for (final option in const [
          ('High · 0.9', 0.9),
          ('Medium · 0.7', 0.7),
          ('Low · 0.5', 0.5),
          ('Very low · 0.3', 0.3),
        ])
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(option.$2),
            child: Text(option.$1),
          ),
        if (current != null)
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(double.nan),
            child: const Text('Clear'),
          ),
      ],
    ),
  );
}

/// Turns the priority dialog result into an actionable value.
({bool cleared, Priority? priority})? resolvePriority(
    Object? result, Priority? current) {
  if (identical(result, _cleared)) return (cleared: true, priority: current);
  if (result is Priority) return (cleared: false, priority: result);
  return null;
}
