import 'package:ai_knowledge_companion/features/playback/playback_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/playback_fakes.dart';

void main() {
  late FakeSessionAudioPlayer player;
  late ProviderContainer container;

  setUp(() {
    player = FakeSessionAudioPlayer();
    container = ProviderContainer(overrides: [
      sessionAudioPlayerProvider.overrideWithValue(player),
    ]);
    addTearDown(container.dispose);
  });

  test('play loads the source, subscribes, and reports playing', () async {
    final controller =
        container.read(playbackControllerProvider.notifier);

    await controller.play('s1', '/tmp/s1.m4a');

    expect(player.setSourceCalls, 1);
    expect(player.source, '/tmp/s1.m4a');
    expect(player.playing, true);
    final state = container.read(playbackControllerProvider);
    expect(state.sessionId, 's1');
    expect(state.source, '/tmp/s1.m4a');
    expect(state.playing, true);
    expect(state.loading, false);
    expect(state.duration, const Duration(seconds: 30));
  });

  test('replaying the same source resumes without reloading', () async {
    final controller = container.read(playbackControllerProvider.notifier);

    await controller.play('s1', '/tmp/s1.m4a');
    await controller.pause();
    expect(player.playing, false);
    expect(container.read(playbackControllerProvider).playing, false);

    await controller.toggle('s1', '/tmp/s1.m4a');
    expect(player.setSourceCalls, 1);
    expect(player.playing, true);
    expect(container.read(playbackControllerProvider).playing, true);
  });

  test('toggle to a different session loads the new source', () async {
    final controller = container.read(playbackControllerProvider.notifier);

    await controller.play('s1', '/tmp/s1.m4a');
    await controller.toggle('s2', '/tmp/s2.m4a');

    expect(player.setSourceCalls, 2);
    expect(player.source, '/tmp/s2.m4a');
    expect(container.read(playbackControllerProvider).sessionId, 's2');
  });

  test('player position/duration streams update state', () async {
    final controller = container.read(playbackControllerProvider.notifier);
    await controller.play('s1', '/tmp/s1.m4a');

    player.emitPosition(const Duration(seconds: 5));
    await pumpEventQueue();
    expect(
      container.read(playbackControllerProvider).position,
      const Duration(seconds: 5),
    );

    player.emitDuration(const Duration(minutes: 1));
    await pumpEventQueue();
    expect(
      container.read(playbackControllerProvider).duration,
      const Duration(minutes: 1),
    );
  });

  test('seek and setSpeed are forwarded to the player and persisted',
      () async {
    final controller = container.read(playbackControllerProvider.notifier);
    await controller.play('s1', '/tmp/s1.m4a');

    await controller.seek(const Duration(seconds: 10));
    await controller.setSpeed(1.5);

    expect(player.position, const Duration(seconds: 10));
    expect(player.speed, 1.5);
    expect(
      container.read(playbackControllerProvider).position,
      const Duration(seconds: 10),
    );
    expect(container.read(playbackControllerProvider).speed, 1.5);
  });

  test('setSource failure surfaces an error and never marks playing', () async {
    player.failNextSetSource = true;
    final controller = container.read(playbackControllerProvider.notifier);

    await controller.play('s1', '/tmp/s1.m4a');

    final state = container.read(playbackControllerProvider);
    expect(state.error, isNotNull);
    expect(state.playing, false);
    expect(state.loading, false);
  });

  test('error stream from the player clears playing state', () async {
    final controller = container.read(playbackControllerProvider.notifier);
    await controller.play('s1', '/tmp/s1.m4a');

    player.emitError();
    await pumpEventQueue();

    final state = container.read(playbackControllerProvider);
    expect(state.playing, false);
    expect(state.error, isNotNull);
  });

  test('stop forgets the source and stops playback', () async {
    final controller = container.read(playbackControllerProvider.notifier);
    await controller.play('s1', '/tmp/s1.m4a');

    await controller.stop();

    expect(player.playing, false);
    expect(container.read(playbackControllerProvider).hasSource, false);
    expect(container.read(playbackControllerProvider).sessionId, isNull);
  });

  test('stopForSession only stops the matching session', () async {
    final controller = container.read(playbackControllerProvider.notifier);
    await controller.play('s1', '/tmp/s1.m4a');

    await controller.stopForSession('other');
    expect(player.playing, true);
    expect(container.read(playbackControllerProvider).hasSource, true);

    await controller.stopForSession('s1');
    expect(player.playing, false);
    expect(container.read(playbackControllerProvider).hasSource, false);
  });

  test('disposing the container disposes the player', () async {
    await container.read(playbackControllerProvider.notifier).play(
          's1',
          '/tmp/s1.m4a',
        );
    container.dispose();
    // _dispose is fire-and-forget; give it a chance to run.
    await pumpEventQueue();
    expect(player.disposed, isTrue);
  });
}
