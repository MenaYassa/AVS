/// Plugin connection state (architecture §4.11).
///
/// Mirrors the engine's `plugin.schema.json` (vendored to `data/contract/`).
/// Credentials never leave the engine: the app only starts the OAuth flow,
/// exchanges the code, and triggers pushes.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/plugin.dart';
import '../../domain/repositories.dart';
import '../auth/auth_controller.dart';

/// OAuth redirect URI for plugin connections. The app has no registered deep
/// link yet, so the flow is out-of-band: the user opens the authorization URL
/// in a browser and pastes the `code` from the redirect back into the app.
const pluginOAuthRedirectUri = 'ai-knowledge-companion://oauth/callback';

/// Current state of every registered plugin target.
typedef PluginStatuses = AsyncValue<List<PluginTargetStatus>>;

final pluginsProvider =
    AsyncNotifierProvider<PluginsController, List<PluginTargetStatus>>(
        PluginsController.new);

class PluginsController extends AsyncNotifier<List<PluginTargetStatus>> {
  @override
  Future<List<PluginTargetStatus>> build() async {
    final userId = await ref.watch(authControllerProvider.future);
    if (userId == null) {
      return const <PluginTargetStatus>[];
    }
    return ref.read(engineGatewayProvider).listPlugins(userId);
  }

  String _userId() =>
      ref.read(authControllerProvider).valueOrNull ?? 'local';

  /// Starts OAuth2 for [kind]; returns the authorization URL the app shows the
  /// user. Does not change connection state (that happens on exchange).
  Future<PluginAuthUrl> connect(String kind) async {
    final url = await ref.read(engineGatewayProvider).pluginAuthUrl(
          _userId(),
          kind,
          redirectUri: pluginOAuthRedirectUri,
        );
    return url;
  }

  /// Exchanges the authorization code pasted by the user, then refreshes the
  /// status list.
  Future<void> exchangeToken(
    String kind, {
    required String code,
    required String state,
  }) async {
    await ref.read(engineGatewayProvider).exchangePluginToken(
          _userId(),
          kind,
          code: code,
          state: state,
          redirectUri: pluginOAuthRedirectUri,
        );
    await _reload();
  }

  /// Disconnects (revokes) a target's credentials, then refreshes.
  Future<void> disconnect(String kind) async {
    await ref.read(engineGatewayProvider).disconnectPlugin(_userId(), kind);
    await _reload();
  }

  /// Pushes a command draft to a connected target and returns the receipt.
  Future<PluginPushReceipt> pushDraft(
    String kind, {
    required Map<String, dynamic> draft,
    String? target,
  }) {
    return ref.read(engineGatewayProvider).pushDraft(
          _userId(),
          kind,
          draft: draft,
          target: target,
        );
  }

  Future<void> _reload() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(
      () => ref.read(engineGatewayProvider).listPlugins(_userId()),
    );
  }
}
