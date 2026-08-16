import 'dart:async';

import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:ai_knowledge_companion/features/settings/privacy_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAppSettings implements AppSettingsRepository {
  final Map<String, bool> deleteAudio = {};
  final Map<String, bool> insights = {};
  final Map<String, bool> memory = {};

  @override
  Future<bool> getDeleteAudioAfterProcessing(String userId) async =>
      deleteAudio[userId] ?? false;

  @override
  Future<void> setDeleteAudioAfterProcessing(String userId, bool value) async {
    deleteAudio[userId] = value;
  }

  @override
  Future<bool> getEnableInsights(String userId) async => insights[userId] ?? false;

  @override
  Future<void> setEnableInsights(String userId, bool value) async {
    insights[userId] = value;
  }

  @override
  Future<bool> getEnableMemory(String userId) async => memory[userId] ?? false;

  @override
  Future<void> setEnableMemory(String userId, bool value) async {
    memory[userId] = value;
  }

  @override
  Future<bool> getMemorySkip(String sessionId) async => false;

  @override
  Future<void> setMemorySkip(String sessionId, bool value) async {}
}

class _SignedInAuth implements AuthRepository {
  _SignedInAuth(this._id);

  final String? _id;
  final _controller = StreamController<String?>.broadcast();

  @override
  String? get currentUserId => _id;

  @override
  Stream<String?> watchUserId() => _controller.stream;

  @override
  Future<void> signInWithGoogle() async {}

  @override
  Future<void> signOut() async {}
}

void main() {
  test('defaults to delete-audio off and scopes storage to the user', () async {
    final settings = _FakeAppSettings();
    final container = ProviderContainer(overrides: [
      appSettingsRepositoryProvider.overrideWithValue(settings),
      authRepositoryProvider.overrideWithValue(_SignedInAuth('u1')),
    ]);
    addTearDown(container.dispose);

    await container.read(privacySettingsProvider.future);
    expect(
      container.read(privacySettingsProvider).valueOrNull!.deleteAudioAfterProcessing,
      false,
    );
  });

  test('toggling the setting persists it per user and updates state',
      () async {
    final settings = _FakeAppSettings();
    final container = ProviderContainer(overrides: [
      appSettingsRepositoryProvider.overrideWithValue(settings),
      authRepositoryProvider.overrideWithValue(_SignedInAuth('u1')),
    ]);
    addTearDown(container.dispose);

    await container.read(privacySettingsProvider.notifier)
        .setDeleteAudioAfterProcessing(true);

    expect(settings.deleteAudio['u1'], true);
    expect(
      container.read(privacySettingsProvider).valueOrNull!.deleteAudioAfterProcessing,
      true);
    expect(settings.deleteAudio.containsKey('u2'), false);

    await container.read(privacySettingsProvider.notifier)
        .setDeleteAudioAfterProcessing(false);
    expect(settings.deleteAudio['u1'], false);
  });

  test('a previously stored true value is loaded on startup', () async {
    final settings = _FakeAppSettings()..deleteAudio['u1'] = true;
    final container = ProviderContainer(overrides: [
      appSettingsRepositoryProvider.overrideWithValue(settings),
      authRepositoryProvider.overrideWithValue(_SignedInAuth('u1')),
    ]);
    addTearDown(container.dispose);

    await container.read(privacySettingsProvider.future);
    expect(
      container.read(privacySettingsProvider).valueOrNull!.deleteAudioAfterProcessing,
      true,
    );
  });

  test('a signed-out user falls back to the local scope', () async {
    final settings = _FakeAppSettings();
    final container = ProviderContainer(overrides: [
      appSettingsRepositoryProvider.overrideWithValue(settings),
      authRepositoryProvider.overrideWithValue(_SignedInAuth(null)),
    ]);
    addTearDown(container.dispose);

    await container.read(privacySettingsProvider.notifier)
        .setDeleteAudioAfterProcessing(true);

    expect(settings.deleteAudio['local'], true);
  });
}
