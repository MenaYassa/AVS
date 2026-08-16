import 'dart:convert';

import 'enums.dart';

/// User-configured AI provider settings (spec §7, §18).
///
/// Secrets (API keys) are never held on this entity — they are stored in
/// platform secure storage keyed by `providerId` (architecture §12).
class ProviderSetting {
  const ProviderSetting({
    required this.id,
    required this.userId,
    required this.kind,
    required this.provider,
    this.baseUrl,
    this.model,
    this.language,
    this.temperature,
    this.timeoutSec,
    this.enabled = true,
  });

  final String id;
  final String userId;
  final ProviderKind kind;

  /// Provider name, e.g. `openai`, `deepgram`, `ollama`, `custom`.
  final String provider;
  final String? baseUrl;
  final String? model;
  final String? language;
  final double? temperature;
  final int? timeoutSec;
  final bool enabled;

  ProviderSetting copyWith({bool? enabled, String? model, String? baseUrl}) {
    return ProviderSetting(
      id: id,
      userId: userId,
      kind: kind,
      provider: provider,
      baseUrl: baseUrl ?? this.baseUrl,
      model: model ?? this.model,
      language: language,
      temperature: temperature,
      timeoutSec: timeoutSec,
      enabled: enabled ?? this.enabled,
    );
  }

  String get configJson => jsonEncode({
        if (baseUrl != null) 'base_url': baseUrl,
        if (model != null) 'model': model,
        if (language != null) 'language': language,
        if (temperature != null) 'temperature': temperature,
        if (timeoutSec != null) 'timeout_sec': timeoutSec,
      });

  factory ProviderSetting.fromConfigJson(
    String id,
    String userId,
    ProviderKind kind,
    String provider,
    String configJson, {
    bool enabled = true,
  }) {
    final m = jsonDecode(configJson) as Map<String, dynamic>;
    return ProviderSetting(
      id: id,
      userId: userId,
      kind: kind,
      provider: provider,
      baseUrl: m['base_url'] as String?,
      model: m['model'] as String?,
      language: m['language'] as String?,
      temperature: (m['temperature'] as num?)?.toDouble(),
      timeoutSec: (m['timeout_sec'] as num?)?.toInt(),
      enabled: enabled,
    );
  }
}
