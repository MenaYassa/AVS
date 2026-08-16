import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../domain/entities/tag.dart';
import '../../domain/repositories.dart';
import '../auth/auth_controller.dart';

/// Tags attached to a session (architecture §5.3 `session_tags`).
final sessionTagsProvider =
    StreamProvider.autoDispose.family<List<Tag>, String>((ref, sessionId) {
  return ref.watch(tagRepositoryProvider).watchTagsForSession(sessionId);
});

/// Every tag the user owns (catalog for find-or-create + pickers).
final allTagsProvider =
    FutureProvider<List<Tag>>((ref) => ref.watch(tagRepositoryProvider).getAll());

final tagsControllerProvider = Provider<TagsController>((ref) {
  final userId = ref.watch(authControllerProvider).valueOrNull ?? 'local';
  return TagsController(ref.read(tagRepositoryProvider), userId);
});

class TagsController {
  TagsController(this._repo, this._userId);

  final TagRepository _repo;
  final String _userId;
  static const _uuid = Uuid();

  /// Returns the tag with [name] (case-insensitive), creating it if needed.
  Future<Tag> ensureTag(String name, {String? color}) async {
    final trimmed = name.trim();
    final normalized = trimmed.toLowerCase();
    final existing = await _repo.getAll();
    for (final tag in existing) {
      if (tag.name.toLowerCase() == normalized) {
        if (color != null && tag.color != color) {
          final updated = Tag(
            id: tag.id,
            userId: tag.userId,
            name: tag.name,
            color: color,
          );
          await _repo.save(updated);
          return updated;
        }
        return tag;
      }
    }
    final tag = Tag(
      id: _uuid.v4(),
      userId: _userId,
      name: trimmed,
      color: color,
    );
    await _repo.save(tag);
    return tag;
  }

  Future<void> attach(String sessionId, String tagId) =>
      _repo.attachTag(sessionId: sessionId, tagId: tagId);

  Future<void> detach(String sessionId, String tagId) =>
      _repo.detachTag(sessionId: sessionId, tagId: tagId);

  /// Attaches every tag by name; leaves existing session tags untouched.
  Future<void> attachByNames(String sessionId, List<String> names) async {
    for (final name in names) {
      final tag = await ensureTag(name);
      await _repo.attachTag(sessionId: sessionId, tagId: tag.id);
    }
  }
}
