import 'dart:convert';

/// One parsed Server-Sent Event (architecture §7.1).
///
/// The engine stream emits `job`, `progress`, typed terminal events
/// (`done` / `failed` / `cancelled`) and `heartbeat`.
class SseEvent {
  const SseEvent({required this.event, required this.data});

  /// Event name; defaults to `message` when the frame omits `event:`.
  final String event;

  /// Data payload with `data:` lines joined by newlines.
  final String data;
}

/// Incremental SSE frame decoder.
///
/// Server-sent events may be split across any network boundary, so chunks must
/// be buffered until a complete frame (`\n\n` or `\r\n\r\n`) is available.
/// Frames are kept in order; a partially received frame stays buffered for the
/// next chunk.
class SseStreamDecoder {
  final StringBuffer _buffer = StringBuffer();

  /// Feeds a decoded chunk and returns any complete frames inside it.
  List<SseEvent> addChunk(String chunk) {
    _buffer.write(chunk);
    final text = _buffer.toString();
    final events = <SseEvent>[];
    var start = 0;
    while (true) {
      final end = _frameEnd(text, start);
      if (end == -1) break;
      events.add(_parseFrame(text.substring(start, end)));
      start = end;
    }
    _buffer
      ..clear()
      ..write(text.substring(start));
    return events;
  }

  /// Index just past the next frame delimiter, or -1 when none exists yet.
  static int _frameEnd(String text, int start) {
    final nn = text.indexOf('\n\n', start);
    final rnrn = text.indexOf('\r\n\r\n', start);
    if (nn == -1 && rnrn == -1) return -1;
    if (rnrn == -1) return nn + 2;
    if (nn == -1) return rnrn + 4;
    return nn < rnrn ? nn + 2 : rnrn + 4;
  }

  static SseEvent _parseFrame(String frame) {
    var event = 'message';
    final dataLines = <String>[];
    for (final raw in const LineSplitter().convert(frame)) {
      final line = raw.isEmpty || raw.startsWith('\r') ? raw.trimRight() : raw;
      if (line.isEmpty) continue;
      if (line.startsWith(':')) continue; // comment/keep-alive
      final colon = line.indexOf(':');
      final field = colon == -1 ? line : line.substring(0, colon);
      var value = colon == -1 ? '' : line.substring(colon + 1);
      if (value.startsWith(' ')) value = value.substring(1);
      switch (field) {
        case 'event':
          event = value;
        case 'data':
          dataLines.add(value);
      }
    }
    return SseEvent(event: event, data: dataLines.join('\n'));
  }
}
