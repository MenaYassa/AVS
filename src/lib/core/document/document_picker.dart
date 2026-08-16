import 'package:file_picker/file_picker.dart';

/// Swappable document-picking seam (architecture §4.12): images, PDFs, emails
/// and office/text documents enter through picker entry points, then the
/// shared pipeline preprocesses them (OCR for images/PDFs, parsers for
/// emails/documents). Tests inject a fake; the real picker is device-gated.
abstract class DocumentPicker {
  Future<String?> pickImage();

  Future<String?> pickPdf();

  Future<String?> pickEmail();

  Future<String?> pickDocument();
}

/// Real picker backed by `file_picker`. Returns the picked file's local path,
/// or null when the user cancels or the picker is unavailable.
class FilePickerDocumentPicker implements DocumentPicker {
  @override
  Future<String?> pickImage() async {
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.image);
      return result?.files.single.path;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> pickPdf() async {
    return _pickCustom(const ['pdf']);
  }

  @override
  Future<String?> pickEmail() async {
    return _pickCustom(const ['eml']);
  }

  @override
  Future<String?> pickDocument() async {
    return _pickCustom(const [
      'txt',
      'md',
      'html',
      'rtf',
      'docx',
      'odt',
      'csv',
      'json',
      'xml',
    ]);
  }

  Future<String?> _pickCustom(List<String> extensions) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: extensions,
      );
      return result?.files.single.path;
    } catch (_) {
      return null;
    }
  }
}
