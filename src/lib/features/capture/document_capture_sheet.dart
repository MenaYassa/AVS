import 'package:flutter/material.dart';

import 'document_capture_controller.dart';

/// Bottom sheet for choosing what to import (architecture §4.12): images and
/// PDFs flow through OCR on the engine; emails and office/text documents flow
/// through the parser seam. Screenshots are images, so they ride the OCR path
/// too. The app only picks the file.
Future<DocumentKind?> showDocumentCaptureSheet(BuildContext context) {
  return showModalBottomSheet<DocumentKind>(
    context: context,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('Photo or image'),
              subtitle: const Text('OCR-extract text from a picture'),
              onTap: () => Navigator.of(context).pop(DocumentKind.image),
            ),
            ListTile(
              leading: const Icon(Icons.screenshot_outlined),
              title: const Text('Screenshot'),
              subtitle: const Text('OCR-extract text from a screen capture'),
              onTap: () => Navigator.of(context).pop(DocumentKind.screenshot),
            ),
            ListTile(
              leading: const Icon(Icons.picture_as_pdf_outlined),
              title: const Text('PDF document'),
              subtitle: const Text('OCR-extract text from a PDF'),
              onTap: () => Navigator.of(context).pop(DocumentKind.pdf),
            ),
            ListTile(
              leading: const Icon(Icons.mail_outline),
              title: const Text('Email file'),
              subtitle: const Text('Parse an .eml message'),
              onTap: () => Navigator.of(context).pop(DocumentKind.email),
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('Document'),
              subtitle: const Text('Parse a text/office document'),
              onTap: () => Navigator.of(context).pop(DocumentKind.document),
            ),
          ],
        ),
      ),
    ),
  );
}
