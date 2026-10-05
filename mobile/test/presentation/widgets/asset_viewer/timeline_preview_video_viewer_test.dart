import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/video_viewer.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/is_motion_video_playing.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/services/gcast.service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:native_video_player/native_video_player.dart';

import '../../../infrastructure/repository.mock.dart';
import '../../../service.mocks.dart';
import '../../../unit/factories/remote_asset_factory.dart';

class _MockVideoController extends Mock implements NativeVideoPlayerController {}

class _PlaybackInfo extends Fake implements PlaybackInfo {
  _PlaybackInfo(this.status);

  @override
  final PlaybackStatus status;

  @override
  int get position => 0;
}

void main() {
  late MockAssetService assetService;
  late MockStorageRepository storageRepository;
  late ProviderContainer container;
  late Directory temporaryDirectory;
  late String filePath;
  late RemoteAsset asset;
  late _MockVideoController controller;
  late ChangeNotifier ready;
  late ChangeNotifier ended;
  late ValueNotifier<int> position;
  late ValueNotifier<PlaybackStatus> status;
  late ValueNotifier<String?> error;
  late List<String> calls;
  late int completions;
  late Drift db;
  const wakelockChannel = 'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    registerFallbackValue(RemoteAssetFactory.create());
    registerFallbackValue(
      LocalAsset(
        id: 'local-live-photo',
        name: 'apple.heic',
        type: AssetType.image,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        playbackStyle: AssetPlaybackStyle.livePhoto,
        isEdited: false,
      ),
    );
    registerFallbackValue(await VideoSource.init(path: 'test.mp4', type: VideoSourceType.file));
    db = Drift(drift.DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await SettingsRepository.ensureInitialized(db);
    await StoreService.init(storeRepository: StoreRepository(db), listenUpdates: false);
    await Store.put(StoreKey.serverEndpoint, 'https://example.test/api');
    await SettingsRepository.instance.write(SettingsKey.viewerLoadOriginalVideo, true);
    await SettingsRepository.instance.write(SettingsKey.networkCustomHeaders, {'x-test-auth': 'test-value'});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler(
      wakelockChannel,
      (_) async => const StandardMessageCodec().encodeMessage([null]),
    );
  });

  tearDownAll(() async {
    await SettingsRepository.reset();
    await Store.clear();
    await db.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler(wakelockChannel, null);
  });

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    asset = RemoteAssetFactory.create().copyWith(livePhotoVideoId: 'paired-video');
    assetService = MockAssetService();
    storageRepository = MockStorageRepository();
    when(() => assetService.getAsset(any())).thenAnswer((_) async => asset);
    container = ProviderContainer(
      overrides: [
        assetServiceProvider.overrideWithValue(assetService),
        storageRepositoryProvider.overrideWithValue(storageRepository),
        gCastServiceProvider.overrideWithValue(MockGCastService()),
      ],
    );
    temporaryDirectory = await Directory.systemTemp.createTemp('gallery-timeline-preview-');
    filePath = '${temporaryDirectory.path}/motion.mp4';
    await File(filePath).writeAsBytes([0]);
    ready = ChangeNotifier();
    ended = ChangeNotifier();
    position = ValueNotifier(0);
    status = ValueNotifier(PlaybackStatus.stopped);
    error = ValueNotifier(null);
    calls = [];
    completions = 0;
    controller = _MockVideoController();
    when(() => controller.onPlaybackReady).thenReturn(ready);
    when(() => controller.onPlaybackEnded).thenReturn(ended);
    when(() => controller.onPlaybackPositionChanged).thenReturn(position);
    when(() => controller.onPlaybackStatusChanged).thenReturn(status);
    when(() => controller.onError).thenReturn(error);
    when(() => controller.videoSource).thenReturn(null);
    when(() => controller.videoInfo).thenReturn(VideoInfo.fromJson({'height': 1080, 'width': 1920, 'duration': 2000}));
    when(() => controller.playbackInfo).thenAnswer((_) => _PlaybackInfo(status.value));
    when(() => controller.setVolume(any())).thenAnswer((invocation) async {
      calls.add('volume:${invocation.positionalArguments.single}');
    });
    when(() => controller.setLoop(any())).thenAnswer((invocation) async {
      calls.add('loop:${invocation.positionalArguments.single}');
    });
    when(() => controller.loadVideoSource(any())).thenAnswer((_) async {
      calls.add('load');
      ready.notifyListeners();
    });
    when(() => controller.play()).thenAnswer((_) async {
      calls.add('play');
      status.value = PlaybackStatus.playing;
    });
    when(() => controller.pause()).thenAnswer((_) async {
      calls.add('pause');
      status.value = PlaybackStatus.paused;
    });
    when(() => controller.isPlaying()).thenAnswer((_) async => status.value == PlaybackStatus.playing);
  });

  tearDown(() async {
    container.dispose();
    ready.dispose();
    ended.dispose();
    position.dispose();
    status.dispose();
    error.dispose();
    await temporaryDirectory.delete(recursive: true);
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      null,
    );
  });

  Future<void> mountPreview(
    WidgetTester tester, {
    String? sourcePath,
    bool useLocalFile = true,
    BaseAsset? previewAsset,
    bool Function()? previewIsActive,
    bool? loopOverride,
    bool timelinePreview = true,
    bool playbackPaused = false,
    bool isCurrent = true,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: SizedBox(
            width: 150,
            height: 150,
            child: NativeVideoViewer(
              asset: previewAsset ?? asset,
              localFilePath: useLocalFile ? sourcePath ?? filePath : null,
              image: const ColoredBox(color: Colors.blue),
              isCurrent: isCurrent,
              timelinePreview: timelinePreview,
              playbackPaused: playbackPaused,
              forceAutoPlay: !timelinePreview,
              showControls: false,
              onPreviewCompleted: () => completions++,
              previewIsActive: previewIsActive,
              loopOverride: loopOverride,
            ),
          ),
        ),
      ),
    );
    // The native view is replaced by its normal unsupported-platform placeholder
    // on Linux. Inject the controller through the production ready callback.
    tester.widget<NativeVideoPlayerView>(find.byType(NativeVideoPlayerView)).onViewReady!(controller);
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
  }

  void useSourcePlatform(TargetPlatform platform) {
    debugDefaultTargetPlatformOverride = platform;
    // Keep platform creation pending while routing sources through the existing
    // widget/controller boundary. These tests do not create a native decoder.
    final pendingCreate = Completer<Object?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      (call) async => call.method == 'create' ? pendingCreate.future : null,
    );
  }

  Future<void> finishMemoryViewer(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    // This fixture owns its ProviderContainer. Dispose it before Flutter checks
    // timer invariants, including the normal player's buffering timer.
    container.dispose();
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;
  }

  testWidgets('memory menu pause resumes the loaded video without fetching or reloading it', (tester) async {
    asset = asset.copyWith(type: .video, livePhotoVideoId: null);
    await mountPreview(tester, timelinePreview: false);
    expect(calls.where((call) => call == 'play'), hasLength(1));
    await mountPreview(tester, timelinePreview: false, playbackPaused: true);
    expect(calls.last, 'pause');
    expect(container.read(videoPlayerProvider(asset.id)).status, VideoPlaybackStatus.paused);
    await mountPreview(tester, timelinePreview: false);
    expect(calls.last, 'play');
    expect(calls.where((call) => call == 'load'), hasLength(1));
    verify(() => assetService.getAsset(any())).called(1);
    await finishMemoryViewer(tester);
  });

  testWidgets('a memory video already paused before the menu stays paused on dismissal', (tester) async {
    asset = asset.copyWith(type: .video, livePhotoVideoId: null);
    await mountPreview(tester, timelinePreview: false);
    await controller.pause();
    await mountPreview(tester, timelinePreview: false, playbackPaused: true);
    await mountPreview(tester, timelinePreview: false);
    expect(calls.where((call) => call == 'play'), hasLength(1));
    expect(calls.where((call) => call == 'load'), hasLength(1));
    await finishMemoryViewer(tester);
  });

  testWidgets('readiness during the memory menu defers autoplay until dismissal', (tester) async {
    asset = asset.copyWith(type: .video, livePhotoVideoId: null);
    when(() => controller.loadVideoSource(any())).thenAnswer((_) async => calls.add('load'));
    await mountPreview(tester, timelinePreview: false);
    await mountPreview(tester, timelinePreview: false, playbackPaused: true);
    ready.notifyListeners();
    await tester.pump();
    expect(calls, isNot(contains('play')));
    await mountPreview(tester, timelinePreview: false);
    expect(calls.where((call) => call == 'play'), hasLength(1));
    expect(calls.where((call) => call == 'load'), hasLength(1));
    await finishMemoryViewer(tester);
  });

  testWidgets('memory menu dismissal waits for a pending native pause before resuming', (tester) async {
    asset = asset.copyWith(type: .video, livePhotoVideoId: null);
    await mountPreview(tester, timelinePreview: false);
    final acknowledgement = Completer<void>();
    when(() => controller.pause()).thenAnswer((_) async {
      calls.add('pending-pause');
      await acknowledgement.future;
      status.value = PlaybackStatus.paused;
    });
    await mountPreview(tester, timelinePreview: false, playbackPaused: true);
    await mountPreview(tester, timelinePreview: false);
    expect(calls.where((call) => call == 'play'), hasLength(1));
    acknowledgement.complete();
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
    expect(calls.where((call) => call == 'play'), hasLength(2));
    expect(calls.last, 'play');
    await finishMemoryViewer(tester);
  });

  testWidgets('closing the memory viewer while a pause is pending never resumes its video', (tester) async {
    asset = asset.copyWith(type: .video, livePhotoVideoId: null);
    await mountPreview(tester, timelinePreview: false);
    final acknowledgement = Completer<void>();
    when(() => controller.pause()).thenAnswer((_) async {
      calls.add('pending-pause');
      await acknowledgement.future;
      status.value = PlaybackStatus.paused;
    });
    await mountPreview(tester, timelinePreview: false, playbackPaused: true);
    await mountPreview(tester, timelinePreview: false);
    await tester.pumpWidget(const SizedBox());
    acknowledgement.complete();
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
    expect(calls.where((call) => call == 'play'), hasLength(1));
    await finishMemoryViewer(tester);
  });

  testWidgets('rapidly reopening the memory menu serializes pauses before the final resume', (tester) async {
    asset = asset.copyWith(type: .video, livePhotoVideoId: null);
    await mountPreview(tester, timelinePreview: false);
    final firstPause = Completer<void>();
    final secondPause = Completer<void>();
    var pauseCount = 0;
    when(() => controller.pause()).thenAnswer((_) async {
      final acknowledgement = ++pauseCount == 1 ? firstPause : secondPause;
      calls.add('pending-pause:$pauseCount');
      await acknowledgement.future;
      status.value = PlaybackStatus.paused;
    });
    await mountPreview(tester, timelinePreview: false, playbackPaused: true);
    await mountPreview(tester, timelinePreview: false);
    await mountPreview(tester, timelinePreview: false, playbackPaused: true);
    await mountPreview(tester, timelinePreview: false);
    expect(pauseCount, 1);
    firstPause.complete();
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
    expect(pauseCount, 2);
    expect(calls.where((call) => call == 'play'), hasLength(1));
    secondPause.complete();
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
    expect(calls.where((call) => call == 'play'), hasLength(2));
    expect(calls.last, 'play');
    await finishMemoryViewer(tester);
  });

  testWidgets('foregrounding the app cannot play a memory video while its menu is open', (tester) async {
    asset = asset.copyWith(type: .video, livePhotoVideoId: null);
    await mountPreview(tester, timelinePreview: false);
    await mountPreview(tester, timelinePreview: false, playbackPaused: true);
    final previousPlays = calls.where((call) => call == 'play').length;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
    expect(calls.where((call) => call == 'play'), hasLength(previousPlays));
    await finishMemoryViewer(tester);
  });

  testWidgets('a delayed pause acknowledgement and background menu dismissal wait for foreground', (tester) async {
    asset = asset.copyWith(type: .video, livePhotoVideoId: null);
    await mountPreview(tester, timelinePreview: false);
    final acknowledgement = Completer<void>();
    when(() => controller.pause()).thenAnswer((_) async {
      calls.add('pending-pause');
      await acknowledgement.future;
      status.value = PlaybackStatus.paused;
    });
    await mountPreview(tester, timelinePreview: false, playbackPaused: true);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await mountPreview(tester, timelinePreview: false);
    acknowledgement.complete();
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
    expect(calls.where((call) => call == 'play'), hasLength(1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
    expect(calls.where((call) => call == 'play'), hasLength(2));
    expect(calls.last, 'play');
    await finishMemoryViewer(tester);
  });

  testWidgets('a memory video becoming non-current while backgrounded never resumes on foreground', (tester) async {
    asset = asset.copyWith(type: .video, livePhotoVideoId: null);
    await mountPreview(tester, timelinePreview: false);
    final acknowledgement = Completer<void>();
    when(() => controller.pause()).thenAnswer((_) async {
      calls.add('pending-pause');
      await acknowledgement.future;
      status.value = PlaybackStatus.paused;
    });
    await mountPreview(tester, timelinePreview: false, playbackPaused: true);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await mountPreview(tester, timelinePreview: false, isCurrent: false);
    acknowledgement.complete();
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
    expect(calls.where((call) => call == 'play'), hasLength(1));
    await finishMemoryViewer(tester);
  });

  testWidgets('mutes and disables looping before loading or playing, with isolated viewer state', (tester) async {
    container.read(isPlayingMotionVideoProvider.notifier).playing = true;
    await mountPreview(tester);

    expect(calls.take(4), ['volume:0.0', 'loop:false', 'load', 'play']);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(container.read(isPlayingMotionVideoProvider), isTrue);
    expect(container.read(videoPlayerProvider(asset.id)).status, VideoPlaybackStatus.paused);
    expect(container.read(timelinePreviewVideoPlayerProvider(asset.id)).status, VideoPlaybackStatus.playing);

    ended.notifyListeners();
    ended.notifyListeners();
    await tester.pump();
    expect(completions, 1);
    expect(container.read(isPlayingMotionVideoProvider), isTrue);
    expect(calls.last, 'pause');
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('plays one shot and ignores repeated readiness and completion events while still mounted', (
    tester,
  ) async {
    await mountPreview(tester);
    ready.notifyListeners();
    ready.notifyListeners();
    await tester.pump();

    expect(calls.where((call) => call == 'play'), hasLength(1));
    expect(completions, 0);

    ended.notifyListeners();
    await tester.pump();
    expect(find.byType(NativeVideoViewer), findsOneWidget);
    expect(completions, 1);
    expect(calls.last, 'pause');

    // Native buffering/readiness events can arrive after completion before the
    // scope rebuild removes the platform view. They must never replay the clip.
    ready.notifyListeners();
    ended.notifyListeners();
    ready.notifyListeners();
    await tester.pump(const Duration(seconds: 1));

    expect(calls.where((call) => call == 'play'), hasLength(1));
    expect(calls.where((call) => call == 'load'), hasLength(1));
    expect(calls.where((call) => call.startsWith('loop:')), ['loop:false']);
    expect(completions, 1);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('timeline previews never loop even when viewer preferences and loop override request looping', (
    tester,
  ) async {
    final previousLoopSetting = SettingsRepository.instance.appConfig.viewer.loopVideo;
    await SettingsRepository.instance.write(SettingsKey.viewerLoopVideo, true);
    try {
      await mountPreview(tester, loopOverride: true);
      expect(SettingsRepository.instance.appConfig.viewer.loopVideo, isTrue);
      expect(calls.take(4), ['volume:0.0', 'loop:false', 'load', 'play']);
      verifyNever(() => controller.setLoop(true));

      ended.notifyListeners();
      await tester.pump();
      ready.notifyListeners();
      await tester.pump();
      expect(completions, 1);
      expect(calls.where((call) => call == 'play'), hasLength(1));
      expect(calls.last, 'pause');
    } finally {
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
      await SettingsRepository.instance.write(SettingsKey.viewerLoopVideo, previousLoopSetting);
    }
  });

  testWidgets('removing a preview detaches native event listeners and pauses playback', (tester) async {
    await mountPreview(tester);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
    final previousCalls = calls.length;

    ready.notifyListeners();
    ended.notifyListeners();
    error.value = 'late native error';
    await tester.pump();

    expect(calls, contains('pause'));
    expect(calls.length, previousCalls);
    expect(completions, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('source failures complete the preview once', (tester) async {
    await mountPreview(tester, sourcePath: '${temporaryDirectory.path}/missing.mp4');
    expect(completions, 1);
    expect(calls, isNot(contains('load')));
    error.value = 'native error';
    ended.notifyListeners();
    await tester.pump();
    expect(completions, 1);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('native playback errors release the preview and suppress late readiness', (tester) async {
    await mountPreview(tester);
    error.value = 'decoder failure';
    ready.notifyListeners();
    ended.notifyListeners();
    await tester.pump();

    expect(completions, 1);
    expect(calls.where((call) => call == 'play'), hasLength(1));
    expect(calls.last, 'pause');
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('failed native loading returns to the thumbnail without playing', (tester) async {
    when(() => controller.loadVideoSource(any())).thenThrow(StateError('load failed'));
    await mountPreview(tester);
    expect(completions, 1);
    expect(calls, isNot(contains('play')));
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('removal while muting prevents subsequent load and autoplay', (tester) async {
    final muted = Completer<void>();
    when(() => controller.setVolume(any())).thenAnswer((_) => muted.future);
    await mountPreview(tester);
    ready.notifyListeners();
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
    muted.complete();
    await tester.pump();

    expect(calls, isNot(contains('load')));
    expect(calls, isNot(contains('play')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('revoking the scope token prevents late readiness from playing a still-mounted preview', (tester) async {
    var active = true;
    when(() => controller.loadVideoSource(any())).thenAnswer((_) async => calls.add('load'));
    await mountPreview(tester, previewIsActive: () => active);
    expect(calls, contains('load'));
    expect(find.byType(NativeVideoViewer), findsOneWidget);

    active = false;
    ready.notifyListeners();
    await tester.pump();

    expect(calls, isNot(contains('play')));
    expect(find.byType(NativeVideoViewer), findsOneWidget);
    expect(completions, 0);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a stale source cannot load or play after the preview is removed', (tester) async {
    final pendingAsset = Completer<BaseAsset?>();
    when(() => assetService.getAsset(any())).thenAnswer((_) => pendingAsset.future);
    await mountPreview(tester);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
    pendingAsset.complete(asset);
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
    expect(calls, isNot(contains('load')));
    expect(calls, isNot(contains('play')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving the foreground pauses and completes instead of resuming behind another route', (tester) async {
    await mountPreview(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    final playCount = calls.where((call) => call == 'play').length;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(completions, 1);
    expect(calls.last, 'pause');
    expect(calls.where((call) => call == 'play').length, playCount);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('${platform.name} paired live photo uses authenticated encoded playback even with original enabled', (
      tester,
    ) async {
      useSourcePlatform(platform);
      asset = RemoteAssetFactory.create(
        name: platform == TargetPlatform.android ? 'samsung.jpg' : 'apple.heic',
      ).copyWith(livePhotoVideoId: 'paired-${platform.name}-video');
      await mountPreview(tester, useLocalFile: false);

      final source = verify(() => controller.loadVideoSource(captureAny())).captured.single as VideoSource;
      expect(source.type, VideoSourceType.network);
      expect(source.path, 'https://example.test/api/assets/paired-${platform.name}-video/video/playback');
      expect(source.headers, {'x-test-auth': 'test-value'});
      expect(SettingsRepository.instance.appConfig.viewer.loadOriginalVideo, isTrue);
      expect(completions, 0);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('merged Android motion photo bypasses the local image and reuses the server video pair', (tester) async {
    useSourcePlatform(TargetPlatform.android);
    asset = RemoteAssetFactory.create(
      localId: 'local-samsung-photo',
    ).copyWith(livePhotoVideoId: 'samsung-motion-video');
    await mountPreview(tester, useLocalFile: false);

    final source = verify(() => controller.loadVideoSource(captureAny())).captured.single as VideoSource;
    expect(source.path, 'https://example.test/api/assets/samsung-motion-video/video/playback');
    verifyNever(() => assetService.getLocalAsset(any()));
    expect(completions, 0);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a local-only Android motion image without a server pair safely stays static', (tester) async {
    useSourcePlatform(TargetPlatform.android);
    final local = LocalAsset(
      id: 'local-only-motion',
      name: 'samsung.jpg',
      type: AssetType.image,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      playbackStyle: AssetPlaybackStyle.livePhoto,
      isEdited: false,
    );
    when(() => assetService.getAsset(local)).thenAnswer((_) async => local);
    await mountPreview(tester, useLocalFile: false, previewAsset: local);

    expect(completions, 1);
    verifyNever(() => controller.loadVideoSource(any()));
    expect(calls, isNot(contains('play')));
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  LocalAsset iosLocalLivePhoto() => LocalAsset(
    id: 'local-live-photo',
    name: 'apple.heic',
    type: AssetType.image,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
    playbackStyle: AssetPlaybackStyle.livePhoto,
    isEdited: false,
  );

  testWidgets('iOS cached still image with an iCloud-only motion part uses the remote pair without local export', (
    tester,
  ) async {
    useSourcePlatform(TargetPlatform.iOS);
    final local = iosLocalLivePhoto();
    asset = RemoteAssetFactory.create(localId: local.id).copyWith(livePhotoVideoId: 'remote-apple-motion');
    when(() => assetService.getLocalAsset(local.id)).thenAnswer((_) async => local);
    when(() => storageRepository.isAssetAvailableLocally(local.id)).thenAnswer((_) async => true);
    when(() => storageRepository.isAssetAvailableLocally(local.id, withSubtype: true)).thenAnswer((_) async => false);

    await mountPreview(tester, useLocalFile: false);

    verify(() => storageRepository.isAssetAvailableLocally(local.id, withSubtype: true)).called(1);
    verifyNever(() => storageRepository.getMotionFileForAsset(any()));
    verifyNever(() => storageRepository.getFileForAsset(any()));
    verifyNever(() => storageRepository.loadMotionFileFromCloud(any(), progressHandler: any(named: 'progressHandler')));
    final source = verify(() => controller.loadVideoSource(captureAny())).captured.single as VideoSource;
    expect(source.type, VideoSourceType.network);
    expect(source.path, 'https://example.test/api/assets/remote-apple-motion/video/playback');
    expect(completions, 0);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('iOS locally cached motion subtype uses the existing paired-file export', (tester) async {
    useSourcePlatform(TargetPlatform.iOS);
    final local = iosLocalLivePhoto();
    when(() => assetService.getAsset(local)).thenAnswer((_) async => local);
    when(() => storageRepository.isAssetAvailableLocally(local.id, withSubtype: true)).thenAnswer((_) async => true);
    when(() => storageRepository.getMotionFileForAsset(local)).thenAnswer((_) async => File(filePath));

    await mountPreview(tester, useLocalFile: false, previewAsset: local);

    verify(() => storageRepository.isAssetAvailableLocally(local.id, withSubtype: true)).called(1);
    verify(() => storageRepository.getMotionFileForAsset(local)).called(1);
    verifyNever(() => storageRepository.getFileForAsset(any()));
    final source = verify(() => controller.loadVideoSource(captureAny())).captured.single as VideoSource;
    expect(source.type, VideoSourceType.file);
    expect(source.path, filePath);
    expect(completions, 0);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the preview watchdog releases a stalled native source after eight seconds', (tester) async {
    when(() => controller.loadVideoSource(any())).thenAnswer((_) async => calls.add('load'));
    await mountPreview(tester);
    await tester.pump(const Duration(seconds: 8));

    expect(completions, 1);
    expect(calls.last, 'pause');
    ready.notifyListeners();
    await tester.pump();
    expect(calls, isNot(contains('play')));
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });
}
