import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/document/document_picker.dart';
import '../../core/logging/app_logger.dart';
import '../../domain/entities/session.dart';
import '../../domain/repositories.dart';
import '../../domain/usecases/manage_sessions.dart';
import '../analysis/analysis_controller.dart';
import '../auth/auth_controller.dart';
import '../recording/recording_controller.dart';

/// Which document type the user imports (architecture §4.12 universal input).
/// Images and screenshots are OCR-backed (screenshots ride the image path);
/// PDFs are OCR-backed; emails and office/text documents are parser-backed on
/// the engine.
enum DocumentKind { image, screenshot, pdf, email, document }

/// Mime types the engine's document parser accepts (§4.12). Mirrors
/// `DOCUMENT_MIME_TYPES` in `engine/app/inputs/base.py`.
const _documentMimes = <String, String>{
  'txt': 'text/plain',
  'md': 'text/markdown',
  'html': 'text/html',
  'rtf': 'application/rtf',
  'docx':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'odt': 'application/vnd.oasis.opendocument.text',
  'csv': 'text/csv',
  'json': 'application/json',
  'xml': 'application/xml',
};

/// Overridable document picker (device-gated; tests inject a fake).
final documentPickerProvider = Provider<DocumentPicker>(
  (ref) => FilePickerDocumentPicker(),
);

class DocumentCaptureState {
  const DocumentCaptureState({this.importing = false, this.error});

  final bool importing;
  final String? error;

  DocumentCaptureState copyWith({bool? importing, String? error}) {
    return DocumentCaptureState(
      importing: importing ?? this.importing,
      error: error ?? this.error,
    );
  }
}

/// Imports an image/PDF/email/document into a session and kicks off analysis:
/// pick the file, copy it into the app documents directory (stable blob path,
/// same place recordings live), create a session starting at `uploading`, and
/// submit an `analyze` job with the matching `input_kind`. Returns the created
/// session so the caller can navigate to it, or null when the user cancels or
/// the file format is unsupported.
final documentCaptureControllerProvider =
    NotifierProvider<DocumentCaptureController, DocumentCaptureState>(
  DocumentCaptureController.new,
);

class DocumentCaptureController extends Notifier<DocumentCaptureState> {
  @override
  DocumentCaptureState build() => const DocumentCaptureState();

  Future<Session?> capture(DocumentKind kind) async {
    if (state.importing) return null;
    state = const DocumentCaptureState(importing: true);
    try {
      final picker = ref.read(documentPickerProvider);
      final picked = switch (kind) {
        DocumentKind.image || DocumentKind.screenshot => await picker.pickImage(),
        DocumentKind.pdf => await picker.pickPdf(),
        DocumentKind.email => await picker.pickEmail(),
        DocumentKind.document => await picker.pickDocument(),
      };
      if (picked == null) {
        // User cancelled — reset without an error.
        state = const DocumentCaptureState();
        return null;
      }

      final mimeType = _mime(kind, picked.split('.').last.toLowerCase());
      if (mimeType == null) {
        state = const DocumentCaptureState(
          error: 'Unsupported document format.',
        );
        return null;
      }

      final userId = ref.read(authControllerProvider).valueOrNull;
      final dir = await ref.read(recordingOutputDirectoryProvider);
      final ext = picked.split('.').last.toLowerCase();
      final session = await StartDocumentSession(ref.read(databaseProvider))(
        userId: userId,
        documentPath: picked,
      );
      final copied = '${dir.path}/${session.id}.$ext';
      await File(picked).copy(copied);
      await ref.read(databaseProvider).updateSession(
            session.copyWith(audioPath: copied),
          );

      // Fail-safe: any setup error surfaces in the analysis controller as a
      // retryable failure rather than propagating.
      unawaited(
        ref
            .read(analysisControllerProvider(session.id).notifier)
            .analyzeDocument(copied,
                inputKind: _inputKind(kind), mimeType: mimeType),
      );

      state = const DocumentCaptureState();
      return session;
    } catch (e, st) {
      Log.e('Failed to import document', e, st);
      state = const DocumentCaptureState(error: 'Could not import the document.');
      return null;
    }
  }

  String _inputKind(DocumentKind kind) => switch (kind) {
        DocumentKind.image => 'image',
        DocumentKind.screenshot => 'screenshot',
        DocumentKind.pdf => 'pdf',
        DocumentKind.email => 'email',
        DocumentKind.document => 'document',
      };

  /// Returns null when the extension has no engine-supported mime type, so the
  /// caller can reject the file before creating a doomed session.
  String? _mime(DocumentKind kind, String ext) {
    return switch (kind) {
      DocumentKind.pdf => 'application/pdf',
      DocumentKind.email => 'message/rfc822',
      DocumentKind.document => _documentMimes[ext],
      DocumentKind.image ||
      DocumentKind.screenshot =>
        switch (ext) {
          'jpg' || 'jpeg' => 'image/jpeg',
          'png' => 'image/png',
          'gif' => 'image/gif',
          'webp' => 'image/webp',
          'heic' => 'image/heic',
          'bmp' => 'image/bmp',
          _ => 'image/*',
        },
    };
  }
}
