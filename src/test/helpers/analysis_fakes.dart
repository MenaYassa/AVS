import 'dart:async';

import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/job.dart';
import 'package:ai_knowledge_companion/domain/entities/plugin.dart';
import 'package:ai_knowledge_companion/domain/entities/semantic_search_result.dart';
import 'package:ai_knowledge_companion/domain/repositories.dart';

/// Controllable [EngineGateway] for analysis tests: `createJob` records the
/// submission, `streamJob` returns a live broadcast stream the test drives.
class FakeEngineGateway implements EngineGateway {
  final List<Job> jobs = [];
  final StreamController<Job> _live = StreamController<Job>.broadcast();

  Job? get created => jobs.isEmpty ? null : jobs.last;

  /// Number of `createJob` calls (retry re-submits).
  int get createCount => jobs.length;

  /// Last submission's `inputRef`, captured for assertion.
  String? lastInputRef;

  /// Last submission's `options`, captured for assertion.
  Map<String, dynamic>? lastOptions;

  /// Texts handed to `embedSessions` on the last backfill call.
  List<String>? embeddedTexts;

  /// Plugin targets handed back from `listPlugins`.
  List<PluginTargetStatus> pluginStatuses = [
    const PluginTargetStatus(
      kind: 'notion',
      displayName: 'Notion',
      connected: false,
      configured: true,
    ),
    const PluginTargetStatus(
      kind: 'slack',
      displayName: 'Slack',
      connected: false,
      configured: true,
    ),
  ];

  /// Last plugin push draft captured for assertion.
  Map<String, dynamic>? lastPushedDraft;

  /// Last `pluginAuthUrl` redirect URI captured for assertion.
  String? lastAuthRedirectUri;

  /// Plugins the fake will report as connected.
  final Set<String> connectedPlugins = {};

  /// Record of `disconnectPlugin` calls.
  final List<String> disconnectedKinds = [];

  /// Emits a job update into the live SSE stream.
  void emit(Job job) => _live.add(job);

  void closeStream() => _live.close();

  @override
  Future<Job> createJob({
    required String userId,
    required JobKind kind,
    String? inputRef,
    Map<String, dynamic>? options,
    Map<String, dynamic>? promptVersions,
  }) async {
    lastInputRef = inputRef;
    lastOptions = options;
    final now = DateTime.now().toUtc();
    final job = Job(
      id: 'j${jobs.length + 1}',
      userId: userId,
      kind: kind,
      status: JobStatus.queued,
      inputRef: inputRef,
      createdAt: now,
      updatedAt: now,
    );
    jobs.add(job);
    return job;
  }

  @override
  Future<Job> getJob(String userId, String jobId) async =>
      jobs.firstWhere((j) => j.id == jobId);

  @override
  Future<void> cancelJob(String userId, String jobId) async {
    final index = jobs.indexWhere((j) => j.id == jobId);
    final cancelled = jobs[index].copyWith(
      status: JobStatus.cancelled,
      sessionStatus: 'cancelled',
      stageLabel: null,
      updatedAt: DateTime.now().toUtc(),
    );
    jobs[index] = cancelled;
    emit(cancelled);
  }

  @override
  Stream<Job> streamJob(String userId, String jobId) => _live.stream;

  @override
  Future<EngineSemanticSearch> semanticSearch(
    String query, {
    int limit = 20,
    double threshold = 0.7,
  }) async => const EngineSemanticSearch(
        results: [],
        queryEmbedding: [],
        dimension: 0,
      );

  @override
  Future<EngineEmbedSessions> embedSessions(
    List<({String sessionId, String text})> sessions, {
    int limit = 50,
  }) async {
    embeddedTexts = [for (final s in sessions) s.text];
    return EngineEmbedSessions(
      embeddings: [
        for (final s in sessions)
          EngineSessionEmbedding(
            sessionId: s.sessionId,
            embedding: [0.5, 0.5],
            dimension: 2,
          ),
      ],
      dimension: 2,
    );
  }

  @override
  Future<List<PluginTargetStatus>> listPlugins(String userId) async =>
      [
        for (final s in pluginStatuses)
          PluginTargetStatus(
            kind: s.kind,
            displayName: s.displayName,
            connected: connectedPlugins.contains(s.kind),
            configured: s.configured,
          ),
      ];

  @override
  Future<PluginAuthUrl> pluginAuthUrl(
    String userId,
    String kind, {
    required String redirectUri,
  }) async {
    lastAuthRedirectUri = redirectUri;
    return PluginAuthUrl(
      kind: kind,
      displayName: 'Notion',
      url: 'https://oauth.example/authorize?kind=$kind',
      state: 'state-1',
    );
  }

  @override
  Future<void> exchangePluginToken(
    String userId,
    String kind, {
    required String code,
    required String state,
    required String redirectUri,
  }) async {
    connectedPlugins.add(kind);
  }

  @override
  Future<PluginPushReceipt> pushDraft(
    String userId,
    String kind, {
    required Map<String, dynamic> draft,
    String? target,
  }) async {
    lastPushedDraft = draft;
    return PluginPushReceipt(
      kind: kind,
      ok: true,
      targetUrl: 'https://target.example/entry',
      externalId: 'ext-1',
    );
  }

  @override
  Future<void> disconnectPlugin(String userId, String kind) async {
    connectedPlugins.remove(kind);
    disconnectedKinds.add(kind);
  }
}

/// Builds a running job snapshot for a given pipeline stage.
Job runningJob(Job base, String stage, String sessionStatus, String stageLabel) =>
    base.copyWith(
      status: JobStatus.running,
      stage: stage,
      sessionStatus: sessionStatus,
      stageLabel: stageLabel,
      updatedAt: DateTime.now().toUtc(),
    );

/// Builds a succeeded job carrying a canonical session result.
Job succeededJob(
  Job base,
  String resultJson, {
  String? intermediatesJson,
}) =>
    base.copyWith(
      status: JobStatus.succeeded,
      stage: null,
      sessionStatus: 'ready',
      stageLabel: 'Validating',
      resultJson: resultJson,
      intermediatesJson: intermediatesJson,
      updatedAt: DateTime.now().toUtc(),
    );

/// Builds a failed job carrying a structured engine error.
Job failedJob(Job base, String message) => base.copyWith(
      status: JobStatus.failed,
      stage: 'cleanup',
      sessionStatus: 'failed',
      stageLabel: 'Cleaning up',
      errorJson: '{"code":"JOB_FAILED","message":"$message"}',
      updatedAt: DateTime.now().toUtc(),
    );
