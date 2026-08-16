import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logging/app_logger.dart';
import '../../domain/repositories.dart';

/// Per-user privacy preferences (spec §18 Privacy, architecture §12).
class PrivacySettings {
  const PrivacySettings({this.deleteAudioAfterProcessing = false});

  /// "Delete audio after processing": removes the raw recording once its
  /// session finishes analysis.
  final bool deleteAudioAfterProcessing;

  PrivacySettings copyWith({bool? deleteAudioAfterProcessing}) =>
      PrivacySettings(
        deleteAudioAfterProcessing:
            deleteAudioAfterProcessing ?? this.deleteAudioAfterProcessing,
      );
}

final privacySettingsProvider =
    AsyncNotifierProvider<PrivacySettingsNotifier, PrivacySettings>(
  PrivacySettingsNotifier.new,
);

class PrivacySettingsNotifier extends AsyncNotifier<PrivacySettings> {
  @override
  Future<PrivacySettings> build() async {
    final userId = _userId();
    try {
      final deleteAudio = await ref
          .read(appSettingsRepositoryProvider)
          .getDeleteAudioAfterProcessing(userId);
      return PrivacySettings(deleteAudioAfterProcessing: deleteAudio);
    } catch (e, st) {
      // Default to off; the repository is overridable in tests.
      Log.e('Could not load privacy settings', e, st);
      return const PrivacySettings();
    }
  }

  String _userId() {
    try {
      return ref.read(authRepositoryProvider).currentUserId ?? 'local';
    } catch (_) {
      return 'local';
    }
  }

  Future<void> setDeleteAudioAfterProcessing(bool value) async {
    final userId = _userId();
    try {
      await ref
          .read(appSettingsRepositoryProvider)
          .setDeleteAudioAfterProcessing(userId, value);
      state = AsyncData(
        PrivacySettings(deleteAudioAfterProcessing: value),
      );
    } catch (e, st) {
      Log.e('Failed to save privacy setting', e, st);
      state = AsyncError(e, st);
    }
  }
}
