import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../domain/repositories.dart';

/// Wraps platform keychain/keystore access (architecture §12).
///
/// Used for auth sessions and user-configured custom provider API keys.
/// Never store non-secret data here.
class KeychainSecureStore implements SecureStore {
  KeychainSecureStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  final FlutterSecureStorage _storage;

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Well-known keys.
abstract final class SecureKeys {
  static const authSession = 'auth_session';
  static const customProviderKeyPrefix = 'provider_key_';

  static String providerKey(String providerId) =>
      '$customProviderKeyPrefix$providerId';
}
