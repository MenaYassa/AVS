import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../domain/entities/enums.dart';
import '../../domain/entities/job.dart';
import '../../domain/entities/semantic_search_result.dart';
import '../../domain/entities/plugin.dart';
import '../../domain/repositories.dart';
import 'sse_parser.dart';

/// HTTP client for the AI Knowledge Engine (architecture §7.1).
///
/// The app NEVER calls STT/LLM providers directly — all AI traffic goes
/// through the engine (architecture §2).
class EngineClient implements EngineGateway {
  EngineClient({
    required this.baseUrl,
    Dio? dio,
  }) : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: baseUrl,
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 30),
            ));

  final String baseUrl;
  final Dio _dio;
  String? _authToken;

  void setAuthToken(String? token) => _authToken = token;

  Options get _authOptions => Options(headers: {
        if (_authToken != null) 'Authorization': 'Bearer $_authToken',
      });

  @override
  Future<Job> createJob({
    required String userId,
    required JobKind kind,
    String? inputRef,
    Map<String, dynamic>? options,
    Map<String, dynamic>? promptVersions,
  }) async {
    final body = <String, dynamic>{
      'kind': kind.name,
      'input_ref': ?inputRef,
      'options': ?options,
      'prompt_versions': ?promptVersions,
    };
    final res = await _dio.post<Map<String, dynamic>>(
      '/api/v1/jobs',
      data: body,
      options: _authOptions.copyWith(contentType: Headers.jsonContentType),
    );
    final data = _unwrap(res.data);
    return Job.fromJson(data as Map<String, dynamic>);
  }

  @override
  Future<Job> getJob(String userId, String jobId) async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/api/v1/jobs/$jobId',
      options: _authOptions,
    );
    final data = _unwrap(res.data);
    return Job.fromJson(data as Map<String, dynamic>);
  }

  @override
  Future<void> cancelJob(String userId, String jobId) async {
    await _dio.post<void>(
      '/api/v1/jobs/$jobId/cancel',
      options: _authOptions,
    );
  }

  @override
  Stream<Job> streamJob(String userId, String jobId) async* {
    // SSE stream (architecture §7.1): `job` on stage change, `progress` with
    // the session-lifecycle projection, typed terminal events, `heartbeat`.
    final res = await _dio.get<ResponseBody>(
      '/api/v1/jobs/$jobId/stream',
      options: Options(
        responseType: ResponseType.stream,
        headers: _authOptions.headers,
      ),
    );
    final decoder = SseStreamDecoder();
    Job? latest;
    await for (final chunk in res.data!.stream) {
      for (final event
          in decoder.addChunk(utf8.decode(chunk, allowMalformed: true))) {
        switch (event.event) {
          case 'job':
          case 'done':
          case 'failed':
          case 'cancelled':
            final job = _jobFromSse(event.data);
            latest = job;
            yield job;
          case 'progress':
            final projection =
                jsonDecode(event.data) as Map<String, dynamic>;
            if (latest == null) continue;
            latest = latest.copyWith(
              status: JobStatus.values
                      .where((s) => s.name == projection['job_status'])
                      .firstOrNull ??
                  latest.status,
              stage: projection['stage'] as String?,
              sessionStatus: projection['session_status'] as String?,
              stageLabel: projection['stage_label'] as String?,
            );
            yield latest;
          case 'heartbeat':
          default:
            break; // keep-alive; no state change
        }
      }
    }
  }

  Job _jobFromSse(String data) {
    try {
      return Job.fromJson(jsonDecode(data) as Map<String, dynamic>);
    } catch (_) {
      throw const EngineFailure('Malformed engine stream event');
    }
  }

  @override
  Future<EngineSemanticSearch> semanticSearch(
    String query, {
    int limit = 20,
    double threshold = 0.7,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      '/api/v1/search/semantic',
      data: {'query': query, 'limit': limit, 'threshold': threshold},
      options: _authOptions.copyWith(contentType: Headers.jsonContentType),
    );
    final data = _unwrap(res.data) as Map<String, dynamic>;
    final rawResults = (data['results'] as List<dynamic>? ?? const []);
    return EngineSemanticSearch(
      results: [
        for (final r in rawResults.cast<Map<String, dynamic>>())
          SemanticSearchResult(
            sessionId: r['session_id'] as String,
            title: r['title'] as String?,
            summary: r['summary'] as String?,
            status: SessionStatus.ready,
            similarity: (r['similarity'] as num).toDouble(),
          ),
      ],
      queryEmbedding: (data['query_embedding'] as List<dynamic>? ?? const [])
          .map((v) => (v as num).toDouble())
          .toList(),
      dimension: (data['dimension'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<EngineEmbedSessions> embedSessions(
    List<({String sessionId, String text})> sessions, {
    int limit = 50,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      '/api/v1/search/embed_sessions',
      data: {
        'sessions': [
          for (final s in sessions.take(limit))
            {'session_id': s.sessionId, 'text': s.text},
        ],
      },
      options: _authOptions.copyWith(contentType: Headers.jsonContentType),
    );
    final data = _unwrap(res.data) as Map<String, dynamic>;
    final raw = (data['embeddings'] as List<dynamic>? ?? const []);
    return EngineEmbedSessions(
      embeddings: [
        for (final e in raw.cast<Map<String, dynamic>>())
          EngineSessionEmbedding(
            sessionId: e['session_id'] as String,
            embedding: (e['embedding'] as List<dynamic>? ?? const [])
                .map((v) => (v as num).toDouble())
                .toList(),
            dimension: (e['dimension'] as num?)?.toInt() ?? 0,
          ),
      ],
      dimension: (data['dimension'] as num?)?.toInt() ?? 0,
    );
  }

  /// Unwraps the stable engine envelope `{status, data | error}` (§7.1).
  dynamic _unwrap(dynamic envelope) {
    if (envelope is! Map<String, dynamic>) {
      throw EngineFailure('Unexpected engine response shape');
    }
    if (envelope['status'] != 'ok') {
      final err = envelope['error'];
      final message = err is Map
          ? (err['message'] as String? ?? 'Engine request failed')
          : 'Engine request failed';
      throw EngineFailure(message);
    }
    return envelope['data'];
  }

  @override
  Future<List<PluginTargetStatus>> listPlugins(String userId) async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/api/v1/plugins',
      options: _authOptions,
    );
    final data = _unwrap(res.data) as Map<String, dynamic>;
    final list = (data['plugins'] as List<dynamic>? ?? const []);
    return list
        .map((e) => PluginTargetStatus.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<PluginAuthUrl> pluginAuthUrl(
    String userId,
    String kind, {
    required String redirectUri,
  }) async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/api/v1/plugins/$kind/auth-url',
      queryParameters: {'redirect_uri': redirectUri},
      options: _authOptions,
    );
    final data = _unwrap(res.data) as Map<String, dynamic>;
    return PluginAuthUrl.fromJson(data);
  }

  @override
  Future<void> exchangePluginToken(
    String userId,
    String kind, {
    required String code,
    required String state,
    required String redirectUri,
  }) async {
    await _dio.post<Map<String, dynamic>>(
      '/api/v1/plugins/$kind/token',
      data: {
        'code': code,
        'state': state,
        'redirect_uri': redirectUri,
      },
      options: _authOptions.copyWith(contentType: Headers.jsonContentType),
    );
  }

  @override
  Future<PluginPushReceipt> pushDraft(
    String userId,
    String kind, {
    required Map<String, dynamic> draft,
    String? target,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      '/api/v1/plugins/$kind/push',
      data: {
        'draft': draft,
        'target': target,
      },
      options: _authOptions.copyWith(contentType: Headers.jsonContentType),
    );
    final data = _unwrap(res.data) as Map<String, dynamic>;
    return PluginPushReceipt.fromJson(data);
  }

  @override
  Future<void> disconnectPlugin(String userId, String kind) async {
    await _dio.delete<Map<String, dynamic>>(
      '/api/v1/plugins/$kind/credentials',
      options: _authOptions,
    );
  }
}

/// A safe-to-use in-memory gateway for offline/dev flows (no engine reachable).
class UnavailableEngineGateway implements EngineGateway {
  const UnavailableEngineGateway();

  Never _unavailable() => throw const EngineFailure(
      'AI engine is not configured. Set ENGINE_BASE_URL and sign in.');

  @override
  Future<void> cancelJob(String userId, String jobId) => _unavailable();

  @override
  Future<Job> createJob({
    required String userId,
    required JobKind kind,
    String? inputRef,
    Map<String, dynamic>? options,
    Map<String, dynamic>? promptVersions,
  }) =>
      _unavailable();

  @override
  Future<Job> getJob(String userId, String jobId) => _unavailable();

  @override
  Stream<Job> streamJob(String userId, String jobId) => _unavailable();

  @override
  Future<EngineSemanticSearch> semanticSearch(
    String query, {
    int limit = 20,
    double threshold = 0.7,
  }) =>
      _unavailable();

  @override
  Future<EngineEmbedSessions> embedSessions(
    List<({String sessionId, String text})> sessions, {
    int limit = 50,
  }) =>
      _unavailable();

  @override
  Future<List<PluginTargetStatus>> listPlugins(String userId) => _unavailable();

  @override
  Future<PluginAuthUrl> pluginAuthUrl(
    String userId,
    String kind, {
    required String redirectUri,
  }) =>
      _unavailable();

  @override
  Future<void> exchangePluginToken(
    String userId,
    String kind, {
    required String code,
    required String state,
    required String redirectUri,
  }) =>
      _unavailable();

  @override
  Future<PluginPushReceipt> pushDraft(
    String userId,
    String kind, {
    required Map<String, dynamic> draft,
    String? target,
  }) =>
      _unavailable();

  @override
  Future<void> disconnectPlugin(String userId, String kind) => _unavailable();
}
