import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logging/app_logger.dart';
import '../../domain/entities/enums.dart';
import '../../domain/entities/job.dart';
import '../../domain/entities/session.dart';
import '../../domain/repositories.dart';
import '../../domain/usecases/delete_session_audio.dart';
import '../auth/auth_controller.dart';
import '../memory/memory_context.dart';
import '../settings/intelligence_controller.dart';
import '../settings/memory_controller.dart';
import '../tags/tags_controller.dart';
import '../versioning/version_controller.dart';

/// User-visible phases of analyzing a session's recording (architecture §4.5).
enum AnalysisPhase { idle, submitting, processing, succeeded, failed, cancelled }

/// Analysis progress for one session, driven by the engine SSE stream.
class AnalysisState {
  const AnalysisState({
    this.phase = AnalysisPhase.idle,
    this.job,
    this.status,
    this.stageLabel,
    this.error,
  });

  final AnalysisPhase phase;
  final Job? job;

  /// Session lifecycle projection from the engine (`session_status`).
  final SessionStatus? status;

  /// Human-readable label for the current pipeline stage.
  final String? stageLabel;
  final String? error;

  bool get isProcessing => phase == AnalysisPhase.submitting ||
      phase == AnalysisPhase.processing;

  bool get hasAnalysis => phase == AnalysisPhase.succeeded;

