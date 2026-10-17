import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:mocktail/mocktail.dart';
import 'package:native_video_player/native_video_player.dart';

class _MockVideoController extends Mock implements NativeVideoPlayerController {}

class _PlaybackInfo extends Fake implements PlaybackInfo {
  _PlaybackInfo(this.status);

  @override
  final PlaybackStatus status;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a native play acknowledgement after disposal cannot create a buffering timer', () {
    fakeAsync((async) {
      final controller = _MockVideoController();
      final acknowledgement = Completer<void>();
      when(() => controller.play()).thenAnswer((_) => acknowledgement.future);
      final notifier = VideoPlayerNotifier(wakelockEnabled: false);
      notifier.attachController(controller);
      unawaited(notifier.play());
      async.flushMicrotasks();
      verify(() => controller.play()).called(1);
      notifier.dispose();
      acknowledgement.complete();
      async.flushMicrotasks();
      expect(async.nonPeriodicTimerCount, 0);
    });
  });

  test('preview provider has separate controller ownership and never changes the viewer wake lock', () async {
    const wakelockChannel = 'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';
    var wakeLockCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler(wakelockChannel, (
      message,
    ) async {
      wakeLockCalls++;
      return const StandardMessageCodec().encodeMessage([null]);
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler(wakelockChannel, null);
    });

    final container = ProviderContainer();
    final viewerSubscription = container.listen(videoPlayerProvider('same-asset'), (_, _) {});
    final previewSubscription = container.listen(timelinePreviewVideoPlayerProvider('same-asset'), (_, _) {});
    final viewer = container.read(videoPlayerProvider('same-asset').notifier);
    final preview = container.read(timelinePreviewVideoPlayerProvider('same-asset').notifier);
    final controller = _MockVideoController();
    when(() => controller.playbackInfo).thenReturn(_PlaybackInfo(PlaybackStatus.playing));

    expect(preview, isNot(same(viewer)));
    preview.attachController(controller);
    preview.onNativeStatusChanged();
    preview.onNativePlaybackEnded();
    expect(container.read(videoPlayerProvider('same-asset')).status, VideoPlaybackStatus.paused);

    previewSubscription.close();
    await container.pump();
    expect(wakeLockCalls, 0);

    viewer.attachController(controller);
    viewer.onNativeStatusChanged();
    await pumpEventQueue();
    expect(wakeLockCalls, 1, reason: 'The existing asset viewer still owns its wake lock');
    viewerSubscription.close();
    container.dispose();
    await pumpEventQueue();
    expect(wakeLockCalls, 2);
  });
}
