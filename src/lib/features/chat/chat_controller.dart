/// Per-session AI chat controller (architecture §4.11, spec §17).
///
/// Drives the chat lifecycle per session: persists the user's question, builds
/// context, submits the engine chat job, streams progress, and persists the
/// grounded assistant answer (with citations + confidence) on success.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/logging/app_logger.dart';
import '../../domain/entities/chat_message.dart';
import '../../domain/entities/enums.dart';
import '../../domain/entities/job.dart';
import '../../domain/entities/session.dart';
import '../../domain/repositories.dart';
import '../auth/auth_controller.dart';
import '../memory/memory_context.dart';
import '../settings/intelligence_controller.dart';
import '../settings/memory_controller.dart';

/// User-visible phase of a chat exchange.
enum ChatPhase { idle, running, failed }

/// State for the chat controller.
class ChatState {
  const ChatState({
    this.phase = ChatPhase.idle,
    this.job,
    this.error,
    this.memorySources = const [],
  });

  final ChatPhase phase;
  final Job? job;
  final String? error;

  /// The related-session descriptors (source ids + titles) that rode into the
  /// last answer's prompt when AI memory was used (architecture §4.9).
  final List<Map<String, dynamic>> memorySources;

  bool get isRunning => phase == ChatPhase.running;

  ChatState copyWith({
    ChatPhase? phase,
    Job? job,
    String? error,
    List<Map<String, dynamic>>? memorySources,
    bool clearError = false,
  }) {
    return ChatState(
      phase: phase ?? this.phase,
      job: job ?? this.job,
      error: clearError ? null : (error ?? this.error),
      memorySources: memorySources ?? this.memorySources,
    );
  }
}

/// Per-session chat coordinator.
final chatControllerProvider =
    NotifierProvider.family<ChatController, ChatState, String>(
  ChatController.new,
);

/// Example questions shown when a chat has no messages yet (spec §17).
const List<String> kChatExamples = [
  'What decisions did I make?',
  'What tasks are still open?',
  'What ideas did I mention about EAG?',
  'Summarize only the technical discussion.',
];

/// The persisted message history for a session, oldest first.
final chatMessagesProvider =
    StreamProvider.family<List<ChatMessage>, String>((ref, sessionId) {
  return ref.watch(chatRepositoryProvider).watchMessages(sessionId);
});

class ChatController extends FamilyNotifier<ChatState, String> {
  StreamSubscription<Job>? _sub;

  @override
  ChatState build(String sessionId) {
    ref.onDispose(_stopStreaming);
    return const ChatState();
  }

  /// Builds the compact session context the engine chat prompt expects —
  /// the same canonical shape the command bus sends.
  Future<Map<String, dynamic>> _buildContext(Session session) async {
    final topicsJson = session.topics
        .map(
          (t) => {
            'title': t.title,
            'description': t.description,
            'items': t.items
                .map(
                  (i) => {
                    'title': i.title,
                    'description': i.description,
                    'type': i.type.name,
                  },
                )
                .toList(),
          },
        )
        .toList();

    final tagRows = await ref.read(tagRepositoryProvider).getTagsForSession(session.id);

    return {
      'session_id': session.id,
      'title': session.title,
      'summary': session.summary,
      'transcript': session.cleanedTranscript ?? session.originalTranscript,
      'language': session.language,
      'tags': tagRows.map((t) => {'name': t.name}).toList(),
      'entities': session.entities
          .map((e) => {'name': e.name, 'type': e.type.wireName})
          .toList(),
      'topics': topicsJson,
    };
  }

