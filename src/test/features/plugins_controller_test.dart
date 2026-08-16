import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:ai_knowledge_companion/features/plugins/plugins_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/analysis_fakes.dart';

class _FakeAuth implements AuthRepository {
  _FakeAuth(this.id);

  final String? id;

  @override
  String? get currentUserId => id;

  @override
  Stream<String?> watchUserId() => const Stream.empty();

  @override
  Future<void> signInWithGoogle() async {}

  @override
  Future<void> signOut() async {}
}

void main() {
  late FakeEngineGateway engine;
  late ProviderContainer container;

  setUp(() {
    engine = FakeEngineGateway();
    container = ProviderContainer(overrides: [
      engineGatewayProvider.overrideWithValue(engine),
      authRepositoryProvider.overrideWithValue(_FakeAuth('u1')),
    ]);
    addTearDown(container.dispose);
  });

  test('build lists plugin targets with connection status', () async {
    final statuses = await container.read(pluginsProvider.future);

    expect(statuses, hasLength(2));
    expect(statuses.first.kind, 'notion');
    expect(statuses.first.connected, false);
    expect(statuses.map((s) => s.connected), everyElement(false));
  });

  test('signed-out users get an empty plugin list', () async {
    final local = ProviderContainer(overrides: [
      engineGatewayProvider.overrideWithValue(engine),
      authRepositoryProvider.overrideWithValue(_FakeAuth(null)),
    ]);
    addTearDown(local.dispose);

    final statuses = await local.read(pluginsProvider.future);
    expect(statuses, isEmpty);
  });

  test('connect returns an authorization URL with the app redirect URI',
      () async {
    final url = await container
        .read(pluginsProvider.notifier)
        .connect('notion');

    expect(url.kind, 'notion');
    expect(url.url, contains('kind=notion'));
    expect(url.state, 'state-1');
    expect(engine.lastAuthRedirectUri, pluginOAuthRedirectUri);
  });

  test('exchangeToken connects the target and refreshes the status list',
      () async {
    final notifier = container.read(pluginsProvider.notifier);
    final url = await notifier.connect('slack');

    await notifier.exchangeToken('slack', code: 'code-1', state: url.state);

    final statuses = container.read(pluginsProvider).value;
    final slack = statuses!.singleWhere((s) => s.kind == 'slack');
    expect(slack.connected, true);
    expect(statuses.singleWhere((s) => s.kind == 'notion').connected, false);
  });

  test('disconnect revokes credentials and refreshes the status list',
      () async {
    engine.connectedPlugins.addAll(['notion', 'slack']);
    await container.read(pluginsProvider.future);
    await container.read(pluginsProvider.notifier).disconnect('notion');

    expect(engine.disconnectedKinds, ['notion']);
    final statuses = container.read(pluginsProvider).value;
    expect(statuses!.singleWhere((s) => s.kind == 'notion').connected, false);
    expect(statuses.singleWhere((s) => s.kind == 'slack').connected, true);
  });

  test('pushDraft forwards the draft and returns the receipt', () async {
    final receipt = await container
        .read(pluginsProvider.notifier)
        .pushDraft('notion', draft: {'title': 't', 'body': 'b'});

    expect(engine.lastPushedDraft, {'title': 't', 'body': 'b'});
    expect(receipt.ok, true);
    expect(receipt.kind, 'notion');
    expect(receipt.externalId, 'ext-1');
  });
}
