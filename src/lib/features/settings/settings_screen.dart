import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../core/secure_storage/secure_store.dart';
import '../../domain/entities/enums.dart';
import '../../domain/entities/provider_setting.dart';
import '../../domain/repositories.dart';
import '../auth/auth_controller.dart';
import '../plugins/plugins_section.dart';
import 'intelligence_controller.dart';
import 'privacy_controller.dart';

/// Settings for AI providers (spec §18, §7; architecture §5.3).
final providerSettingsProvider = FutureProvider<List<ProviderSetting>>((ref) {
  return ref.watch(providerSettingsRepositoryProvider).getAll();
});

final providerSettingsControllerProvider =
    NotifierProvider<ProviderSettingsController, bool>(ProviderSettingsController.new);

class ProviderSettingsController extends Notifier<bool> {
  static const _uuid = Uuid();

  @override
  bool build() => false;

  Future<void> save(
    ProviderKind kind,
    String provider, {
    String? model,
    String? baseUrl,
    String? apiKey,
  }) async {
    final userId = ref.read(authControllerProvider).valueOrNull ?? 'local';
    final repo = ref.read(providerSettingsRepositoryProvider);
    final existing = await repo.getAll();
    final match = existing
        .where((s) => s.kind == kind && s.provider == provider)
        .firstOrNull;

    final setting = match?.copyWith(model: model, baseUrl: baseUrl) ??
        ProviderSetting(
          id: _uuid.v4(),
          userId: userId,
          kind: kind,
          provider: provider,
          model: model,
          baseUrl: baseUrl,
        );

    await repo.save(setting);
    if (apiKey != null && apiKey.isNotEmpty) {
      await ref.read(secureStoreProvider).write(SecureKeys.providerKey(setting.id), apiKey);
    }
    ref.invalidate(providerSettingsProvider);
    state = true;
  }

  Future<void> remove(String id) async {
    await ref.read(providerSettingsRepositoryProvider).delete(id);
    await ref.read(secureStoreProvider).delete(SecureKeys.providerKey(id));
    ref.invalidate(providerSettingsProvider);
  }
}

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(providerSettingsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          if (settings.hasValue) ...[
            _ProviderSection(
              title: 'Speech-to-Text',
              kind: ProviderKind.stt,
              defaultProviders: const ['openai_whisper', 'deepgram', 'custom'],
            ),
            _ProviderSection(
              title: 'LLM',
              kind: ProviderKind.llm,
              defaultProviders: const ['openai', 'anthropic', 'ollama', 'custom'],
            ),
          ] else if (settings.isLoading)
            const Center(child: Padding(
              padding: EdgeInsets.all(32),
              child: CircularProgressIndicator(),
            )),
          const Divider(),
          const _PrivacySection(),
          const Divider(),
          const _IntelligenceSection(),
          const Divider(),
          const PluginsSection(),
          const Divider(),
          const _AuthTile(),
        ],
      ),
    );
  }
}

class _ProviderSection extends ConsumerWidget {
  const _ProviderSection({
    required this.title,
    required this.kind,
    required this.defaultProviders,
  });

  final String title;
  final ProviderKind kind;
  final List<String> defaultProviders;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = ref.watch(providerSettingsProvider).value ?? const [];
    final rows = all.where((s) => s.kind == kind).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(title, style: Theme.of(context).textTheme.titleMedium),
        ),
        for (final p in defaultProviders)
          _ProviderRow(
            provider: p,
            kind: kind,
            setting: rows.where((s) => s.provider == p).firstOrNull,
          ),
        const Divider(),
      ],
    );
  }
}

class _ProviderRow extends ConsumerStatefulWidget {
  const _ProviderRow({
    required this.provider,
    required this.kind,
    required this.setting,
  });

  final String provider;
  final ProviderKind kind;
  final ProviderSetting? setting;

  @override
  ConsumerState<_ProviderRow> createState() => _ProviderRowState();
}

class _ProviderRowState extends ConsumerState<_ProviderRow> {
  final _model = TextEditingController();
  final _baseUrl = TextEditingController();
  final _apiKey = TextEditingController();

