import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/video_viewer.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/cast.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:mocktail/mocktail.dart';
import 'package:native_video_player/native_video_player.dart';

import '../../../service.mocks.dart';

class _Playback extends Fake implements PlaybackInfo {
  _Playback(this.status, this.position);

  @override
  final PlaybackStatus status;
  @override
  final int position;
}

/// Exercises the real widget's listener ordering using real notifier events;
/// no platform decoder, media library or HTTP request is involved.
class _Controller extends Mock implements NativeVideoPlayerController {
  @override
  final onPlaybackReady = ChangeNotifier();
  @override
  final onPlaybackEnded = ChangeNotifier();
  @override
  final onPlaybackStatusChanged = ValueNotifier<PlaybackStatus>(PlaybackStatus.stopped);
  @override
  final onPlaybackPositionChanged = ValueNotifier<int>(0);
  @override
  final onError = ValueNotifier<String?>(null);

  final commands = <String>[];
  final sources = <VideoSource>[];
  Completer<void>? loadAcknowledgement;
  VoidCallback? onLoad;
  bool failLoad = false;
  bool failPlay = false;

  @override
  VideoSource? get videoSource => sources.lastOrNull;

  @override
  VideoInfo get videoInfo => VideoInfo.fromJson({'width': 1920, 'height': 1080, 'duration': 1600});

  @override
  PlaybackInfo get playbackInfo => _Playback(onPlaybackStatusChanged.value, onPlaybackPositionChanged.value);

  @override
  Future<void> loadVideoSource(VideoSource source) async {
    commands.add('load');
    if (failLoad) {
      throw PlatformException(code: 'LOCAL_VIDEO_UNAVAILABLE');
    }
    sources.add(source);
    onLoad?.call();
    await loadAcknowledgement?.future;
  }

  @override
  Future<void> setVolume(double volume) async => commands.add('volume:$volume');

  @override
  Future<void> setLoop(bool loop) async => commands.add('loop:$loop');

  @override
  Future<void> play() async {
    commands.add('play');
    if (failPlay) {
      throw PlatformException(code: 'LOCAL_PLAYBACK_ERROR');
    }
    onPlaybackStatusChanged.value = PlaybackStatus.playing;
  }

  @override
  Future<void> pause() async {
    commands.add('pause');
    onPlaybackStatusChanged.value = PlaybackStatus.paused;
  }

  @override
  Future<bool> isPlaying() async => onPlaybackStatusChanged.value == PlaybackStatus.playing;

  @override
  Future<void> seekTo(int position) async => onPlaybackPositionChanged.value = position;
}

class _NativeSurface extends StatefulWidget {
  const _NativeSurface({required this.controller, required this.onReady});

  final _Controller controller;
  final ValueChanged<NativeVideoPlayerController> onReady;

  @override
  State<_NativeSurface> createState() => _NativeSurfaceState();
}

class _NativeSurfaceState extends State<_NativeSurface> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onReady(widget.controller);
      }
    });
  }

  @override
  Widget build(BuildContext context) => const ColoredBox(key: Key('native-surface'), color: Colors.black);
}

LocalAsset _local({String? remoteId}) => LocalAsset(
  id: 'device-live',
  remoteId: remoteId,
  name: 'synthetic-live.jpg',
  checksum: 'synthetic-checksum',
  type: AssetType.image,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  playbackStyle: AssetPlaybackStyle.livePhoto,
  isEdited: false,
);

RemoteAsset _remote() => RemoteAsset(
  id: 'server-live',
  name: 'synthetic-remote.jpg',
  checksum: 'remote-checksum',
  ownerId: 'test-owner',
  type: AssetType.image,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  livePhotoVideoId: 'server-motion',
  isEdited: false,
);

void testAndroidWidgets(String description, WidgetTesterCallback callback) {
  testWidgets(description, callback, variant: TargetPlatformVariant.only(TargetPlatform.android));
}

