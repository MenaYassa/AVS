import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logging/app_logger.dart';
import '../../domain/repositories.dart';

/// Opt-in AI intelligence preferences (architecture §4.9, §12).
///
/// Cross-session intelligence and AI memory are both off by default: nothing
/// leaves the device until the user enables them.
class IntelligenceSettings {
  const IntelligenceSettings({
    this.enableInsights = false,
    this.enableMemory = false,
  });

  /// "Cross-session insights": when on, the app ships compact session
  /// descriptors to the engine so it can compute insight statements
  /// (e.g. "You've discussed X in N sessions") with provenance links.
  final bool enableInsights;

  /// "AI memory": when on, the app ships a compact, token-budgeted block of
  /// related-session context (titles, summaries, open tasks, source-tagged)
  /// with analysis and chat jobs so answers can reason across sessions.
  final bool enableMemory;

  IntelligenceSettings copyWith({
    bool? enableInsights,
    bool? enableMemory,
  }) =>
      IntelligenceSettings(
        enableInsights: enableInsights ?? this.enableInsights,
        enableMemory: enableMemory ?? this.enableMemory,
      );
}

final intelligenceSettingsProvider =
    AsyncNotifierProvider<IntelligenceSettingsNotifier, IntelligenceSettings>(
  IntelligenceSettingsNotifier.new,
);

class IntelligenceSettingsNotifier extends AsyncNotifier<IntelligenceSettings> {
  @override
  Future<IntelligenceSettings> build() async {
    final userId = _userId();
    try {
      final repo = ref.read(appSettingsRepositoryProvider);
      final enableInsights = await repo.getEnableInsights(userId);
      final enableMemory = await repo.getEnableMemory(userId);
      return IntelligenceSettings(
        enableInsights: enableInsights,
        enableMemory: enableMemory,
      );
    } catch (e, st) {
      // Default to off; the repository is overridable in tests.
      Log.e('Could not load intelligence settings', e, st);
      return const IntelligenceSettings();
    }
  }

  String _userId() {
    try {
      return ref.read(authRepositoryProvider).currentUserId ?? 'local';
    } catch (_) {
      return 'local';
    }
  }

  Future<void> setEnableInsights(bool value) async {
    final userId = _userId();
    try {
      await ref
          .read(appSettingsRepositoryProvider)
          .setEnableInsights(userId, value);
      state = AsyncData(
        (state.valueOrNull ?? const IntelligenceSettings())
            .copyWith(enableInsights: value),
      );
    } catch (e, st) {
      Log.e('Failed to save intelligence setting', e, st);
      state = AsyncError(e, st);
    }
  }

  Future<void> setEnableMemory(bool value) async {
    final userId = _userId();
    try {
      await ref
          .read(appSettingsRepositoryProvider)
          .setEnableMemory(userId, value);
      state = AsyncData(
        (state.valueOrNull ?? const IntelligenceSettings())
            .copyWith(enableMemory: value),
      );
    } catch (e, st) {
      Log.e('Failed to save intelligence setting', e, st);
      state = AsyncError(e, st);
    }
  }
}
