import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/sync/sync_engine.dart';
import '../../domain/entities/session.dart';
import '../../domain/entities/tag.dart';
import '../../domain/repositories.dart';

/// Sync engine over the local DB + remote repository (architecture §4.13).
final syncEngineProvider = Provider<SyncEngine>((ref) {
  throw UnimplementedError('SyncEngine provider must be overridden');
});

/// Drives push + pull. Auto-runs on sign-in and exposes `syncNow()`.
final syncControllerProvider =
    AsyncNotifierProvider<SyncController, SyncRunResult>(SyncController.new);

class SyncController extends AsyncNotifier<SyncRunResult> {
  /// True once the build-time pass has finished. `syncNow()` called while the
  /// controller is still initializing (e.g. a lazy `SyncOnResume` read) would
  /// otherwise start a second overlapping pass.
  bool _initialized = false;

  @override
  Future<SyncRunResult> build() async {
    _initialized = false;
    final auth = ref.watch(authRepositoryProvider);
    auth.watchUserId().listen((id) {
      if (id != null) syncNow();
    });
    final userId = auth.currentUserId;
    if (userId == null) {
      _initialized = true;
      return SyncRunResult.empty;
    }
    try {
      return await _run(userId);
    } finally {
      _initialized = true;
    }
  }

  Future<void> syncNow() async {
    final userId = ref.read(authRepositoryProvider).currentUserId;
    if (userId == null) return;
    if (!_initialized) return; // build() is already running the first pass.
    state = const AsyncLoading();
    state = await AsyncValue.guard(() => _run(userId));
  }

  Future<SyncRunResult> _run(String userId) async {
    final result = await ref.read(syncEngineProvider).sync(userId: userId);
    return result.copyWith(completedAt: DateTime.now());
  }
}

/// Fallback when Supabase is not configured (local-only mode). No-ops so the
/// engine stays wired without a cloud backend.
class NoopSyncRepository implements SyncRepository {
  const NoopSyncRepository();

  @override
  Future<void> deleteSession({
    required String userId,
    required String sessionId,
  }) async {}

  @override
  Future<List<Session>> pullChangedSessions({
    required String userId,
    required DateTime since,
  }) async => const [];

  @override
  Future<Session?> pullSession({
    required String userId,
    required String sessionId,
  }) async => null;

  @override
  Future<void> pushSession(Session session) async {}

  @override
  Future<void> uploadAudio(String sessionId, String localPath) async {}

  @override
  Future<void> pushTag(Tag tag) async {}

  @override
  Future<void> deleteTag({
    required String userId,
    required String tagId,
  }) async {}

  @override
  Future<void> pushSessionTag({
    required String sessionId,
    required String tagId,
  }) async {}

  @override
  Future<void> deleteSessionTag({
    required String sessionId,
    required String tagId,
  }) async {}

  @override
  Future<List<Tag>> pullTags(String userId) async => const [];

  @override
  Future<List<SessionTag>> pullSessionTags(String userId) async => const [];
}