void main() {
  late Drift db;
  late StoreService store;
  late MockAssetService assets;
  late _Controller controller;
  var surfaces = 0;
  var started = 0;
  var completed = 0;
  var failed = 0;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    registerFallbackValue(_local());
    db = Drift(drift.DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await SettingsRepository.ensureInitialized(db);
    store = await StoreService.init(storeRepository: StoreRepository(db), listenUpdates: false);
    await Store.put(StoreKey.serverEndpoint, 'https://example.invalid/api');
    const channel = 'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler(
      channel,
      (_) async => const StandardMessageCodec().encodeMessage([null]),
    );
  });

  setUp(() {
    assets = MockAssetService();
    when(
      () => assets.getAsset(any()),
    ).thenAnswer((invocation) async => invocation.positionalArguments.first as BaseAsset);
    controller = _Controller();
    surfaces = started = completed = failed = 0;
  });

  tearDownAll(() async {
    const channel = 'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler(channel, null);
    await SettingsRepository.reset();
    await store.dispose();
    await db.close();
  });

  Future<File> syntheticFile(WidgetTester tester) async {
    final file = await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp('foto-build19-player-');
      final file = File('${directory.path}/local motion #1.mp4');
      await file.writeAsBytes([0, 0, 0, 8, 102, 116, 121, 112]);
      return file;
    });
    addTearDown(() async => file!.parent.delete(recursive: true));
    return file!;
  }

  Widget host({
    required BaseAsset asset,
    String? path,
    bool timeline = true,
    bool current = true,
    bool Function()? active,
  }) => ProviderScope(
    overrides: [
      appConfigProvider.overrideWithValue(const AppConfig().copyWith.viewer(autoPlayVideo: false)),
      assetServiceProvider.overrideWithValue(assets),
      castProvider.overrideWith((_) => CastNotifier(MockGCastService())),
    ],
    child: MaterialApp(
      home: SizedBox.square(
        dimension: 160,
        child: NativeVideoViewer(
          key: const Key('video-viewer'),
          asset: asset,
          localFilePath: path,
          image: const ColoredBox(key: Key('still'), color: Colors.green),
          timelinePreview: timeline,
          isCurrent: current,
          showControls: !timeline,
          previewIsActive: active,
          onPreviewStarted: () => started++,
          onPreviewCompleted: () => completed++,
          onPreviewFailed: () => failed++,
          playerViewBuilder: (onReady) {
            surfaces++;
            return _NativeSurface(controller: controller, onReady: onReady);
          },
        ),
      ),
    ),
  );

  Future<void> flushLocalIo(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    await tester.pump();
  }

  Future<void> mount(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(child);
    await flushLocalIo(tester);
    addTearDown(() async {
      if (controller.loadAcknowledgement?.isCompleted == false) {
        controller.loadAcknowledgement!.complete();
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  }

  testAndroidWidgets('cold local source is muted and non-looping before readiness even before native load ACK', (
    tester,
  ) async {
    final file = await syntheticFile(tester);
    controller.loadAcknowledgement = Completer<void>();
    controller.onLoad = controller.onPlaybackReady.notifyListeners;

    await mount(tester, host(asset: _local(), path: file.path));

    expect(controller.commands.take(4), ['volume:0.0', 'loop:false', 'load', 'play']);
    expect(controller.loadAcknowledgement!.isCompleted, isFalse);
    expect(controller.sources.single.type, VideoSourceType.file);
    expect(controller.sources.single.path, file.uri.toString());
    expect(controller.sources.single.headers, isEmpty);
    verifyZeroInteractions(assets);

    controller.onPlaybackReady.notifyListeners();
    await tester.pump();
    expect(controller.commands.where((c) => c == 'play'), hasLength(1));
    expect(started, 0);
    controller.onPlaybackPositionChanged.value = 20;
    await tester.pump();
    controller.onPlaybackPositionChanged.value = 40;
    await tester.pump();
    expect(started, 1);
  });

  testAndroidWidgets('merged preview uses the exact proven local component without remote lookup', (tester) async {
    final file = await syntheticFile(tester);
    controller.onLoad = controller.onPlaybackReady.notifyListeners;
    await mount(
      tester,
      host(
        asset: _local(remoteId: 'server-live'),
        path: file.path,
      ),
    );
    expect(controller.sources.single.type, VideoSourceType.file);
    expect(controller.sources.single.path, file.uri.toString());
    verifyZeroInteractions(assets);
  });

  testAndroidWidgets('remote timeline stays static and does not construct a native player', (tester) async {
    await mount(tester, host(asset: _remote()));
    expect(surfaces, 0);
    expect(controller.sources, isEmpty);
    expect(controller.commands, isEmpty);
    expect(find.byKey(const Key('still')), findsOneWidget);
    verifyZeroInteractions(assets);
  });

  testAndroidWidgets('missing local component fails once without a remote fallback', (tester) async {
    await mount(
      tester,
      host(
        asset: _local(remoteId: 'server-live'),
        path: '/nonexistent/foto-build19.mp4',
      ),
    );
    expect(controller.sources, isEmpty);
    expect(failed, 1);
    expect(controller.commands.where((c) => c == 'play'), isEmpty);
    verifyZeroInteractions(assets);
  });

  testAndroidWidgets('a network path cannot bypass timeline local-source enforcement', (tester) async {
    await mount(tester, host(asset: _local(), path: 'https://example.invalid/motion.mp4'));
    expect(controller.sources, isEmpty);
    expect(failed, 1);
    verifyZeroInteractions(assets);
  });

  testAndroidWidgets('native loading failure stays static and does not start playback', (tester) async {
    final file = await syntheticFile(tester);
    controller.failLoad = true;
    await mount(tester, host(asset: _local(), path: file.path));
    expect(failed, 1);
    expect(completed, 0);
    expect(controller.commands.where((c) => c == 'play'), isEmpty);
  });

  testAndroidWidgets('native playback rejection reports one bounded preview failure', (tester) async {
    final file = await syntheticFile(tester);
    controller.failPlay = true;
    controller.onLoad = controller.onPlaybackReady.notifyListeners;
    await mount(tester, host(asset: _local(), path: file.path));
    expect(failed, 1);
    controller.onPlaybackReady.notifyListeners();
    await tester.pump();
    expect(controller.commands.where((c) => c == 'play'), hasLength(1));
    expect(failed, 1);
  });

  testAndroidWidgets('a revoked lease prevents a late native-ready event from starting playback', (tester) async {
    final file = await syntheticFile(tester);
    var active = true;
    controller.loadAcknowledgement = Completer<void>();
    await mount(tester, host(asset: _local(), path: file.path, active: () => active));
    expect(controller.sources, hasLength(1));
    active = false;
    await tester.pumpWidget(host(asset: _local(), path: file.path, current: false, active: () => active));
    controller.onPlaybackReady.notifyListeners();
    await tester.pump();
    expect(controller.commands.where((c) => c == 'play'), isEmpty);
    expect(controller.commands, contains('pause'));
  });

  testAndroidWidgets('backgrounding pauses the player and a late ready event cannot restart it', (tester) async {
    final file = await syntheticFile(tester);
    controller.onLoad = controller.onPlaybackReady.notifyListeners;
    await mount(tester, host(asset: _local(), path: file.path));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(controller.commands, contains('pause'));
    expect(completed, 1);
    controller.onPlaybackReady.notifyListeners();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(controller.commands.where((c) => c == 'play'), hasLength(1));
  });

  testAndroidWidgets('disposal removes listeners so late native events cannot restart playback', (tester) async {
    final file = await syntheticFile(tester);
    controller.onLoad = controller.onPlaybackReady.notifyListeners;
    await mount(tester, host(asset: _local(), path: file.path));
    await tester.pumpWidget(const SizedBox());
    final count = controller.commands.where((c) => c == 'play').length;
    controller.onPlaybackReady.notifyListeners();
    controller.onPlaybackPositionChanged.value = 30;
    controller.onError.value = 'late native error';
    await tester.pump();
    expect(controller.commands.where((c) => c == 'play'), hasLength(count));
    expect(tester.takeException(), isNull);
  });

  testAndroidWidgets('full-screen remote motion retains its network source and manual play controls', (tester) async {
    final remote = _remote();
    await mount(tester, host(asset: remote, timeline: false));
    expect(controller.sources.single.type, VideoSourceType.network);
    expect(controller.sources.single.path, 'https://example.invalid/api/assets/server-motion/video/playback');
    final context = tester.element(find.byType(NativeVideoViewer));
    await ProviderScope.containerOf(context).read(videoPlayerProvider(remote.id).notifier).play();
    expect(controller.commands, contains('play'));
    verify(() => assets.getAsset(remote)).called(1);
  });
}
