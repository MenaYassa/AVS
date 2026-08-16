import 'enums.dart';

/// A ranked full-text search hit (architecture §5.3). [snippet] is the FTS5
/// excerpt around the best match with the matched terms wrapped in `\x01`/
/// `\x02` markers, so the UI can highlight exactly what matched.
class SearchResult {
  const SearchResult({
    required this.sessionId,
    required this.title,
    required this.summary,
    required this.status,
    required this.rank,
    required this.snippet,
  });

  final String sessionId;
  final String? title;
  final String? summary;
  final SessionStatus status;
  final double rank;
  final String? snippet;
}
