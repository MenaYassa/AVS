import 'dart:async';

import 'package:ai_knowledge_companion/core/secure_storage/secure_store.dart';
import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/provider_setting.dart';
import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:ai_knowledge_companion/features/settings/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeProviderSettings implements ProviderSettingsRepository {
  _FakeProviderSettings([List<ProviderSetting> initial = const []])
      : _items = List.of(initial);

  final List<ProviderSetting> _items;
  final List<ProviderSetting> saved = [];

  @override
  Future<List<ProviderSetting>> getAll() async => List.of(_items);

  @override
  Future<void> save(ProviderSetting setting) async {
    saved.add(setting);
    final i = _items.indexWhere((s) => s.id == setting.id);
    if (i >= 0) {
      _items[i] = setting;
    } else {
      _items.add(setting);
    }
  }

  @override
  Future<void> delete(String id) async {
    _items.removeWhere((s) => s.id == id);
  }
}

class _FakeSecureStore implements SecureStore {
  final Map<String, String> map = {};

  @override
  Future<void> write(String key, String value) async => map[key] = value;

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> delete(String key) async => map.remove(key);
}

class _FakeAuth implements AuthRepository {
  _FakeAuth(this._id);

  String? _id;
  final _controller = StreamController<String?>.broadcast();
  int signInCalls = 0;
  int signOutCalls = 0;

  @override
  String? get currentUserId => _id;

  @override
  Stream<String?> watchUserId() => _controller.stream;

  @override
  Future<void> signInWithGoogle() async {
    signInCalls++;
    _id = 'u1';
    _controller.add('u1');
  }

  @override
  Future<void> signOut() async {
    signOutCalls++;
    _id = null;
    _controller.add(null);
  }

  void dispose() => _controller.close();
}

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

Widget _app(List<Override> overrides) => ProviderScope(
      overrides: overrides,
      child: const MaterialApp(home: SettingsScreen()),
    );

void main() {
  testWidgets('settings lists provider sections and configuration state',
      (tester) async {
    final repo = _FakeProviderSettings([
      const ProviderSetting(
        id: 'w1',
        userId: 'u1',
        kind: ProviderKind.stt,
        provider: 'openai_whisper',
        model: 'whisper-1',
      ),
      const ProviderSetting(
        id: 'o1',
        userId: 'u1',
        kind: ProviderKind.llm,
        provider: 'ollama',
        model: 'llama3',
      ),
    ]);
    await tester.pumpWidget(_app([
      providerSettingsRepositoryProvider.overrideWithValue(repo),
      secureStoreProvider.overrideWithValue(_FakeSecureStore()),
      authRepositoryProvider.overrideWithValue(_FakeAuth(null)),
    ]));
    await tester.pumpAndSettle();

    expect(find.text('Speech-to-Text'), findsOneWidget);
    expect(find.text('LLM'), findsOneWidget);
    expect(find.text('OPENAI WHISPER'), findsOneWidget);
    expect(find.text('DEEPGRAM'), findsOneWidget);
    expect(find.text('OPENAI'), findsOneWidget);
    expect(find.text('Configured'), findsNWidgets(2));
    expect(find.text('Not configured'), findsNWidgets(5));
  });

  testWidgets('saving a provider persists it and stores the API key securely',
      (tester) async {
    final repo = _FakeProviderSettings();
    final secureStore = _FakeSecureStore();
    await tester.pumpWidget(_app([
      providerSettingsRepositoryProvider.overrideWithValue(repo),
      secureStoreProvider.overrideWithValue(secureStore),
      authRepositoryProvider.overrideWithValue(_FakeAuth(null)),
    ]));
    await tester.pumpAndSettle();

    await tester.tap(find.text('DEEPGRAM'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Model'), 'nova-2');
    await tester.enterText(
      find.widgetWithText(TextField, 'API key (kept in secure storage)'),
      'sk-test-123',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(repo.saved, hasLength(1));
    final setting = repo.saved.single;
    expect(setting.kind, ProviderKind.stt);
    expect(setting.provider, 'deepgram');
    expect(setting.model, 'nova-2');
    expect(setting.userId, 'local');
    expect(secureStore.map[SecureKeys.providerKey(setting.id)], 'sk-test-123');
    expect(find.text('Configured'), findsOneWidget);
    expect(find.text('Not configured'), findsNWidgets(6));
  });

  testWidgets('auth tile signs in and out through the auth repository',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final auth = _FakeAuth(null);
    addTearDown(auth.dispose);
    final repo = _FakeProviderSettings();
    await tester.pumpWidget(_app([
      providerSettingsRepositoryProvider.overrideWithValue(repo),
      secureStoreProvider.overrideWithValue(_FakeSecureStore()),
      authRepositoryProvider.overrideWithValue(auth),
    ]));
    await tester.pumpAndSettle();

    expect(find.text('Signed out'), findsOneWidget);
    expect(find.text('No cloud sync'), findsOneWidget);

    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(auth.signInCalls, 1);
    expect(find.text('Signed in'), findsOneWidget);
    expect(find.text('u1'), findsOneWidget);

    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(auth.signOutCalls, 1);
    expect(find.text('Signed out'), findsOneWidget);
  });

  testWidgets('privacy toggle persists delete-audio-after-processing',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final appSettings = _FakeAppSettings();
    await tester.pumpWidget(_app([
      providerSettingsRepositoryProvider.overrideWithValue(_FakeProviderSettings()),
      secureStoreProvider.overrideWithValue(_FakeSecureStore()),
      authRepositoryProvider.overrideWithValue(_FakeAuth('u1')),
      appSettingsRepositoryProvider.overrideWithValue(appSettings),
    ]));
    await tester.pumpAndSettle();

    expect(find.text('Delete audio after processing'), findsOneWidget);
    final tile =
        find.widgetWithText(SwitchListTile, 'Delete audio after processing');
    expect(tile, findsOneWidget);
    expect(tester.widget<SwitchListTile>(tile).value, false);

    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(appSettings.deleteAudio['u1'], true);
    expect(
      tester
          .widget<SwitchListTile>(find.widgetWithText(
              SwitchListTile, 'Delete audio after processing'))
          .value,
      true,
    );
  });
}