  AnalysisState copyWith({
    AnalysisPhase? phase,
    Job? job,
    SessionStatus? status,
    String? stageLabel,
    String? error,
    bool clearError = false,
  }) {
    return AnalysisState(
      phase: phase ?? this.phase,
      job: job ?? this.job,
      status: status ?? this.status,
      stageLabel: stageLabel ?? this.stageLabel,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Per-session analysis coordinator (architecture §4.5, §7.1).
///
/// Submits an `analyze` job to the engine, streams SSE progress, projects the
/// engine's `session_status` onto the local session, and applies the validated
/// canonical session on success. Retry/re-submit is safe from `idle` or
/// `failed`; a running analysis ignores duplicate submissions.
final analysisControllerProvider =
    NotifierProvider.family<AnalysisController, AnalysisState, String>(
  AnalysisController.new,
);

/// Removes the raw recording after analysis when the privacy setting is on.
final deleteSessionAudioProvider = Provider<DeleteSessionAudio>(
  (ref) => DeleteSessionAudio(ref.watch(databaseProvider)),
);

class AnalysisController extends FamilyNotifier<AnalysisState, String> {
  StreamSubscription<Job>? _sub;

  @override
  AnalysisState build(String sessionId) {
    ref.onDispose(_stopStreaming);
    return const AnalysisState();
  }

  /// Submits (or re-submits after failure) an analysis job for this session.
  Future<void> analyze() async {
    if (state.isProcessing) return;
    final session = await ref.read(databaseProvider).getSession(arg);
    if (session == null || session.audioPath == null) {
      state = state.copyWith(
        phase: AnalysisPhase.failed,
        error: 'No recording to analyze.',
      );
      return;
    }
    final audioPath = session.audioPath!;
    String userId;
    try {
      userId = ref.read(authControllerProvider).valueOrNull ?? session.userId;
    } catch (_) {
      userId = session.userId;
    }
    state = const AnalysisState(phase: AnalysisPhase.submitting);
    try {
      // Keep the device-local audio path for playback, but upload it through
      // the existing sync/storage seam so the engine receives a stable,
      // server-readable bucket/object reference.
      final remoteRef =
          session.audioRemoteUrl ?? 'sessions/$userId/${session.id}.m4a';
      if (session.audioRemoteUrl == null) {
        await ref.read(syncProvider).uploadAudio(session.id, audioPath);
        await ref.read(databaseProvider).updateSession(session.copyWith(
              audioRemoteUrl: remoteRef,
              updatedAt: DateTime.now().toUtc(),
            ));
      }

      final memory = await _memoryFor();
      final job = await ref.read(engineGatewayProvider).createJob(
        userId: userId,
        kind: JobKind.analyze,
        inputRef: remoteRef,
        options: {
          'input_kind': 'voice',
          'input_meta': {
            'mime_type': 'audio/mp4',
            if (session.durationSec != null) 'duration_sec': session.durationSec,
          },
          'memory': memory,
        },
      );
      await _persistSessionStatus(SessionStatus.uploading);
      await ref.read(jobProvider).insertJob(job);
      state = state.copyWith(phase: AnalysisPhase.processing, job: job);
      _subscribe(job);
    } on AppFailure catch (e) {
      state = AnalysisState(
        phase: AnalysisPhase.failed,
        error: 'Could not start analysis: ${e.message}',
      );
    } catch (e, st) {
      Log.e('Failed to start analysis', e, st);
      state = const AnalysisState(
        phase: AnalysisPhase.failed,
        error: 'Could not start analysis.',
      );
    }
  }

  /// Re-runs analysis from an edited transcript (architecture §4.12, spec §15):
  /// submits an `analyze` job with `input_kind: transcript` so the engine
  /// skips STT and re-analyzes the corrected text. No audio is needed.
  Future<void> analyzeTranscript(String transcript) async {
    if (state.isProcessing) return;
    if (transcript.trim().isEmpty) {
      state = state.copyWith(
        phase: AnalysisPhase.failed,
        error: 'The transcript is empty.',
      );
      return;
    }
    final session = await _session();
    if (session == null) return;
    String userId;
    try {
      userId = ref.read(authControllerProvider).valueOrNull ?? session.userId;
    } catch (_) {
      userId = session.userId;
    }
    state = const AnalysisState(phase: AnalysisPhase.submitting);
    try {
      final memory = await _memoryFor();
      final job = await ref.read(engineGatewayProvider).createJob(
            userId: userId,
            kind: JobKind.analyze,
            inputRef: null,
            options: {
              'input_kind': 'transcript',
              'input_meta': {'text': transcript},
              'memory': memory,
            },
          );
      // No upload/STT for a transcript re-run; the pipeline starts at cleanup.
      await _persistSessionStatus(SessionStatus.cleaning);
      await ref.read(jobProvider).insertJob(job);
      state = state.copyWith(phase: AnalysisPhase.processing, job: job);
      _subscribe(job);
    } on AppFailure catch (e) {
      state = AnalysisState(
        phase: AnalysisPhase.failed,
        error: 'Could not start analysis: ${e.message}',
      );
    } catch (e, st) {
      Log.e('Failed to start analysis', e, st);
      state = const AnalysisState(
        phase: AnalysisPhase.failed,
        error: 'Could not start analysis.',
      );
    }
  }

  /// Analyzes a manual note (architecture §4.12, universal input): submits an
  /// `analyze` job with `input_kind: note` so the engine skips recording and
  /// STT and feeds the authored text straight into the pipeline. The note text
  /// travels in `input_meta.text`, so no blob or input_ref is needed.
  Future<void> analyzeNote(String text, {String? title}) async {
    if (state.isProcessing) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      state = state.copyWith(
        phase: AnalysisPhase.failed,
        error: 'The note is empty.',
      );
      return;
    }
    final session = await _session();
    if (session == null) return;
    String userId;
    try {
      userId = ref.read(authControllerProvider).valueOrNull ?? session.userId;
    } catch (_) {
      userId = session.userId;
    }
    state = const AnalysisState(phase: AnalysisPhase.submitting);
    try {
      final memory = await _memoryFor();
      final trimmedTitle = title?.trim();
      final job = await ref.read(engineGatewayProvider).createJob(
            userId: userId,
            kind: JobKind.analyze,
            inputRef: null,
            options: {
              'input_kind': 'note',
              'input_meta': {
                'text': trimmed,
                if (trimmedTitle != null && trimmedTitle.isNotEmpty)
                  'title': trimmedTitle,
              },
              'memory': memory,
            },
          );
      // No upload/STT for a note; the pipeline starts at cleanup.
      await _persistSessionStatus(SessionStatus.cleaning);
      await ref.read(jobProvider).insertJob(job);
      state = state.copyWith(phase: AnalysisPhase.processing, job: job);
      _subscribe(job);
    } on AppFailure catch (e) {
      state = AnalysisState(
        phase: AnalysisPhase.failed,
        error: 'Could not start analysis: ${e.message}',
      );
    } catch (e, st) {
      Log.e('Failed to start analysis', e, st);
      state = const AnalysisState(
        phase: AnalysisPhase.failed,
        error: 'Could not start analysis.',
      );
    }
  }

  /// Analyzes an imported image/PDF document (architecture §4.12, universal
  /// input): submits an `analyze` job with `input_kind: image|pdf` so the
  /// engine OCR-extracts the blob and runs the shared pipeline. The blob path
  /// travels as `input_ref` (mirroring the voice flow); `input_meta.mime_type`
  /// lets the adapter validate the blob before OCR.
  Future<void> analyzeDocument(
    String path, {
    required String inputKind,
    required String mimeType,
  }) async {
    if (state.isProcessing) return;
    final session = await _session();
    if (session == null) return;
    String userId;
    try {
      userId = ref.read(authControllerProvider).valueOrNull ?? session.userId;
    } catch (_) {
      userId = session.userId;
    }
    state = const AnalysisState(phase: AnalysisPhase.submitting);
    try {
      final memory = await _memoryFor();
      final job = await ref.read(engineGatewayProvider).createJob(
            userId: userId,
            kind: JobKind.analyze,
            inputRef: path,
            options: {
              'input_kind': inputKind,
              'input_meta': {'mime_type': mimeType},
              'memory': memory,
            },
          );
      await _persistSessionStatus(SessionStatus.uploading);
      await ref.read(jobProvider).insertJob(job);
      state = state.copyWith(phase: AnalysisPhase.processing, job: job);
      _subscribe(job);
    } on AppFailure catch (e) {
      state = AnalysisState(
        phase: AnalysisPhase.failed,
        error: 'Could not start analysis: ${e.message}',
      );
    } catch (e, st) {
      Log.e('Failed to start analysis', e, st);
      state = const AnalysisState(
        phase: AnalysisPhase.failed,
        error: 'Could not start analysis.',
      );
    }
  }

  /// Cancels the in-flight analysis (engine best-effort; lifecycle shows it).
  Future<void> cancel() async {
    final job = state.job;
    if (job == null || job.status.isTerminal) return;
    final userId = ref.read(authControllerProvider).valueOrNull ?? job.userId;
    try {
      await ref.read(engineGatewayProvider).cancelJob(userId, job.id);
    } catch (e, st) {
      Log.e('Failed to cancel analysis', e, st);
    }
  }

  void _subscribe(Job job) {
    _stopStreaming();
    final userId = ref.read(authControllerProvider).valueOrNull ?? job.userId;
    _sub = ref
        .read(engineGatewayProvider)
        .streamJob(userId, job.id)
        .listen(_onJob, onError: (Object e, StackTrace st) {
      Log.e('Analysis stream failed', e, st);
      state = state.copyWith(
        phase: AnalysisPhase.failed,
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
    final status = SessionStatus.fromWire(job.sessionStatus);
    state = state.copyWith(
      job: job,
      status: status,
      stageLabel: job.stageLabel,
      clearError: true,
    );
    if (status != null && !status.isTerminal) {
      await _persistSessionStatus(status);
    }
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
    final session = await _session();
    if (session != null) {
      final parsed = _parseResult(job, session);
      final transcripts = _parseTranscripts(job);
      if (parsed != null) {
        await ref
            .read(databaseProvider)
            .replaceTopics(arg, parsed.topics);
        final updated = session.copyWith(
              title: parsed.title,
              alternativeTitles: parsed.alternativeTitles,
              summary: parsed.summary,
              summaryConfidence: parsed.summaryConfidence,
              extractionConfidence: parsed.extractionConfidence,
              language: parsed.language,
              wordCount: parsed.wordCount,
              promptVersions: parsed.promptVersions,
              originalTranscript: transcripts?.$1,
              cleanedTranscript: transcripts?.$2,
              entities: parsed.entities,
              relationships: parsed.relationships,
              status: SessionStatus.ready,
              clearError: true,
              updatedAt: DateTime.now().toUtc(),
            );
        await ref.read(databaseProvider).updateSession(updated);
        await _applyAutoTags(job);
        await _persistEmbedding(job);
        await _maybeDeleteAudioAfterProcessing(updated);
      } else {
        final updated = session.copyWith(
              originalTranscript: transcripts?.$1,
              cleanedTranscript: transcripts?.$2,
              status: SessionStatus.ready,
              clearError: true,
              updatedAt: DateTime.now().toUtc(),
            );
        await ref.read(databaseProvider).updateSession(updated);
        await _maybeDeleteAudioAfterProcessing(updated);
      }
    }
    state = state.copyWith(
      phase: AnalysisPhase.succeeded,
      status: SessionStatus.ready,
      clearError: true,
    );
    // Commit point for the initial AI output / prompt re-runs (§4.6).
    await ref.read(versioningControllerProvider(arg).notifier)
        .commitAnalysisResult();
  }

  Future<void> _onFailed(Job job) async {
    final error = _jobErrorMessage(job);
    final session = await _session();
    if (session != null) {
      await ref.read(databaseProvider).updateSession(session.copyWith(
            status: SessionStatus.failed,
            lastError: error,
            updatedAt: DateTime.now().toUtc(),
          ));
    }
    state = state.copyWith(
      phase: AnalysisPhase.failed,
      status: SessionStatus.failed,
      error: error ?? 'Analysis failed.',
    );
  }

  Future<void> _onCancelled(Job job) async {
    final session = await _session();
    if (session != null) {
      await ref.read(databaseProvider).updateSession(session.copyWith(
            status: SessionStatus.cancelled,
            updatedAt: DateTime.now().toUtc(),
          ));
    }
    state = state.copyWith(
      phase: AnalysisPhase.cancelled,
      status: SessionStatus.cancelled,
    );
  }

  Future<void> _persistSessionStatus(SessionStatus status) async {
    final session = await _session();
    if (session == null) return;
    await ref.read(databaseProvider).updateSession(session.copyWith(
          status: status,
          updatedAt: DateTime.now().toUtc(),
        ));
  }

  Future<Session?> _session() =>
      ref.read(databaseProvider).getSession(arg);

  /// Resolves the opt-in memory block for this session (architecture §4.9):
  /// empty when AI memory is off, the session opts out, or nothing is related.
  Future<List<Map<String, dynamic>>> _memoryFor() {
    final settings = ref.read(intelligenceSettingsProvider).valueOrNull;
    return memoryForSession(
      enableMemory: settings?.enableMemory ?? false,
      readSkip: () => ref.read(memorySkipProvider(arg).future),
      readSessions: () => ref.read(databaseProvider).watchSessions().first,
      tagsFor: (id) => ref.read(tagRepositoryProvider).getTagsForSession(id),
      sessionId: arg,
    );
  }

  /// "Delete audio after processing" (spec §18, architecture §12): once a
  /// session reaches `ready`, the raw recording is removed when the privacy
  /// setting is on. Best-effort — a deletion failure never fails the analysis.
  Future<void> _maybeDeleteAudioAfterProcessing(Session session) async {
    try {
      final enabled = await ref
          .read(appSettingsRepositoryProvider)
          .getDeleteAudioAfterProcessing(session.userId);
      if (!enabled) return;
      await ref.read(deleteSessionAudioProvider)(session);
    } catch (e, st) {
      Log.e('Failed to delete audio after processing', e, st);
    }
  }

  /// Attaches the engine's `tags` stage output to the session (§4.2 auto AI
  /// tags). Best-effort: never fails the analysis over a tagging problem, and
  /// never removes manual tags (auto tags are additive, deduped by name).
  Future<void> _applyAutoTags(Job job) async {
    final json = job.resultJson;
    if (json == null) return;
    try {
      final result = jsonDecode(json) as Map<String, dynamic>;
      final sessionJson = result['session'] as Map<String, dynamic>?;
      final rawTags = (sessionJson?['tags'] as List<dynamic>?) ?? const [];
      final names = rawTags
          .map((t) => ((t as Map<String, dynamic>)['name'] as String? ?? '')
              .trim())
          .where((n) => n.isNotEmpty)
          .toList();
      if (names.isEmpty) return;
      await ref.read(tagsControllerProvider).attachByNames(arg, names);
    } catch (_) {
      // Auto-tags are best-effort; ignore malformed tagging output.
    }
  }

  /// Parses the engine's validated canonical session result, or null when the
  /// payload is absent/malformed (the session still lands as `ready`).
  Session? _parseResult(Job job, Session session) {
    final json = job.resultJson;
    if (json == null) return null;
    try {
      return Session.fromCanonicalJson(
        jsonDecode(json) as Map<String, dynamic>,
        userId: session.userId,
        audioPath: session.audioPath,
      );
    } catch (e, st) {
      Log.e('Malformed analysis result', e, st);
      return null;
    }
  }

  /// Persists the engine's `embedding` stage output into the local semantic
  /// index (§6.1): `job.intermediates.embedding = {embedding, dimension,
  /// text_length}`. Best-effort — a missing/malformed vector never fails the
  /// analysis.
  Future<void> _persistEmbedding(Job job) async {
    final raw = job.intermediatesJson;
    if (raw == null) return;
    try {
      final intermediates = jsonDecode(raw) as Map<String, dynamic>;
      final embedding = intermediates['embedding'];
      if (embedding is! Map<String, dynamic>) return;
      final vector = embedding['embedding'];
      if (vector is! List || vector.isEmpty) return;
      final contentRef = embedding['text_length']?.toString() ?? '';
      await ref.read(embeddingRepositoryProvider).upsertSessionEmbedding(
            sessionId: arg,
            scope: 'local',
            contentRef: contentRef,
            vector: vector.map((v) => (v as num).toDouble()).toList(),
          );
    } catch (e, st) {
      Log.e('Failed to persist session embedding', e, st);
    }
  }

  /// Extracts `(original_text, cleaned_text)` from the cleanup stage output in
  /// `job.intermediates` (§2.5), or null when unavailable.
  (String?, String?)? _parseTranscripts(Job job) {
    final raw = job.intermediatesJson;
    if (raw == null) return null;
    try {
      final intermediates = jsonDecode(raw) as Map<String, dynamic>;
      final cleanup = intermediates['cleanup'];
      if (cleanup is! Map<String, dynamic>) return null;
      final cleaned = cleanup['cleaned_text'] as String?;
      final original = cleanup['original_text'] as String?;
      if (cleaned == null && original == null) return null;
      return (original, cleaned);
    } catch (e, st) {
      Log.e('Malformed analysis intermediates', e, st);
      return null;
    }
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
