/// Plugins management UI (architecture §4.11, spec §23).
///
/// Lives inside the Settings screen. Connects/disconnects OAuth2 targets
/// (Notion, Slack) whose credentials are stored server-side, and shows the
/// connection status returned by the engine.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/plugin.dart';
import 'plugins_controller.dart';

class PluginsSection extends ConsumerStatefulWidget {
  const PluginsSection({super.key});

  @override
  ConsumerState<PluginsSection> createState() => _PluginsSectionState();
}

class _PluginsSectionState extends ConsumerState<PluginsSection> {
  Future<void> _connect(PluginTargetStatus target) async {
    final controller = ref.read(pluginsProvider.notifier);
    final PluginAuthUrl authUrl;
    try {
      authUrl = await controller.connect(target.kind);
    } on Exception catch (e) {
      if (mounted) _showSnack('Could not start connection: $e');
      return;
    }
    if (!mounted) return;

    final codeController = TextEditingController();
    final submitted = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Connect ${authUrl.displayName}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Open the link below in a browser, authorize, then paste the '
              'code from the redirect back here. Credentials stay on the '
              'engine.',
            ),
            const SizedBox(height: 12),
            SelectableText(
              authUrl.url,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            TextButton.icon(
              icon: const Icon(Icons.copy),
              label: const Text('Copy link'),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: authUrl.url));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Link copied')),
                  );
                }
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: codeController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Authorization code',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, codeController.text.trim()),
            child: const Text('Connect'),
          ),
        ],
      ),
    );

    if (submitted == null || submitted.isEmpty) return;
    try {
      await controller.exchangeToken(
        target.kind,
        code: submitted,
        state: authUrl.state,
      );
      if (mounted) _showSnack('${authUrl.displayName} connected');
    } on Exception catch (e) {
      if (mounted) _showSnack('Connection failed: $e');
    }
  }

  Future<void> _disconnect(PluginTargetStatus target) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Disconnect ${target.displayName}?'),
            content: const Text(
              'The stored access token will be revoked on the engine.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Disconnect'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    try {
      await ref.read(pluginsProvider.notifier).disconnect(target.kind);
      if (mounted) _showSnack('${target.displayName} disconnected');
    } on Exception catch (e) {
      if (mounted) _showSnack('Could not disconnect: $e');
    }
  }

  void _showSnack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    final statuses = ref.watch(pluginsProvider).valueOrNull ?? const [];
    final busy = ref.watch(pluginsProvider).isLoading;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            'Plugins',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Push AI command drafts to Notion or Slack. Credentials are '
            'stored server-side; the app never sees your tokens.',
            style: TextStyle(fontSize: 12),
          ),
        ),
        for (final target in statuses)
          ListTile(
            leading: _targetIcon(target.kind),
            title: Text(target.displayName),
            subtitle: Text(
              target.connected
                  ? 'Connected'
                  : target.configured
                      ? 'Not connected'
                      : 'Not configured on engine',
            ),
            trailing: busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : target.connected
                    ? TextButton(
                        onPressed: () => _disconnect(target),
                        child: const Text('Disconnect'),
                      )
                    : target.configured
                        ? FilledButton(
                            onPressed: () => _connect(target),
                            child: const Text('Connect'),
                          )
                        : null,
          ),
        if (statuses.isEmpty && !busy)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text('Sign in to the engine to manage plugins.'),
          ),
        const Divider(),
      ],
    );
  }

  Icon _targetIcon(String kind) {
    switch (kind) {
      case 'slack':
        return const Icon(Icons.forum_outlined);
      case 'notion':
      default:
        return const Icon(Icons.article_outlined);
    }
  }
}
