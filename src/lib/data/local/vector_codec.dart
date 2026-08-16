import 'dart:math' as math;
import 'dart:typed_data';

/// Float32 vector codec + cosine similarity for on-device semantic search
/// (architecture §5.3: drift `embeddings.vector` blob column).
///
/// The engine embeds text with sentence-transformers (384 dims,
/// all-MiniLM-L6-v2); vectors are persisted as little-endian float32 bytes
/// and ranked in Dart (approved deviation from sqlite-vec: see Roadmap §6.1).

Uint8List encodeFloat32(List<double> values) {
  final data = ByteData(values.length * 4);
  for (var i = 0; i < values.length; i++) {
    data.setFloat32(i * 4, values[i], Endian.little);
  }
  return data.buffer.asUint8List();
}

List<double> decodeFloat32(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final count = bytes.length ~/ 4;
  return List<double>.generate(
    count,
    (i) => data.getFloat32(i * 4, Endian.little),
    growable: false,
  );
}

/// Cosine similarity in [0, 1]. Zero vectors and length mismatches return 0.
double cosineSimilarity(List<double> a, List<double> b) {
  if (a.length != b.length || a.isEmpty) return 0;
  var dot = 0.0;
  var normA = 0.0;
  var normB = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  if (normA == 0 || normB == 0) return 0;
  return dot / math.sqrt(normA * normB);
}

/// Encodes [text] as a stable pseudo-embedding for tests and offline fallback
/// (deterministic hash-bucket projection). Not used for real retrieval.
List<double> fakeEmbedding(String text, {int dimensions = 384}) {
  var seed = 0;
  for (final unit in text.codeUnits) {
    seed = (seed * 31 + unit) & 0x7fffffff;
  }
  return List<double>.generate(
    dimensions,
    (i) => ((seed >> (i % 24)) & 0xff) / 255.0 - 0.5,
    growable: false,
  );
}
