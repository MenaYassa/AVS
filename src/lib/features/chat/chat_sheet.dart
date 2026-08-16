import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/entities/chat_message.dart';
import 'chat_controller.dart';

/// Per-session AI chat bottom sheet (architecture §4.11, spec §17).
///
/// Shows the message history for a session, example-question chips when the
/// conversation is empty, an inline answer progress row while the job runs,
/// and a message input. Answers surface their citations + confidence.
class ChatSheet extends ConsumerStatefulWidget {
  const ChatSheet({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<ChatSheet> createState() => _ChatSheetState();
}

class _ChatSheetState extends ConsumerState<ChatSheet> {
  final TextEditingController _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _ask(String question) async {
    _input.clear();
    await ref
        .read(chatControllerProvider(widget.sessionId).notifier)
        .ask(question);
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatControllerProvider(widget.sessionId));
    final messagesAsync = ref.watch(chatMessagesProvider(widget.sessionId));
    final messages = messagesAsync.valueOrNull ?? const <ChatMessage>[];

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Text('Ask about this session',
                    style: Theme.of(context).textTheme.titleLarge),
                const Spacer(),
                if (chat.isRunning)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (chat.memorySources.isNotEmpty)
            _MemorySources(sources: chat.memorySources),
          Flexible(
            child: messages.isEmpty
                ? _Examples(onTap: _ask, enabled: !chat.isRunning)
                : ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: messages.length,
                    itemBuilder: (context, index) =>
                        _MessageBubble(message: messages[index]),
                  ),
          ),
          if (chat.isRunning)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Text('Thinking…'),
                ],
              ),
            ),
          if (chat.error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                chat.error!,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.error),
              ),
            ),
          _Composer(
            enabled: !chat.isRunning,
            onSend: _ask,
            controller: _input,
          ),
        ],
      ),
    );
  }
}

/// Source sessions that contributed to the answer via AI memory: tappable,
/// provenance-linked chips (architecture §4.9).
class _MemorySources extends StatelessWidget {
  const _MemorySources({required this.sources});

  final List<Map<String, dynamic>> sources;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Used context from', style: theme.textTheme.labelSmall),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final source in sources)
                ActionChip(
                  avatar: const Icon(Icons.history, size: 16),
                  label: Text(
                    (source['title'] as String? ?? '(untitled session)')
                        .trim()
                        .isEmpty
                        ? '(untitled session)'
                        : source['title'] as String,
                    style: theme.textTheme.labelMedium,
                  ),
                  onPressed: () {
                    final id = source['session_id'] as String?;
                    if (id != null) {
                      context.push('/sessions/$id');
                    }
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Example-question chips, shown before the first message (spec §17).
class _Examples extends StatelessWidget {
  const _Examples({required this.onTap, required this.enabled});

  final ValueChanged<String> onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Try asking', style: theme.textTheme.labelSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final example in kChatExamples)
                ActionChip(
                  label: Text(example, style: theme.textTheme.labelMedium),
                  onPressed:
                      enabled ? () => onTap(example) : null,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One chat bubble: user questions align right, answers align left.
class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = message.isUser;
    final color = isUser
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.surfaceContainerHighest;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          Flexible(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 420),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    message.content,
                    style: theme.textTheme.bodyMedium,
                  ),
                  if (!isUser && message.citations.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      message.citations.join(' · '),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  if (!isUser && message.confidence != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      'Confidence ${(message.confidence! * 100).round()}%',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Message input row with a send button.
class _Composer extends StatelessWidget {
  const _Composer({
    required this.enabled,
    required this.onSend,
    required this.controller,
  });

  final bool enabled;
  final ValueChanged<String> onSend;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              enabled: enabled,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              decoration: const InputDecoration(
                hintText: 'Ask about this session…',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: enabled
                  ? (value) {
                      if (value.trim().isNotEmpty) onSend(value);
                    }
                  : null,
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            tooltip: 'Send',
            icon: const Icon(Icons.send),
            onPressed: enabled
                ? () {
                    if (controller.text.trim().isNotEmpty) {
                      onSend(controller.text);
                    }
                  }
                : null,
          ),
        ],
      ),
    );
  }
}
