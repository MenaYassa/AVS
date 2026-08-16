/// Cross-session intelligence controller (architecture §4.9, spec §19).
///
/// Builds compact descriptors from the local session library, submits an
/// `insights` job to the engine, streams progress, and exposes the resulting
/// insight statements with their source-session provenance. Deterministic and
/// provider-free on the engine side; here it is opt-in via
/// `intelligenceSettingsProvider`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logging/app_logger.dart';
import '../../domain/entities/enums.dart';
import '../../domain/entities/insight.dart';
import '../../domain/entities/job.dart';
import '../../domain/entities/session.dart';
import '../../domain/entities/tag.dart';
import '../../domain/repositories.dart';
import '../auth/auth_controller.dart';

/// How much transcript text rides into one session descriptor. Snippet
/// extraction happens against items/summary first; this is a bounded fallback.
const int kMaxDescriptorTranscriptChars = 4000;

/// User-visible phase of an insights run.
enum InsightsPhase { idle, running, failed }

/// State for the insights controller.
class InsightsState {
  const InsightsState({
    this.phase = InsightsPhase.idle,
    this.result,
    this.job,
    this.error,
  });

  final InsightsPhase phase;
  final InsightResult? result;
  final Job? job;
  final String? error;

  bool get isRunning => phase == InsightsPhase.running;

  InsightsState copyWith({
    InsightsPhase? phase,
    InsightResult? result,
    Job? job,
    String? error,
    bool clearError = false,
  }) {
    return InsightsState(
      phase: phase ?? this.phase,
      result: result ?? this.result,
      job: job ?? this.job,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Compact session descriptor the engine's insights runner clusters over
/// (`insights.schema.json` input shape; privacy: only what we ship is ever
/// computed on — architecture §4.9).
Map<String, dynamic> sessionToInsightDescriptor(
  Session session,
  List<Tag> tags,
) {
  final transcript = session.cleanedTranscript ?? session.originalTranscript ?? '';
  return {
    'session_id': session.id,
    'title': session.title ?? '',
    'summary': session.summary ?? '',
    'transcript': transcript.substring(
      0,
      math.min(transcript.length, kMaxDescriptorTranscriptChars),
    ),
    'tags': tags.map((t) => t.name).toList(),
    'entities': [
      for (final e in session.entities)
        {'name': e.name, 'type': e.type.wireName},
    ],
    'items': [
      for (final topic in session.topics)
        for (final item in topic.items)
          {
            'title': item.title,
            'description': item.description,
            'type': item.type.name,
          },
    ],
  };
}

/// Whether a session has been analyzed (and therefore carries the entities,
/// tags, and topics the clustering works on).
bool isAnalyzedForInsights(Session session) => switch (session.status) {
      SessionStatus.ready ||
      SessionStatus.edited ||
      SessionStatus.synced =>
        true,
      _ => false,
    };

final insightsControllerProvider =
    NotifierProvider<InsightsController, InsightsState>(
  InsightsController.new,
);

class InsightsController extends Notifier<InsightsState> {
  StreamSubscription<Job>? _sub;

  @override
  InsightsState build() {
    ref.onDispose(_stopStreaming);
    return const InsightsState();
  }

  /// Runs a fresh insights pass over the analyzed sessions in the library.
  Future<void> refresh() async {
    if (state.isRunning) return;

    final sessions = await _analyzedSessions();
    if (sessions.isEmpty) {
      state = InsightsState();
      return;
    }

    String userId;
    try {
      userId = ref.read(authControllerProvider).valueOrNull ?? 'local';
    } catch (_) {
      userId = 'local';
    }

    state = state.copyWith(phase: InsightsPhase.running, clearError: true);

    try {
      final descriptors = <Map<String, dynamic>>[];
      for (final session in sessions) {
        final tags = await ref
            .read(tagRepositoryProvider)
            .getTagsForSession(session.id);
        descriptors.add(sessionToInsightDescriptor(session, tags));
      }

      final job = await ref.read(engineGatewayProvider).createJob(
            userId: userId,
            kind: JobKind.insights,
            inputRef: null,
            options: {'sessions': descriptors},
          );

      await ref.read(jobProvider).insertJob(job);
      state = state.copyWith(phase: InsightsPhase.running, job: job);
      _subscribe(job);
    } on AppFailure catch (e) {
      state = state.copyWith(
        phase: InsightsPhase.failed,
        error: 'Could not generate insights: ${e.message}',
      );
    } catch (e, st) {
      Log.e('Failed to start insights', e, st);
      state = state.copyWith(
        phase: InsightsPhase.failed,
        error: 'Could not generate insights.',
      );
    }
  }

  Future<List<Session>> _analyzedSessions() async {
    final sessions =
        await ref.read(databaseProvider).watchSessions().first;
    return sessions.where(isAnalyzedForInsights).toList();
  }

  void _subscribe(Job job) {
    _stopStreaming();
    final userId = ref.read(authControllerProvider).valueOrNull ?? job.userId;
    _sub = ref
        .read(engineGatewayProvider)
        .streamJob(userId, job.id)
        .listen(_onJob, onError: (Object e, StackTrace st) {
      Log.e('Insights stream failed', e, st);
      state = state.copyWith(
        phase: InsightsPhase.failed,
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
        state = state.copyWith(phase: InsightsPhase.idle);
      case JobStatus.queued:
      case JobStatus.running:
        break;
    }
  }

  Future<void> _onSucceeded(Job job) async {
    if (job.resultJson == null) {
      state = state.copyWith(
        phase: InsightsPhase.failed,
        error: 'Insights succeeded but produced no result.',
      );
      return;
    }
    final result = jsonDecode(job.resultJson!) as Map<String, dynamic>;
    state = state.copyWith(
      phase: InsightsPhase.idle,
      result: InsightResult.fromJson(result),
      job: job,
    );
  }

  Future<void> _onFailed(Job job) async {
    state = state.copyWith(
      phase: InsightsPhase.failed,
      error: _jobErrorMessage(job) ?? 'Insights failed.',
    );
  }

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
