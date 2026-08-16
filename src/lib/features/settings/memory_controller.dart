import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logging/app_logger.dart';
import '../../domain/repositories.dart';

/// Per-session "use AI memory" flag (architecture §4.9). A session can opt
/// out of memory context from the session detail menu; only meaningful while
/// AI memory is globally enabled (see [IntelligenceSettings.enableMemory]).
///
/// Async so the memory context provider can await the resolved flag instead
/// of racing the initial load (a sync notifier would flip state mid-build and
/// orphan the in-flight context future).
final memorySkipProvider =
    AsyncNotifierProvider.family<MemorySkipController, bool, String>(
  MemorySkipController.new,
);

class MemorySkipController extends FamilyAsyncNotifier<bool, String> {
  @override
  Future<bool> build(String sessionId) async {
    try {
      return await ref
          .read(appSettingsRepositoryProvider)
          .getMemorySkip(sessionId);
    } catch (e, st) {
      Log.e('Failed to load memory skip flag', e, st);
      return false;
    }
  }

  /// Flips the per-session flag; returns the new value.
  Future<bool> toggle() async {
    final next = !(state.valueOrNull ?? false);
    try {
      await ref.read(appSettingsRepositoryProvider).setMemorySkip(arg, next);
      state = AsyncData(next);
    } catch (e, st) {
      Log.e('Failed to save memory skip flag', e, st);
    }
    return state.valueOrNull ?? next;
  }
}
