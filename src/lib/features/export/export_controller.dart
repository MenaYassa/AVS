/// Export controller that generates session files and triggers sharing
/// (spec §20). Pure function for now; no persistent state.
library;

import 'dart:io';

import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:ai_knowledge_companion/domain/entities/tag.dart';
import 'package:ai_knowledge_companion/features/export/session_exporter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

/// Export controller that holds no state; just a collection of methods.
class ExportController {
  ExportController(this.ref);

  final Ref ref;

  /// Exports a session in the requested format and shares it via the OS.
  Future<void> export(
    BuildContext context, {
    required Session session,
    required List<Tag> tags,
    required ExportFormat format,
  }) async {
    try {
      final origin = _sharePositionOrigin(context);
      final exporter = SessionExporter(session, tags);
      final File file;
      switch (format) {
        case ExportFormat.markdown:
          file = await exporter.toMarkdown();
          break;
        case ExportFormat.json:
          file = await exporter.toJson();
          break;
        case ExportFormat.plainText:
          file = await exporter.toPlainText();
          break;
        case ExportFormat.pdf:
          file = await exporter.toPdf();
          break;
      }

      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'Session: ${session.title ?? '(Untitled)'}',
        sharePositionOrigin: origin,
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    }
  }

  /// Copies the session's Markdown to the clipboard.
  Future<void> copyToClipboard({
    required Session session,
    required List<Tag> tags,
  }) async {
    final exporter = SessionExporter(session, tags);
    final file = await exporter.toMarkdown();
    final content = await file.readAsString();
    await Clipboard.setData(ClipboardData(text: content));
  }

  Rect? _sharePositionOrigin(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }
}

final exportControllerProvider = Provider<ExportController>((ref) {
  return ExportController(ref);
});
