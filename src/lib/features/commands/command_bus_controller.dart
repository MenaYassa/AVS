/// Command bus controller (architecture §4.11).
///
/// Drives the AI command lifecycle per session: builds context, submits the
/// engine job, streams progress, and persists the resulting Draft.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/logging/app_logger.dart';
import '../../domain/entities/command_draft.dart';
import '../../domain/entities/enums.dart';
import '../../domain/entities/job.dart';
import '../../domain/entities/session.dart';
import '../../domain/repositories.dart';
import '../auth/auth_controller.dart';

/// User-visible phase of a command job.
enum CommandBusPhase { idle, submitting, running, succeeded, failed }

/// State for the command bus controller.
class CommandBusState {
  const CommandBusState({
    this.phase = CommandBusPhase.idle,
    this.job,
    this.error,
    this.lastDraftId,
  });

  final CommandBusPhase phase;
  final Job? job;
  final String? error;
  final String? lastDraftId; // id of the most recently created draft

  bool get isProcessing =>
      phase == CommandBusPhase.submitting || phase == CommandBusPhase.running;

  CommandBusState copyWith({
    CommandBusPhase? phase,
    Job? job,
    String? error,
    String? lastDraftId,
    bool clearError = false,
  }) {
    return CommandBusState(
      phase: phase ?? this.phase,
      job: job ?? this.job,
      error: clearError ? null : (error ?? this.error),
      lastDraftId: lastDraftId ?? this.lastDraftId,
    );
  }
}

/// Per-session command bus coordinator.
final commandBusControllerProvider =
    NotifierProvider.family<CommandBusController, CommandBusState, String>(
  CommandBusController.new,
);

class CommandBusController extends FamilyNotifier<CommandBusState, String> {
  StreamSubscription<Job>? _sub;

  @override
  CommandBusState build(String sessionId) {
    ref.onDispose(_stopStreaming);
    return const CommandBusState();
  }

  /// Builds the compact session context the engine command prompt expects.
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

  /// Submits an AI command for the current session.
  Future<void> runCommand(String commandName) async {
    if (state.isProcessing) return;

    final session = await _session();
    if (session == null) {
      state = state.copyWith(
        phase: CommandBusPhase.failed,
        error: 'Session not found.',
      );
      return;
    }

    String userId;
    try {
      userId = ref.read(authControllerProvider).valueOrNull ?? session.userId;
    } catch (_) {
      userId = session.userId;
    }

    state = state.copyWith(phase: CommandBusPhase.submitting, clearError: true);

    try {
      final context = await _buildContext(session);

      final job = await ref.read(engineGatewayProvider).createJob(
            userId: userId,
            kind: JobKind.command,
            inputRef: null,
            options: {
              'command': commandName,
              'context': context,
              'stage': {'provider': 'placeholder'}, // TODO: use configured LLM
            },
          );

      await ref.read(jobProvider).insertJob(job);

      state = state.copyWith(phase: CommandBusPhase.running, job: job);
      _subscribe(job);
    } on AppFailure catch (e) {
      state = state.copyWith(
        phase: CommandBusPhase.failed,
        error: 'Could not start command: ${e.message}',
      );
    } catch (e, st) {
      Log.e('Failed to start command', e, st);
      state = state.copyWith(
        phase: CommandBusPhase.failed,
        error: 'Could not start command.',
      );
    }
  }

  void _subscribe(Job job) {
    _stopStreaming();
    final userId = ref.read(authControllerProvider).valueOrNull ?? job.userId;
    _sub = ref
        .read(engineGatewayProvider)
        .streamJob(userId, job.id)
        .listen(_onJob, onError: (Object e, StackTrace st) {
      Log.e('Command stream failed', e, st);
      state = state.copyWith(
        phase: CommandBusPhase.failed,
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
        await _onCancelled(job);
      case JobStatus.queued:
      case JobStatus.running:
        break;
    }
  }

  Future<void> _onSucceeded(Job job) async {
    if (job.resultJson == null) {
      state = state.copyWith(
        phase: CommandBusPhase.failed,
        error: 'Command succeeded but produced no result.',
      );
      return;
    }
    final result = jsonDecode(job.resultJson!) as Map<String, dynamic>;
    final draft = CommandDraft.fromJobResult(
      result,
      id: const Uuid().v4(),
      sessionId: arg,
    );
    await ref.read(draftRepositoryProvider).saveDraft(draft);

    state = state.copyWith(
      phase: CommandBusPhase.succeeded,
      lastDraftId: draft.id,
    );
  }

  Future<void> _onFailed(Job job) async {
    final error = _jobErrorMessage(job);
    state = state.copyWith(
      phase: CommandBusPhase.failed,
      error: error ?? 'Command failed.',
    );
  }

  Future<void> _onCancelled(Job job) async {
    state = state.copyWith(phase: CommandBusPhase.idle);
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