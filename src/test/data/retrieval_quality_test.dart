import 'dart:math' as math;
import 'dart:math';

import 'package:ai_knowledge_companion/data/local/database.dart';
import 'package:ai_knowledge_companion/data/local/local_data_source.dart';
import 'package:ai_knowledge_companion/data/local/vector_codec.dart';
import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Retrieval-quality tests (§6.5): a deterministic token-overlap embedding
/// (mirrors the engine's `test_retrieval_quality.py` harness) lets us assert
/// that on-device `searchSimilar` returns genuinely related sessions first
/// across a realistic corpus, not just pairwise ordering.
List<double> _tokenOverlapEmbedding(String text, {int dims = 384}) {
  final vector = List<double>.filled(dims, 0.0);
  for (final token in text.toLowerCase().split(RegExp(r'\s+'))) {
    if (token.isEmpty) continue;
    var seed = 0;
    for (final unit in token.codeUnits) {
      seed = (seed * 31 + unit) & 0x7fffffff;
    }
    vector[seed % dims] += 1.0;
  }
  final norm = math.sqrt(vector.fold(0.0, (sum, v) => sum + v * v));
  if (norm == 0) return vector;
  return vector.map((v) => v / norm).toList(growable: false);
}

Session _session(String id, String title) => Session(
      id: id,
      userId: 'u1',
      title: title,
      summary: title,
      status: SessionStatus.ready,
      createdAt: DateTime.utc(2026, 8, 6, 10),
      updatedAt: DateTime.utc(2026, 8, 6, 10),
    );

void main() {
  late AppDatabase db;
  late EmbeddingLocalDataSource ds;
  late SessionLocalDataSource sessions;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    ds = EmbeddingLocalDataSource(db);
    sessions = SessionLocalDataSource(db);
  });
  tearDown(() => db.close());

  test('token-overlap embedding ranks related text higher', () {
    final query = _tokenOverlapEmbedding('release planning launch timeline');
    final related = _tokenOverlapEmbedding('planning the launch release');
    final unrelated = _tokenOverlapEmbedding('grocery eggs milk bread');
    expect(cosineSimilarity(query, related), greaterThan(0.5));
    expect(cosineSimilarity(query, unrelated), lessThan(0.1));
  });

  test('searchSimilar surfaces all related sessions in the top-k', () async {
    const queryText = 'release planning for the launch';

    const related = <String, String>{
      'r1': 'release planning and launch timeline',
      'r2': 'launch checklist for the release',
      'r3': 'quarterly plan for the release',
    };
    final corpus = <String, String>{...related};
    for (var i = 0; i < 20; i++) {
      corpus['d$i'] = 'recipe ingredients kitchen cooking session number $i';
    }

    final ids = corpus.keys.toList()..shuffle(Random(42));
    for (final id in ids) {
      await sessions.insertSession(_session(id, corpus[id]!));
      await ds.upsertSessionEmbedding(
        sessionId: id,
        scope: 'local',
        contentRef: '',
        vector: _tokenOverlapEmbedding(corpus[id]!),
      );
    }

    final query = _tokenOverlapEmbedding(queryText);
    final results = await ds.searchSimilar(
      query,
      limit: 5,
      threshold: 0.0,
    );

    // Precision@5: every genuinely-related session is in the top five and
    // ordered by descending similarity.
    final topIds = results.map((r) => r.sessionId).toList();
    expect(topIds.take(3).toSet(), related.keys.toSet());
    final relatedSims = results
        .where((r) => related.containsKey(r.sessionId))
        .map((r) => r.similarity)
        .toList();
    expect(relatedSims, List<double>.from(relatedSims)..sort((a, b) => b.compareTo(a)));
  });
}
