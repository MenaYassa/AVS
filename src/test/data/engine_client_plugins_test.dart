import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_knowledge_companion/data/engine/engine_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.respond);

  final FutureOr<Map<String, dynamic>> Function(RequestOptions options) respond;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final body = await respond(options);
    return ResponseBody.fromString(jsonEncode(body), 200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        });
  }
}

EngineClient _client(_FakeAdapter adapter) => EngineClient(
      baseUrl: 'https://engine.test',
      dio: Dio()..httpClientAdapter = adapter,
    )..setAuthToken('tok');

void main() {
  test('listPlugins GETs /api/v1/plugins and maps target status', () async {
    final adapter = _FakeAdapter((options) {
      expect(options.method, 'GET');
      expect(options.path, '/api/v1/plugins');
      expect(options.headers['Authorization'], 'Bearer tok');
      return {
        'status': 'ok',
        'data': {
          'plugins': [
            {
              'kind': 'notion',
              'display_name': 'Notion',
              'connected': true,
              'configured': true,
            },
            {
              'kind': 'slack',
              'display_name': 'Slack',
              'connected': false,
              'configured': true,
            },
          ],
        },
      };
    });

    final statuses = await _client(adapter).listPlugins('u1');

    expect(statuses, hasLength(2));
    expect(statuses.first.kind, 'notion');
    expect(statuses.first.connected, true);
    expect(statuses.last.connected, false);
  });

  test('pluginAuthUrl GETs with redirect_uri query param', () async {
    final adapter = _FakeAdapter((options) {
      expect(options.method, 'GET');
      expect(options.path, '/api/v1/plugins/notion/auth-url');
      expect(options.queryParameters['redirect_uri'],
          'ai-knowledge-companion://oauth/callback');
      return {
        'status': 'ok',
        'data': {
          'kind': 'notion',
          'display_name': 'Notion',
          'url': 'https://oauth.example/auth?code_challenge=x',
          'state': 'st-1',
        },
      };
    });

    final url = await _client(adapter).pluginAuthUrl(
      'u1',
      'notion',
      redirectUri: 'ai-knowledge-companion://oauth/callback',
    );

    expect(url.kind, 'notion');
    expect(url.url, contains('code_challenge=x'));
    expect(url.state, 'st-1');
  });

  test('exchangePluginToken POSTs code/state/redirect_uri', () async {
    final adapter = _FakeAdapter((options) {
      expect(options.method, 'POST');
      expect(options.path, '/api/v1/plugins/notion/token');
      final payload = options.data is String
          ? jsonDecode(options.data as String) as Map<String, dynamic>
          : (options.data as Map<String, dynamic>);
      expect(payload['code'], 'code-1');
      expect(payload['state'], 'st-1');
      expect(payload['redirect_uri'], 'ai-knowledge-companion://oauth/callback');
      return {
        'status': 'ok',
        'data': {'kind': 'notion', 'connected': true},
      };
    });

    await _client(adapter).exchangePluginToken(
      'u1',
      'notion',
      code: 'code-1',
      state: 'st-1',
      redirectUri: 'ai-knowledge-companion://oauth/callback',
    );
  });

  test('pushDraft POSTs the draft and maps the receipt', () async {
    final adapter = _FakeAdapter((options) {
      expect(options.method, 'POST');
      expect(options.path, '/api/v1/plugins/slack/push');
      final payload = options.data is String
          ? jsonDecode(options.data as String) as Map<String, dynamic>
          : (options.data as Map<String, dynamic>);
      expect(payload['draft'], {'title': 't', 'body': 'b'});
      expect(payload['target'], isNull);
      return {
        'status': 'ok',
        'data': {
          'kind': 'slack',
          'ok': true,
          'target_url': 'https://slack.test/messages/1',
          'external_id': 'msg-1',
        },
      };
    });

    final receipt = await _client(adapter)
        .pushDraft('u1', 'slack', draft: {'title': 't', 'body': 'b'});

    expect(receipt.ok, true);
    expect(receipt.externalId, 'msg-1');
    expect(receipt.targetUrl, 'https://slack.test/messages/1');
  });

  test('disconnectPlugin DELETEs stored credentials', () async {
    final adapter = _FakeAdapter((options) {
      expect(options.method, 'DELETE');
      expect(options.path, '/api/v1/plugins/notion/credentials');
      return {
        'status': 'ok',
        'data': {'kind': 'notion', 'connected': false},
      };
    });

    await _client(adapter).disconnectPlugin('u1', 'notion');
  });
}
