/// Session export service (spec §20).
///
/// Exports a session to Markdown, JSON, plain text, or PDF. Each format is
/// self-contained and includes the session's title, summary, transcript, topics,
/// items, tags, and entities. PDF uses the `pdf` package; other formats are
/// plain text/JSON.
library;

import 'dart:convert';
import 'dart:io';

import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../domain/entities/enums.dart';
import '../../domain/entities/session.dart';
import '../../domain/entities/tag.dart';

/// Export format options (spec §20).
enum ExportFormat { markdown, json, plainText, pdf }

extension ExportFormatLabel on ExportFormat {
  String get label {
    switch (this) {
      case ExportFormat.markdown:
        return 'Markdown';
      case ExportFormat.json:
        return 'JSON';
      case ExportFormat.plainText:
        return 'Plain Text';
      case ExportFormat.pdf:
        return 'PDF';
    }
  }

  String get subtitle {
    switch (this) {
      case ExportFormat.markdown:
        return 'Best for notes apps';
      case ExportFormat.json:
        return 'Machine-readable canonical form';
      case ExportFormat.plainText:
        return 'Simple text outline';
      case ExportFormat.pdf:
        return 'Formatted document';
    }
  }
}

/// Exports a session to various formats. Each method returns a File path
/// in the app's temporary directory; callers can share/save/delete as needed.
class SessionExporter {
  SessionExporter(this.session, this.tags);

  final Session session;
  final List<Tag> tags;

  /// Export as Markdown with frontmatter (title, date, tags) and hierarchical
  /// topics/items structure.
  Future<File> toMarkdown() async {
    final buffer = StringBuffer();
    buffer.writeln('# ${session.title ?? "(Untitled Session)"}');
    buffer.writeln();
    
    if (session.createdAt != null) {
      final date = DateFormat.yMMMMd().add_jm().format(session.createdAt!.toLocal());
      buffer.writeln('**Created:** $date');
      buffer.writeln();
    }

    if (tags.isNotEmpty) {
      buffer.writeln('**Tags:** ${tags.map((t) => t.name).join(", ")}');
      buffer.writeln();
    }

    if (session.summary != null && session.summary!.isNotEmpty) {
      buffer.writeln('## Summary');
      buffer.writeln();
      buffer.writeln(session.summary);
      buffer.writeln();
    }

    if (session.topics.isNotEmpty) {
      buffer.writeln('## Topics');
      buffer.writeln();
      for (final topic in session.topics) {
        buffer.writeln('### ${topic.title}');
        if (topic.description.isNotEmpty) {
          buffer.writeln();
          buffer.writeln(topic.description);
        }
        buffer.writeln();
        for (final item in topic.items) {
          final icon = _itemIcon(item.type);
          buffer.writeln('- **$icon ${item.title}**');
          if (item.description.isNotEmpty) {
            buffer.writeln('  ${item.description}');
          }
        }
        buffer.writeln();
      }
    }

    final transcript = session.cleanedTranscript ?? session.originalTranscript;
    if (transcript != null && transcript.isNotEmpty) {
      buffer.writeln('## Transcript');
      buffer.writeln();
      buffer.writeln(transcript);
      buffer.writeln();
    }

    if (session.entities.isNotEmpty) {
      buffer.writeln('## Entities');
      buffer.writeln();
      for (final entity in session.entities) {
        buffer.writeln('- ${entity.name} (${entity.type.name})');
      }
      buffer.writeln();
    }

    return _writeTemp('${_safeFilename()}.md', buffer.toString());
  }

  /// Export as JSON (the canonical session schema from the engine contract).
  Future<File> toJson() async {
    final json = session.toCanonicalJson();
    json['tags'] = tags.map((t) => {'name': t.name}).toList();
    final content = const JsonEncoder.withIndent('  ').convert(json);
    return _writeTemp('${_safeFilename()}.json', content);
  }

