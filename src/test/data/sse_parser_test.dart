import 'package:ai_knowledge_companion/data/engine/sse_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SseStreamDecoder', () {
    test('parses a single event frame', () {
      final decoder = SseStreamDecoder();
      final events = decoder.addChunk('event: job\ndata: {"a":1}\n\n');
      expect(events, hasLength(1));
      expect(events.single.event, 'job');
      expect(events.single.data, '{"a":1}');
    });

    test('defaults event name to message', () {
      final decoder = SseStreamDecoder();
      final events = decoder.addChunk('data: hello\n\n');
      expect(events.single.event, 'message');
      expect(events.single.data, 'hello');
    });

    test('joins multi-line data with newlines', () {
      final decoder = SseStreamDecoder();
      final events = decoder.addChunk('data: line1\ndata: line2\n\n');
      expect(events.single.data, 'line1\nline2');
    });

    test('ignores comments and keeps fields in order', () {
      final decoder = SseStreamDecoder();
      final events = decoder.addChunk(
          ': keep-alive\nevent: progress\ndata: {}\n\n');
      expect(events.single.event, 'progress');
      expect(events.single.data, '{}');
    });

    test('handles CRLF delimiters', () {
      final decoder = SseStreamDecoder();
      final events = decoder.addChunk('event: done\ndata: {}\r\n\r\n');
      expect(events.single.event, 'done');
      expect(events.single.data, '{}');
    });

    test('buffers frames split across chunks', () {
      final decoder = SseStreamDecoder();
      expect(decoder.addChunk('event: job\nda'), isEmpty);
      expect(decoder.addChunk('ta: {"a":1}\n\n'), hasLength(1));
      expect(decoder.addChunk('event: '), isEmpty);
      expect(decoder.addChunk('done\ndata: {}\n\n').single.event, 'done');
    });

    test('parses multiple frames from one chunk', () {
      final decoder = SseStreamDecoder();
      final events = decoder.addChunk(
          'event: job\ndata: {}\n\nevent: done\ndata: {}\n\n');
      expect(events.map((e) => e.event).toList(), ['job', 'done']);
    });
  });
}
