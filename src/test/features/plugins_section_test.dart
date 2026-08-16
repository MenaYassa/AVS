import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:ai_knowledge_companion/features/plugins/plugins_section.dart';
import 'package:flutter/material.dart';
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

Widget _app(FakeEngineGateway engine) => ProviderScope(
      overrides: [
        engineGatewayProvider.overrideWithValue(engine),
        authRepositoryProvider.overrideWithValue(_FakeAuth('u1')),
      ],
      child: const MaterialApp(home: Scaffold(body: PluginsSection())),
    );

void main() {
  testWidgets('shows targets with their connection state', (tester) async {
    final engine = FakeEngineGateway();
    await tester.pumpWidget(_app(engine));
    await tester.pumpAndSettle();

    expect(find.text('Plugins'), findsOneWidget);
    expect(find.text('Notion'), findsOneWidget);
    expect(find.text('Slack'), findsOneWidget);
    expect(find.text('Not connected'), findsNWidgets(2));
    expect(find.widgetWithText(FilledButton, 'Connect'), findsNWidgets(2));
  });

  testWidgets('connect flow starts OAuth and marks the target connected',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final engine = FakeEngineGateway();
    await tester.pumpWidget(_app(engine));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Connect').first);
    await tester.pumpAndSettle();

    expect(find.text('Connect Notion'), findsOneWidget);
    expect(find.textContaining('https://oauth.example'), findsOneWidget);

    await tester.enterText(
        find.widgetWithText(TextField, 'Authorization code'), 'code-123');
    await tester.tap(find.widgetWithText(FilledButton, 'Connect').last);
    await tester.pumpAndSettle();

    expect(engine.connectedPlugins, contains('notion'));
    expect(find.text('Connected'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Disconnect'), findsOneWidget);
  });

  testWidgets('disconnect flow revokes credentials with confirmation',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final engine = FakeEngineGateway()..connectedPlugins.addAll(['notion', 'slack']);
    await tester.pumpWidget(_app(engine));
    await tester.pumpAndSettle();

    expect(find.text('Connected'), findsNWidgets(2));

    await tester.tap(find.widgetWithText(TextButton, 'Disconnect').first);
    await tester.pumpAndSettle();
    expect(find.text('Disconnect Notion?'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Disconnect'));
    await tester.pumpAndSettle();

    expect(engine.disconnectedKinds, ['notion']);
    expect(find.text('Connected'), findsOneWidget);
  });
}
