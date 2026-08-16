import 'dart:io';

import 'package:ai_knowledge_companion/data/remote/supabase_data_source.dart';
import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/graph.dart';
import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;

// Run against a live stack: `flutter test --dart-define=SUPABASE_URL=http://127.0.0.1:54321
// --dart-define=SUPABASE_ANON_KEY=<key> test/data/supabase_integration_test.dart`.
// Skipped by default so CI / plain `flutter test` stays hermetic.
// Stacks with email confirmations enabled (managed + self-hosted defaults) will
// not hand back a session from signup; pre-provision the two users via the
// GoTrue admin API and pass SUPABASE_TEST_EMAIL/PASSWORD and
// SUPABASE_TEST_EMAIL2/PASSWORD2 to sign in instead of signing up.
const _url = String.fromEnvironment('SUPABASE_URL');
const _anon = String.fromEnvironment('SUPABASE_ANON_KEY');
const _testEmail = String.fromEnvironment('SUPABASE_TEST_EMAIL');
const _testPassword = String.fromEnvironment('SUPABASE_TEST_PASSWORD');
const _testEmail2 = String.fromEnvironment('SUPABASE_TEST_EMAIL2');
const _testPassword2 = String.fromEnvironment('SUPABASE_TEST_PASSWORD2');
const _enabled = _url != '' && _anon != '';

Future<String> _authenticate(SupabaseClient client,
    {required String email, required String password}) async {
  final AuthResponse res;
  if ((_testEmail != '' && email == _testEmail) ||
      (_testEmail2 != '' && email == _testEmail2)) {
    res = await client.auth.signInWithPassword(email: email, password: password);
  } else {
    res = await client.auth.signUp(email: email, password: password);
  }
  return res.session!.user.id;
}

// Uses a bare `SupabaseClient` (not `Supabase.initialize`): the latter forces a
// SharedPreferences PKCE storage and the Flutter test binding blocks real HTTP.

void main() {
  group('Supabase sync integration (local stack)', () {
    late SupabaseSyncRepository alice;
    late SupabaseClient aliceClient;
    late String aliceId;
    late String sessionId;
    late String topicId;
    late String itemId;
    late String run;

    setUpAll(() async {
      if (!_enabled) return;
      final email = _testEmail != ''
          ? _testEmail
          : 'alice.${DateTime.now().millisecondsSinceEpoch}@example.com';
      aliceClient = SupabaseClient(
        _url,
        _anon,
        authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
      );
      aliceId = await _authenticate(aliceClient,
          email: email,
          password: _testPassword != '' ? _testPassword : 'password123');
      alice = SupabaseSyncRepository(aliceClient);
      // Unique ids per run so upserts never conflict with rows left by an
      // earlier run (RLS correctly forbids updating another user's row).
      run = '${DateTime.now().millisecondsSinceEpoch}';
      sessionId = 's-$run';
      topicId = 't-$run';
      itemId = 'i-$run';
    });

    test(
        'push + pull round-trips a full session tree through PostgREST',
        () async {
      await alice.pushSession(Session(
        id: sessionId,
        userId: aliceId,
        title: 'Planning',
        status: SessionStatus.ready,
        alternativeTitles: const ['Planning'],
        summary: 'A planning session',
        summaryConfidence: 0.9,
        language: 'en',
        createdAt: DateTime.utc(2026, 8, 6, 16),
        updatedAt: DateTime.utc(2026, 8, 6, 16),
        topics: [
          Topic(
            id: topicId,
            title: 'Benchmark',
            position: 0,
            confidence: 0.95,
            items: [
              Item(
                id: itemId,
                type: ItemType.task,
                title: 'Add caching',
                position: 0,
                priority: Priority.high,
                timestampSec: 1.5,
                confidence: 0.9,
              ),
            ],
          ),
        ],
        entities: [
          GraphEntity(
            id: 'e-$run',
            userId: aliceId,
            type: EntityType.person,
            name: 'Alice',
            canonicalName: 'Alice',
            aliases: const ['A'],
            confidence: 0.9,
          ),
        ],
        relationships: [
          GraphRelation(
            id: 'r-$run',
            userId: aliceId,
            sourceId: 'e-$run',
            targetId: 'e-$run',
            type: RelationType.discusses,
            sessionId: sessionId,
            weight: 1.0,
            confidence: 0.8,
          ),
        ],
      ));

      final pulled = await alice.pullChangedSessions(
        userId: aliceId,
        since: DateTime.utc(2026, 1, 1),
      );
      final session = pulled.singleWhere((s) => s.id == sessionId);
      expect(session.userId, aliceId);
      expect(session.title, 'Planning');
      expect(session.summaryConfidence, 0.9);
      expect(session.deleted, isFalse);
      expect(session.topics.single.title, 'Benchmark');
      expect(session.topics.single.items.single.title, 'Add caching');
      expect(session.topics.single.items.single.priority, Priority.high);
      expect(session.entities.single.name, 'Alice');
      expect(session.entities.single.type, EntityType.person);
      expect(session.entities.single.aliases, ['A']);
      expect(session.relationships.single.type, RelationType.discusses);
    });

    test('uploadAudio stores the engine-readable private bucket/object key',
        () async {
      final file = File('${Directory.systemTemp.path}/$sessionId.m4a');
      await file.writeAsBytes([0x00, 0x01, 0x02]);
      addTearDown(() => file.delete());

      await alice.uploadAudio(sessionId, file.path);

      final stored = await aliceClient.storage
          .from('sessions')
          .download('$aliceId/$sessionId.m4a');
      expect(stored, [0x00, 0x01, 0x02]);
    });

    test('tombstone deletes via RLS update, visible on the next pull',
        () async {
      await alice.deleteSession(userId: aliceId, sessionId: sessionId);

      final pulled = await alice.pullChangedSessions(
        userId: aliceId,
        since: DateTime.utc(2026, 1, 1),
      );
      final session = pulled.singleWhere((s) => s.id == sessionId);
      expect(session.deleted, isTrue);
    });

    test('a second user cannot see the first user session (RLS)', () async {
      final bob = SupabaseClient(
        _url,
        _anon,
        authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
      );
      final bobEmail = _testEmail2 != ''
          ? _testEmail2
          : 'bob.${DateTime.now().millisecondsSinceEpoch}@example.com';
      final bobId = await _authenticate(bob,
          email: bobEmail,
          password: _testPassword2 != '' ? _testPassword2 : 'password123');

      final bobPulls = await SupabaseSyncRepository(bob).pullChangedSessions(
        userId: bobId,
        since: DateTime.utc(2026, 1, 1),
      );
      expect(bobPulls.where((s) => s.id == sessionId), isEmpty);
    });
  }, skip: !_enabled);
}
