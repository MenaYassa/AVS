import 'package:ai_knowledge_companion/data/local/database.dart';
import 'package:ai_knowledge_companion/data/local/local_data_source.dart';
import 'package:ai_knowledge_companion/data/search/search_data_sources.dart';
import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/search_result.dart';
import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

AppDatabase _memDb() => AppDatabase(NativeDatabase.memory());

SessionRow _session(
  String id, {
  String? title,
  String? summary,
  String? transcript,
  String status = 'ready',
}) =>
    SessionRow(
      id: id,
      userId: 'u1',
      title: title,
      summary: summary,
      cleanedTranscript: transcript,
      status: status,
      favorite: false,
      archived: false,
      deleted: false,
      pinned: false,
      createdAt: DateTime.utc(2026, 8, 6, 10),
      updatedAt: DateTime.utc(2026, 8, 6, 10),
    );

void main() {
  group('SearchDao.toFtsQuery', () {
    test('tokenizes, quotes and AND-joins with prefix wildcards', () {
      expect(SearchDao.toFtsQuery('hello world'), '"hello"* AND "world"*');
      expect(SearchDao.toFtsQuery('  spaced   out  '),
          '"spaced"* AND "out"*');
      expect(SearchDao.toFtsQuery(''), '');
      expect(SearchDao.toFtsQuery('   '), '');
    });

    test('neutralizes FTS query syntax', () {
      expect(SearchDao.toFtsQuery('a OR b'), '"a"* AND "OR"* AND "b"*');
      expect(SearchDao.toFtsQuery('"quoted"'), '"quoted"*');
      expect(SearchDao.toFtsQuery('a*b'), '"a*b"*');
    });
  });

  group('FTS index maintenance', () {
    late AppDatabase db;

    setUp(() => db = _memDb());
    tearDown(() => db.close());

    test('sessions, topics and items are all searchable', () async {
      await db.sessionsDao.insertSession(_session('s1',
          title: 'Standup notes', summary: 'Debounced the cache invalidation'));
      await db.into(db.topics).insert(TopicRow(
            id: 't1',
            sessionId: 's1',
            position: 0,
            title: 'Infra',
            description: '',
          ));
      await db.into(db.items).insert(ItemRow(
            id: 'i1',
            topicId: 't1',
            type: 'task',
            title: 'Ship the krakatoa release',
            position: 0,
            description: '',
          ));

      final titleHit = await db.searchDao.search('standup');
      expect(titleHit.single.sessionId, 's1');

      final itemHit = await db.searchDao.search('krakatoa');
      expect(itemHit.single.sessionId, 's1');
      expect(itemHit.single.snippet, contains('\u0001krakatoa\u0002'));
    });

    test('updating a session reindexes content', () async {
      await db.sessionsDao.insertSession(_session('s1', title: 'Old title'));
      expect(await db.searchDao.search('old'), hasLength(1));
      expect(await db.searchDao.search('new'), isEmpty);

      await db.sessionsDao.upsertSession(_session('s1', title: 'New title'));
      expect(await db.searchDao.search('old'), isEmpty);
      expect((await db.searchDao.search('new')).single.sessionId, 's1');
    });

    test('updating topics/items reindexes their session', () async {
      await db.sessionsDao.insertSession(_session('s1', title: 'Session'));
      await db.into(db.topics).insert(TopicRow(
            id: 't1',
            sessionId: 's1',
            position: 0,
            title: 'First',
            description: '',
          ));
      expect(await db.searchDao.search('first'), hasLength(1));

      await (db.update(db.topics)..where((t) => t.id.equals('t1')))
          .write(const TopicsCompanion(title: Value('Second')));
      expect(await db.searchDao.search('first'), isEmpty);
      expect(await db.searchDao.search('second'), hasLength(1));
    });

    test('deleting a session removes it from results', () async {
      await db.sessionsDao.insertSession(_session('s1', title: 'Doomed'));
      expect(await db.searchDao.search('doomed'), hasLength(1));

      await (db.delete(db.sessions)..where((t) => t.id.equals('s1'))).go();
      expect(await db.searchDao.search('doomed'), isEmpty);
    });

    test('soft-deleted sessions are excluded', () async {
      await db.sessionsDao.insertSession(
          _session('s1', title: 'Archived away', status: 'ready'));
      await (db.update(db.sessions)..where((t) => t.id.equals('s1')))
          .write(const SessionsCompanion(deleted: Value(true)));
      expect(await db.searchDao.search('archived'), isEmpty);
    });

    test('results are ranked by bm25 relevance', () async {
      await db.sessionsDao.insertSession(_session('s1', title: 'Qdrant'));
      await db.sessionsDao.insertSession(_session('s2',
          title: 'Qdrant', summary: 'Qdrant Qdrant Qdrant Qdrant Qdrant'));
      final hits = await db.searchDao.search('qdrant');
      expect(hits, hasLength(2));
      expect(hits.first.sessionId, 's2');
      expect(hits.first.rank < hits.last.rank, isTrue);
    });
  });

  group('SearchLocalDataSource', () {
    late AppDatabase db;
    late SearchLocalDataSource ds;

    setUp(() {
      db = _memDb();
      ds = SearchLocalDataSource(db);
    });
    tearDown(() => db.close());

    test('maps DAO hits to domain SearchResults', () async {
      await db.sessionsDao.insertSession(_session('s1', title: 'Treasure map'));
      final results = await ds.search('treasure');
      expect(results, hasLength(1));
      expect(results.single.sessionId, 's1');
      expect(results.single.status, SessionStatus.ready);
      expect(results.single.snippet, contains('\u0001Treasure\u0002'));
    });

    test('unknown status falls back to ready', () async {
      await db.sessionsDao.insertSession(
          _session('s1', title: 'Draft', status: 'transcribing'));
      final results = await ds.search('draft');
      expect(results.single.status, SessionStatus.transcribing);
    });
  });

  group('FallbackSearchRepository', () {
    test('local results win; remote is skipped', () async {
      final local = _StubRepo([
        const SearchResult(
          sessionId: 's1',
          title: 'Local hit',
          summary: null,
          status: SessionStatus.ready,
          rank: 1,
          snippet: null,
        ),
      ]);
      var remoteCalled = false;
      final remote = _StubRepo(const [], onSearch: () => remoteCalled = true);

      final repo = FallbackSearchRepository(local: local, remote: remote);
      final results = await repo.search('x');
      expect(results, hasLength(1));
      expect(remoteCalled, isFalse);
    });

    test('falls back to the cloud when local misses', () async {
      final repo = FallbackSearchRepository(
        local: _StubRepo(const []),
        remote: _StubRepo(const [
          SearchResult(
            sessionId: 's9',
            title: 'Cloud hit',
            summary: null,
            status: SessionStatus.ready,
            rank: 1,
            snippet: null,
          ),
        ]),
      );
      final results = await repo.search('x');
      expect(results.single.sessionId, 's9');
    });

    test('remote failure degrades to empty, not an error', () async {
      final repo = FallbackSearchRepository(
        local: _StubRepo(const []),
        remote: _ThrowingRepo(),
      );
      final results = await repo.search('x');
      expect(results, isEmpty);
    });

    test('NoopSearchRepository returns nothing', () async {
      expect(await const NoopSearchRepository().search('x'), isEmpty);
    });
  });
}

class _StubRepo implements SearchRepository {
  _StubRepo(this.results, {this.onSearch});

  final List<SearchResult> results;
  final void Function()? onSearch;

  @override
  Future<List<SearchResult>> search(String query) async {
    onSearch?.call();
    return results;
  }
}

class _ThrowingRepo implements SearchRepository {
  @override
  Future<List<SearchResult>> search(String query) async =>
      throw Exception('cloud down');
}
