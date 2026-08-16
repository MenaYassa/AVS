import 'package:ai_knowledge_companion/data/local/database.dart';
import 'package:ai_knowledge_companion/data/local/local_data_source.dart';
import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:ai_knowledge_companion/domain/usecases/delete_session_audio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('DeleteSessionAudio clears audioPath via updateSession', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final sessions = SessionLocalDataSource(db);
    await sessions.insertSession(Session(
      id: 's1',
      userId: 'u1',
      status: SessionStatus.ready,
      audioPath: '/tmp/s1.m4a',
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    ));

    final before = (await sessions.getSession('s1'))!;
    expect(before.audioPath, '/tmp/s1.m4a');

    await DeleteSessionAudio(sessions)(before);

    final after = (await sessions.getSession('s1'))!;
    expect(after.audioPath, isNull);
    await db.close();
  });
}
