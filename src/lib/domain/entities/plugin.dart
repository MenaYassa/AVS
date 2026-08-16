/// Plugin entities (architecture §4.11).
///
/// Mirrors `plugin.schema.json` (vendored to `data/contract/`): OAuth2
/// connection status per target, the authorization URL, and the push receipt.
library;

/// One plugin target's server-side connection status.
class PluginTargetStatus {
  const PluginTargetStatus({
    required this.kind,
    required this.displayName,
    required this.connected,
    required this.configured,
  });

  final String kind;
  final String displayName;
  final bool connected;
  final bool configured;

  factory PluginTargetStatus.fromJson(Map<String, dynamic> json) =>
      PluginTargetStatus(
        kind: json['kind'] as String,
        displayName: json['display_name'] as String,
        connected: json['connected'] as bool? ?? false,
        configured: json['configured'] as bool? ?? false,
      );
}

/// Response of `GET /api/v1/plugins/{kind}/auth-url`.
class PluginAuthUrl {
  const PluginAuthUrl({
    required this.kind,
    required this.displayName,
    required this.url,
    required this.state,
  });

  final String kind;
  final String displayName;
  final String url;
  final String state;

  factory PluginAuthUrl.fromJson(Map<String, dynamic> json) => PluginAuthUrl(
        kind: json['kind'] as String,
        displayName: json['display_name'] as String,
        url: json['url'] as String,
        state: json['state'] as String,
      );
}

/// Response of `POST /api/v1/plugins/{kind}/push` (architecture §4.11).
class PluginPushReceipt {
  const PluginPushReceipt({
    required this.kind,
    required this.ok,
    this.targetUrl,
    this.externalId,
    this.message,
  });

  final String kind;
  final bool ok;
  final String? targetUrl;
  final String? externalId;
  final String? message;

  factory PluginPushReceipt.fromJson(Map<String, dynamic> json) =>
      PluginPushReceipt(
        kind: json['kind'] as String,
        ok: json['ok'] as bool? ?? true,
        targetUrl: json['target_url'] as String?,
        externalId: json['external_id'] as String?,
        message: json['message'] as String?,
      );
}