  @override
  void initState() {
    super.initState();
    _model.text = widget.setting?.model ?? '';
    _baseUrl.text = widget.setting?.baseUrl ?? '';
  }

  @override
  void dispose() {
    _model.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final configured = widget.setting?.enabled ?? false;
    return ExpansionTile(
      title: Text(widget.provider.replaceAll('_', ' ').toUpperCase()),
      subtitle: configured ? const Text('Configured') : const Text('Not configured'),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: [
              TextField(
                controller: _model,
                decoration: const InputDecoration(labelText: 'Model'),
              ),
              TextField(
                controller: _baseUrl,
                decoration: const InputDecoration(labelText: 'Base URL (optional)'),
              ),
              TextField(
                controller: _apiKey,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'API key (kept in secure storage)',
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: () => ref
                      .read(providerSettingsControllerProvider.notifier)
                      .save(
                        widget.kind,
                        widget.provider,
                        model: _model.text.isEmpty ? null : _model.text,
                        baseUrl: _baseUrl.text.isEmpty ? null : _baseUrl.text,
                        apiKey: _apiKey.text.isEmpty ? null : _apiKey.text,
                      ),
                  child: const Text('Save'),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ],
    );
  }
}

/// Privacy preferences (spec §18 Privacy, architecture §12).
class _PrivacySection extends ConsumerWidget {
  const _PrivacySection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final privacy = ref.watch(privacySettingsProvider);
    final deleteAudio =
        privacy.valueOrNull?.deleteAudioAfterProcessing ?? false;
    return SwitchListTile(
      title: const Text('Delete audio after processing'),
      subtitle: const Text(
        'Remove the raw recording once a session is analyzed. Transcripts '
        'and notes are kept.',
      ),
      value: deleteAudio,
      onChanged: (value) => ref
          .read(privacySettingsProvider.notifier)
          .setDeleteAudioAfterProcessing(value),
    );
  }
}

class _IntelligenceSection extends ConsumerWidget {
  const _IntelligenceSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final intelligence = ref.watch(intelligenceSettingsProvider);
    final enabled = intelligence.valueOrNull?.enableInsights ?? false;
    final memoryEnabled = intelligence.valueOrNull?.enableMemory ?? false;
    return Column(
      children: [
        SwitchListTile(
          title: const Text('Cross-session insights'),
          subtitle: const Text(
            'Surface topics and entities that recur across your sessions, '
            'each with links back to its source sessions. Opt-in; computed '
            'from this device\'s data only.',
          ),
          value: enabled,
          onChanged: (value) => ref
              .read(intelligenceSettingsProvider.notifier)
              .setEnableInsights(value),
        ),
        SwitchListTile(
          title: const Text('AI memory'),
          subtitle: const Text(
            'Answer follow-up questions using context from your other '
            'sessions, each with a source link so you can trace it. '
            'Opt-in; skipped per session in the session menu.',
          ),
          value: memoryEnabled,
          onChanged: (value) => ref
              .read(intelligenceSettingsProvider.notifier)
              .setEnableMemory(value),
        ),
      ],
    );
  }
}

class _AuthTile extends ConsumerWidget {
  const _AuthTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final userId = auth.valueOrNull;
    final isLoading = auth.isLoading;

    return ListTile(
      leading: const Icon(Icons.account_circle_outlined),
      title: Text(userId == null ? 'Account' : 'Signed in'),
      subtitle: Text(
        userId != null
            ? userId
            : (auth.hasError
                ? 'Sign-in failed. Tap to retry.'
                : 'Sign in to sync with Supabase cloud'),
        style: TextStyle(
          color: auth.hasError ? Colors.redAccent : null,
        ),
      ),
      trailing: isLoading
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : (userId == null
              ? FilledButton.tonal(
                  onPressed: () => context.push('/auth'),
                  child: const Text('Sign in'),
                )
              : OutlinedButton(
                  onPressed: () =>
                      ref.read(authControllerProvider.notifier).signOut(),
                  child: const Text('Sign out'),
                )),
      onTap: userId == null ? () => context.push('/auth') : null,
    );
  }
}
