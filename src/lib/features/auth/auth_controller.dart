import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/repositories.dart';

/// Auth state for the app (architecture §6).
///
/// Capture is never gated on auth: `userId == null` means signed-out but the
/// app still works locally (spec §4, architecture §6).
final authControllerProvider = AsyncNotifierProvider<AuthController, String?>(
  AuthController.new,
);

class AuthController extends AsyncNotifier<String?> {
  @override
  Future<String?> build() async {
    final repo = ref.watch(authRepositoryProvider);
    final initial = repo.currentUserId;
    repo.watchUserId().listen((id) {
      // Keep notifier state in sync with the underlying session stream.
      if (id != state.valueOrNull) {
        state = AsyncData(id);
      }
    });
    return initial;
  }

  Future<void> signInWithGoogle() async {
    state = const AsyncLoading();
    try {
      await ref.read(authRepositoryProvider).signInWithGoogle();
    } catch (e, st) {
      state = AsyncError(e, st);
    }
    // On success the watched stream updates state with the new user id.
  }

  Future<void> signOut() async {
    state = const AsyncLoading();
    try {
      await ref.read(authRepositoryProvider).signOut();
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }
}

/// Fallback when Supabase is not configured (local-only mode).
class NoopAuthRepository implements AuthRepository {
  const NoopAuthRepository();

  @override
  String? get currentUserId => null;

  @override
  Stream<String?> watchUserId() => const Stream.empty();

  @override
  Future<void> signInWithGoogle() async {
    throw const AuthFailure(
        'Cloud sync is not configured. Set SUPABASE_URL and sign in.');
  }

  @override
  Future<void> signOut() async {}
}
