import 'package:ai_knowledge_companion/data/local/database.dart';
import 'package:ai_knowledge_companion/data/local/local_data_source.dart';
import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:ai_knowledge_companion/features/auth/auth_controller.dart';
import 'package:ai_knowledge_companion/features/tags/tags_controller.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _SignedInAuth implements AuthRepository {
  @override
  String? get currentUserId => 'u1';

  @override
  Stream<String?> watchUserId() => const Stream.empty();

  @override
  Future<void> signInWithGoogle() async {}

  @override
  Future<void> signOut() async {}
}

void main() {
  late AppDatabase db;
  late TagLocalDataSource tags;
  late ProviderContainer container;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tags = TagLocalDataSource(db);
    container = ProviderContainer(overrides: [
      tagRepositoryProvider.overrideWithValue(tags),
      authRepositoryProvider.overrideWithValue(_SignedInAuth()),
    ]);
    addTearDown(container.dispose);
  });

  tearDown(() => db.close());

  Future<TagsController> ctrl() async {
    // The controller reads the auth state at creation; wait for it to resolve
    // so signed-in ownership is captured (not the 'local' fallback).
    await container.read(authControllerProvider.future);
    return container.read(tagsControllerProvider);
  }

  test('ensureTag creates a tag owned by the signed-in user', () async {
    final tag = await (await ctrl()).ensureTag('  Ideas  ');

    expect(tag.name, 'Ideas');
    expect(tag.userId, 'u1');
    expect(await tags.getAll(), hasLength(1));
  });

  test('ensureTag is case-insensitive and reuses the existing tag', () async {
    final first = await (await ctrl()).ensureTag('Ideas', color: '#FF0000');
    final second = await (await ctrl()).ensureTag('ideas');

    expect(second.id, first.id);
    expect(await tags.getAll(), hasLength(1));
  });

  test('ensureTag updates the color when one is supplied', () async {
    await (await ctrl()).ensureTag('Ideas');
    final updated = await (await ctrl()).ensureTag('IDEAS', color: '#00FF00');

    expect(updated.color, '#00FF00');
    expect((await tags.getAll()).single.color, '#00FF00');
  });

  test('attachByNames attaches every tag by name', () async {
    final session = Session(
      id: 's1',
      userId: 'u1',
      status: SessionStatus.ready,
      createdAt: DateTime.utc(2026, 8, 6, 10),
      updatedAt: DateTime.utc(2026, 8, 6, 10),
    );
    await SessionLocalDataSource(db).insertSession(session);

    await (await ctrl()).attachByNames('s1', ['Planning', 'ideas', 'Planning']);

    final attached = await tags.getTagsForSession('s1');
    expect(attached.map((t) => t.name).toSet(), {'Planning', 'ideas'});
  });

  test('detach removes a tag from the session', () async {
    final tag = await (await ctrl()).ensureTag('Ideas');
    await SessionLocalDataSource(db).insertSession(Session(
      id: 's1',
      userId: 'u1',
      status: SessionStatus.ready,
      createdAt: DateTime.utc(2026, 8, 6, 10),
      updatedAt: DateTime.utc(2026, 8, 6, 10),
    ));
    await (await ctrl()).attach('s1', tag.id);

    await (await ctrl()).detach('s1', tag.id);
    expect(await tags.getTagsForSession('s1'), isEmpty);
  });
}
