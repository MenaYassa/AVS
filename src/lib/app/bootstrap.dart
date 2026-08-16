import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/audio/audio_player.dart';
import '../../core/logging/app_logger.dart';
import '../../core/secure_storage/secure_store.dart';
import '../../data/engine/engine_client.dart';
import '../../data/local/database.dart';
import '../../data/local/local_data_source.dart';
import '../../data/remote/supabase_data_source.dart';
import '../../data/search/search_data_sources.dart';
import '../../data/search/semantic_search_data_sources.dart';
import '../../data/sync/sync_engine.dart';
import '../../domain/repositories.dart';
import '../../features/auth/auth_controller.dart';
import '../../features/playback/playback_controller.dart';
import '../../features/sync/sync_controller.dart';

/// Runtime configuration injected via `--dart-define` (architecture §8.3).
abstract final class AppConfig {
  static const engineBaseUrl = String.fromEnvironment(
    'ENGINE_BASE_URL',
    defaultValue: 'http://10.0.2.2:8080',
  );
  static const supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: '',
  );
  static const supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: '',
  );
  static const googleServerClientId = String.fromEnvironment(
    'GOOGLE_SERVER_CLIENT_ID',
    defaultValue: '',
  );
}

/// Wires infrastructure providers (architecture §3.2, §6). Overridable in tests.
abstract final class AppBootstrap {
  static bool supabaseInitialized = false;

  /// Initializes Supabase with secure-storage-backed auth session persistence.
  static Future<void> initSupabase() async {
    if (AppConfig.supabaseUrl.isEmpty || AppConfig.supabaseAnonKey.isEmpty) {
      Log.d('Supabase not configured — running in local-only mode.');
      return;
    }
    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      publishableKey: AppConfig.supabaseAnonKey,
      authOptions: FlutterAuthClientOptions(
        localStorage: FlutterSecureStorageSupabaseStorage(),
      ),
    );
    supabaseInitialized = true;
  }
}

/// Riverpod wiring. These overrides are applied at the app root so features
/// consume Domain interfaces, never concrete data sources (architecture §3.2).
final bootstrapOverrides = <Override>[
  secureStoreProvider.overrideWithValue(KeychainSecureStore()),
  databaseProvider.overrideWithValue(SessionLocalDataSource(_appDatabase)),
  jobProvider.overrideWithValue(JobLocalDataSource(_appDatabase)),
  editLogRepositoryProvider.overrideWithValue(
      EditLogLocalDataSource(_appDatabase)),
  conflictRepositoryProvider.overrideWithValue(
      SyncConflictLocalDataSource(_appDatabase)),
  versionRepositoryProvider.overrideWithValue(
      VersionLocalDataSource(_appDatabase)),
  providerSettingsRepositoryProvider.overrideWithValue(
      ProviderSettingsLocalDataSource(_appDatabase)),
  tagRepositoryProvider.overrideWithValue(TagLocalDataSource(_appDatabase)),
  graphRepositoryProvider.overrideWithValue(GraphLocalDataSource(_appDatabase)),
  draftRepositoryProvider.overrideWithValue(DraftLocalDataSource(_appDatabase)),
  chatRepositoryProvider.overrideWithValue(ChatLocalDataSource(_appDatabase)),
  appSettingsRepositoryProvider.overrideWithValue(
      AppSettingsLocalDataSource(_appDatabase)),
  sessionAudioPlayerProvider.overrideWith(
      (ref) => JustAudioSessionAudioPlayer()),
  searchRepositoryProvider.overrideWith((ref) {
    final local = SearchLocalDataSource(_appDatabase);
    final remote = AppBootstrap.supabaseInitialized
        ? SupabaseSearchDataSource(Supabase.instance.client)
        : const NoopSearchRepository();
    return FallbackSearchRepository(local: local, remote: remote);
  }),
  embeddingRepositoryProvider.overrideWith(
      (ref) => EmbeddingLocalDataSource(_appDatabase)),
  semanticSearchRepositoryProvider.overrideWith((ref) {
    return HybridSemanticSearchRepository(
      engine: ref.watch(engineGatewayProvider),
      embeddings: ref.watch(embeddingRepositoryProvider),
    );
  }),
  engineGatewayProvider.overrideWith(
    (ref) => EngineClient(baseUrl: AppConfig.engineBaseUrl),
  ),
  authRepositoryProvider.overrideWith((ref) {
    if (!AppBootstrap.supabaseInitialized) {
      return const NoopAuthRepository();
    }
    return SupabaseAuthRepository(Supabase.instance.client);
  }),
  syncProvider.overrideWith((ref) {
    if (!AppBootstrap.supabaseInitialized) {
      return const NoopSyncRepository();
    }
    return SupabaseSyncRepository(Supabase.instance.client);
  }),
  syncEngineProvider.overrideWith(
    (ref) => SyncEngine(db: _appDatabase, remote: ref.watch(syncProvider)),
  ),
];

final AppDatabase _appDatabase = AppDatabase.open();

/// Secure-storage-backed session persistence for supabase_flutter
/// (architecture §6: auth session in the platform keychain).
class FlutterSecureStorageSupabaseStorage extends LocalStorage {
  FlutterSecureStorageSupabaseStorage();

  final SecureStore _store = KeychainSecureStore();
  static const _sessionKey = 'supabase_session';

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> hasAccessToken() async =>
      await _store.read(_sessionKey) != null;

  @override
  Future<String?> accessToken() => _store.read(_sessionKey);

  @override
  Future<void> removePersistedSession() => _store.delete(_sessionKey);

  @override
  Future<void> persistSession(String persistSessionString) =>
      _store.write(_sessionKey, persistSessionString);
}
