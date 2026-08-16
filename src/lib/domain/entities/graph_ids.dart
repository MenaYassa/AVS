/// Deterministic graph identifiers (architecture §4.8).
///
/// The engine derives entity/relationship ids with uuid5 over a fixed
/// namespace (see `engine/app/stages/assembly.py`). The app replicates that
/// scheme so a human-added entity gets the same id the engine would assign to
/// the same name — real-world identity is preserved across sessions and across
/// engine re-runs.
library;

import 'dart:convert';
import 'dart:typed_data';

const String _entityNamespace = '4a1e5f99-4d0a-6e3f-bc2d-2b3c4d5e6f70';
const String _relationshipNamespace = '5b2f60aa-5e1b-7f40-cd3e-3c4d5e6f7081';

/// Node id for [name], stable across sessions and engine re-runs.
String graphEntityId(String name) => _uuid5(_entityNamespace, name);

/// Per-session edge id: the same real-world edge in every session gets its own
/// row, so the id is derived from the session too.
String graphRelationshipId({
  required String sessionId,
  required String sourceId,
  required String targetId,
  required String type,
}) =>
    _uuid5(
      _relationshipNamespace,
      '$sessionId|$sourceId|$targetId|$type',
    );

String _uuid5(String namespace, String name) {
  final nsBytes = _hexToBytes(namespace.replaceAll('-', ''));
  final digest = sha1([...nsBytes, ...utf8.encode(name)]);
  final bytes = Uint8List.fromList(digest.sublist(0, 16));
  bytes[6] = (bytes[6] & 0x0f) | 0x50; // version 5
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
}

Uint8List _hexToBytes(String hex) => Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);

/// SHA-1 (RFC 3174). Minimal self-contained implementation so the helper stays
/// hermetic (no extra dependency).
List<int> sha1(List<int> message) {
  final h0 = 0x67452301;
  final h1 = 0xEFCDAB89;
  final h2 = 0x98BADCFE;
  final h3 = 0x10325476;
  final h4 = 0xC3D2E1F0;

  final ml = message.length * 8;
  final padded = [...message, 0x80];
  while (padded.length % 64 != 56) {
    padded.add(0);
  }
  final len = ByteData(8)..setUint64(0, ml, Endian.big);
  padded.addAll(len.buffer.asUint8List());

  var a = h0, b = h1, c = h2, d = h3, e = h4;
  final w = List<int>.filled(80, 0);
  for (var chunkStart = 0; chunkStart < padded.length; chunkStart += 64) {
    for (var i = 0; i < 16; i++) {
      final offset = chunkStart + i * 4;
      w[i] = (padded[offset] << 24) |
          (padded[offset + 1] << 16) |
          (padded[offset + 2] << 8) |
          padded[offset + 3];
    }
    for (var i = 16; i < 80; i++) {
      final n = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16];
      w[i] = ((n << 1) | (n >>> 31)) & 0xFFFFFFFF;
    }

    var ta = a, tb = b, tc = c, td = d, te = e;
    for (var i = 0; i < 80; i++) {
      var f = 0;
      var k = 0;
      if (i < 20) {
        f = (tb & tc) | ((~tb) & td);
        k = 0x5A827999;
      } else if (i < 40) {
        f = tb ^ tc ^ td;
        k = 0x6ED9EBA1;
      } else if (i < 60) {
        f = (tb & tc) | (tb & td) | (tc & td);
        k = 0x8F1BBCDC;
      } else {
        f = tb ^ tc ^ td;
        k = 0xCA62C1D6;
      }
      final temp = (_rotl32(ta, 5) & 0xFFFFFFFF) + f + te + k + w[i];
      te = td;
      td = tc;
      tc = _rotl32(tb, 30) & 0xFFFFFFFF;
      tb = ta;
      ta = temp & 0xFFFFFFFF;
    }
    a = (a + ta) & 0xFFFFFFFF;
    b = (b + tb) & 0xFFFFFFFF;
    c = (c + tc) & 0xFFFFFFFF;
    d = (d + td) & 0xFFFFFFFF;
    e = (e + te) & 0xFFFFFFFF;
  }

  final out = ByteData(20);
  out.setUint32(0, a, Endian.big);
  out.setUint32(4, b, Endian.big);
  out.setUint32(8, c, Endian.big);
  out.setUint32(12, d, Endian.big);
  out.setUint32(16, e, Endian.big);
  return out.buffer.asUint8List();
}

int _rotl32(int value, int shift) =>
    ((value << shift) & 0xFFFFFFFF) | (value >>> (32 - shift));