  /// Sends [question] to the session chat and streams the grounded answer.
  Future<void> ask(String question) async {
    final trimmed = question.trim();
    if (trimmed.isEmpty || state.isRunning) return;

    final session = await _session();
    if (session == null) {
      state = state.copyWith(phase: ChatPhase.failed, error: 'Session not found.');
      return;
    }

    String userId;
    try {
      userId = ref.read(authControllerProvider).valueOrNull ?? session.userId;
    } catch (_) {
      userId = session.userId;
    }

    // Persist the user message first so the conversation reads naturally while
    // the job runs.
    await ref.read(chatRepositoryProvider).addMessage(ChatMessage(
          id: const Uuid().v4(),
          sessionId: session.id,
          role: ChatRole.user,
          content: trimmed,
          createdAt: DateTime.now().toUtc(),
        ));

    state = state.copyWith(phase: ChatPhase.running, clearError: true);

    try {
      final context = await _buildContext(session);
      final memory = await _memoryFor(session);

      final job = await ref.read(engineGatewayProvider).createJob(
            userId: userId,
            kind: JobKind.chat,
            inputRef: null,
            options: {
              'question': trimmed,
              'context': context,
              'memory': memory,
              'stage': {'provider': 'placeholder'}, // TODO: use configured LLM
            },
          );

      await ref.read(jobProvider).insertJob(job);

      state = state.copyWith(
        phase: ChatPhase.running,
        job: job,
        memorySources: memory,
      );
      _subscribe(job);
    } on AppFailure catch (e) {
      state = state.copyWith(
        phase: ChatPhase.failed,
        error: 'Could not start chat: ${e.message}',
      );
    } catch (e, st) {
      Log.e('Failed to start chat', e, st);
      state = state.copyWith(
        phase: ChatPhase.failed,
        error: 'Could not start chat.',
      );
    }
  }

  /// Resolves the opt-in memory block for this session (architecture §4.9):
  /// empty when AI memory is off, the session opts out, or nothing is related.
  Future<List<Map<String, dynamic>>> _memoryFor(Session session) {
    final settings = ref.read(intelligenceSettingsProvider).valueOrNull;
    return memoryForSession(
      enableMemory: settings?.enableMemory ?? false,
      readSkip: () => ref.read(memorySkipProvider(session.id).future),
      readSessions: () => ref.read(databaseProvider).watchSessions().first,
      tagsFor: (id) => ref.read(tagRepositoryProvider).getTagsForSession(id),
      sessionId: session.id,
    );
  }

  void _subscribe(Job job) {
    _stopStreaming();
    final userId = ref.read(authControllerProvider).valueOrNull ?? job.userId;
    _sub = ref
        .read(engineGatewayProvider)
        .streamJob(userId, job.id)
        .listen(_onJob, onError: (Object e, StackTrace st) {
      Log.e('Chat stream failed', e, st);
      state = state.copyWith(
        phase: ChatPhase.failed,
        error: 'Lost connection to the engine.',
      );
    });
  }

  void _stopStreaming() {
    _sub?.cancel();
    _sub = null;
  }

  Future<void> _onJob(Job job) async {
    await ref.read(jobProvider).updateJob(job);

    state = state.copyWith(job: job, clearError: true);

    switch (job.status) {
      case JobStatus.succeeded:
        await _onSucceeded(job);
      case JobStatus.failed:
        await _onFailed(job);
      case JobStatus.cancelled:
        state = state.copyWith(phase: ChatPhase.idle);
      case JobStatus.queued:
      case JobStatus.running:
        break;
    }
  }

  Future<void> _onSucceeded(Job job) async {
    if (job.resultJson == null) {
      state = state.copyWith(
        phase: ChatPhase.failed,
        error: 'Chat succeeded but produced no answer.',
      );
      return;
    }
    final result = jsonDecode(job.resultJson!) as Map<String, dynamic>;
    final response = result['response'] as Map<String, dynamic>? ?? const {};
    final answer = response['answer'] as String? ?? '';
    if (answer.isEmpty) {
      state = state.copyWith(
        phase: ChatPhase.failed,
        error: 'Chat produced an empty answer.',
      );
      return;
    }

    await ref.read(chatRepositoryProvider).addMessage(ChatMessage(
          id: const Uuid().v4(),
          sessionId: arg,
          role: ChatRole.assistant,
          content: answer,
          citations:
              (response['citations'] as List<dynamic>? ?? const []).cast<String>(),
          confidence: (response['confidence'] as num?)?.toDouble(),
          promptVersions:
              (result['prompt_versions'] as Map<String, dynamic>?) ?? const {},
          createdAt: DateTime.now().toUtc(),
        ));

    state = state.copyWith(phase: ChatPhase.idle, job: job);
  }

  Future<void> _onFailed(Job job) async {
    final error = _jobErrorMessage(job);
    state = state.copyWith(
      phase: ChatPhase.failed,
      error: error ?? 'Chat failed.',
    );
  }

  Future<Session?> _session() => ref.read(databaseProvider).getSession(arg);

  String? _jobErrorMessage(Job job) {
    final raw = job.errorJson;
    if (raw == null) return null;
    try {
      final error = jsonDecode(raw) as Map<String, dynamic>;
      return error['message'] as String?;
    } catch (_) {
      return raw;
    }
  }
}
