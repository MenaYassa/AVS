import 'package:ai_knowledge_companion/data/local/database.dart';
import 'package:ai_knowledge_companion/data/local/local_data_source.dart';
import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:ai_knowledge_companion/features/organization/organization_controller.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late SessionLocalDataSource sessions;
  late ProviderContainer container;
  late OrganizationController org;

  Session draft() => Session(
        id: 's1',
        userId: 'u1',
        status: SessionStatus.ready,
        title: 'Hello',
        createdAt: DateTime.utc(2026, 8, 6, 10),
        updatedAt: DateTime.utc(2026, 8, 6, 10),
      );

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    sessions = SessionLocalDataSource(db);
    await sessions.insertSession(draft());
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(sessions),
    ]);
    addTearDown(container.dispose);
    org = container.read(organizationControllerProvider);
  });

  tearDown(() => db.close());

  Future<Session> current() async => (await sessions.getSession('s1'))!;

  test('toggleFavorite flips favorite and bumps updatedAt', () async {
    await org.toggleFavorite(await current());

    final s = await current();
    expect(s.favorite, isTrue);
    expect(s.updatedAt, isNot(DateTime.utc(2026, 8, 6, 10)));
  });

  test('toggleArchive flips archived', () async {
    await org.toggleArchive(await current());
    expect((await current()).archived, isTrue);

    await org.toggleArchive(await current());
    expect((await current()).archived, isFalse);
  });

  test('togglePin flips pinned (schema v7)', () async {
    await org.togglePin(await current());
    expect((await current()).pinned, isTrue);
  });

  test('trash soft-deletes and clears archive; restore brings it back',
      () async {
    await org.toggleArchive(await current());
    await org.trash(await current());

    var s = await current();
    expect(s.deleted, isTrue);
    expect(s.archived, isFalse);

    await org.restore(await current());
    s = await current();
    expect(s.deleted, isFalse);
  });

  test('purge hard-deletes the session', () async {
    await org.purge(await current());
    expect(await sessions.getSession('s1'), isNull);
  });
}