  /// Export as plain text: title, summary, topics as a flat outline, transcript.
  Future<File> toPlainText() async {
    final buffer = StringBuffer();
    buffer.writeln(session.title ?? '(Untitled Session)');
    buffer.writeln('=' * (session.title?.length ?? 19));
    buffer.writeln();

    if (session.createdAt != null) {
      final date = DateFormat.yMMMMd().add_jm().format(session.createdAt!.toLocal());
      buffer.writeln('Created: $date');
      buffer.writeln();
    }

    if (tags.isNotEmpty) {
      buffer.writeln('Tags: ${tags.map((t) => t.name).join(", ")}');
      buffer.writeln();
    }

    if (session.summary != null && session.summary!.isNotEmpty) {
      buffer.writeln('SUMMARY');
      buffer.writeln('-------');
      buffer.writeln(session.summary);
      buffer.writeln();
    }

    if (session.topics.isNotEmpty) {
      buffer.writeln('TOPICS');
      buffer.writeln('------');
      for (final topic in session.topics) {
        buffer.writeln();
        buffer.writeln(topic.title);
        if (topic.description.isNotEmpty) {
          buffer.writeln('  ${topic.description}');
        }
        for (final item in topic.items) {
          buffer.writeln('  • ${item.title}');
          if (item.description.isNotEmpty) {
            buffer.writeln('    ${item.description}');
          }
        }
      }
      buffer.writeln();
    }

    final transcript = session.cleanedTranscript ?? session.originalTranscript;
    if (transcript != null && transcript.isNotEmpty) {
      buffer.writeln('TRANSCRIPT');
      buffer.writeln('----------');
      buffer.writeln(transcript);
      buffer.writeln();
    }

    if (session.entities.isNotEmpty) {
      buffer.writeln('ENTITIES');
      buffer.writeln('--------');
      for (final entity in session.entities) {
        buffer.writeln('• ${entity.name} (${entity.type.name})');
      }
    }

    return _writeTemp('${_safeFilename()}.txt', buffer.toString());
  }

  /// Export as PDF: title page, summary, topics with items, transcript appendix.
  Future<File> toPdf() async {
    final pdf = pw.Document();

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        build: (context) => [
          pw.Header(
            level: 0,
            child: pw.Text(
              session.title ?? '(Untitled Session)',
              style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold),
            ),
          ),
          if (session.createdAt != null)
            pw.Text(
              'Created: ${DateFormat.yMMMMd().add_jm().format(session.createdAt!.toLocal())}',
              style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700),
            ),
          if (tags.isNotEmpty)
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 4),
              child: pw.Text(
                'Tags: ${tags.map((t) => t.name).join(", ")}',
                style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700),
              ),
            ),
          pw.SizedBox(height: 20),
          if (session.summary != null && session.summary!.isNotEmpty) ...[
            pw.Header(level: 1, text: 'Summary'),
            pw.Paragraph(text: session.summary!),
            pw.SizedBox(height: 16),
          ],
          if (session.topics.isNotEmpty) ...[
            pw.Header(level: 1, text: 'Topics'),
            for (final topic in session.topics) ...[
              pw.Header(level: 2, text: topic.title),
              if (topic.description.isNotEmpty)
                pw.Paragraph(text: topic.description),
              pw.SizedBox(height: 8),
              for (final item in topic.items)
                pw.Bullet(
                  text: item.title,
                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                ),
              pw.SizedBox(height: 12),
            ],
          ],
          if (session.cleanedTranscript != null || session.originalTranscript != null) ...[
            pw.Header(level: 1, text: 'Transcript'),
            pw.Paragraph(
              text: session.cleanedTranscript ?? session.originalTranscript!,
              style: const pw.TextStyle(fontSize: 10),
            ),
          ],
          if (session.entities.isNotEmpty) ...[
            pw.SizedBox(height: 16),
            pw.Header(level: 1, text: 'Entities'),
            for (final entity in session.entities)
              pw.Bullet(text: '${entity.name} (${entity.type.name})'),
          ],
        ],
      ),
    );

    final bytes = await pdf.save();
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/${_safeFilename()}.pdf');
    await file.writeAsBytes(bytes);
    return file;
  }

  String _itemIcon(ItemType type) {
    switch (type) {
      case ItemType.task:
        return '☐';
      case ItemType.decision:
        return '✓';
      case ItemType.question:
        return '?';
      case ItemType.idea:
        return '💡';
      default:
        return '•';
    }
  }

  String _safeFilename() {
    final title = session.title ?? 'session';
    return title.replaceAll(RegExp(r'[^\w\s-]'), '').replaceAll(RegExp(r'\s+'), '_');
  }

  Future<File> _writeTemp(String filename, String content) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$filename');
    await file.writeAsString(content);
    return file;
  }
}
