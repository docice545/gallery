import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/presentation/widgets/timeline/live_photo_autoplay.dart';
import 'package:immich_mobile/presentation/widgets/timeline/live_photo_scope.widget.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/photos_filter/filter_sheet.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';
import 'package:logging/logging.dart';

final _configProvider = StateProvider<AppConfig>((_) => const AppConfig());

class _TestSelection extends MultiSelectNotifier {
  void setForceEnable(bool enabled) => state = state.copyWith(forceEnable: enabled);
}

LocalAsset _asset(String id, {bool live = true, bool hashed = true, AssetType type = AssetType.image}) => LocalAsset(
  id: id,
  name: '$id.jpg',
  checksum: hashed ? id : null,
  type: type,
  createdAt: DateTime(2025),
  updatedAt: DateTime(2025),
  playbackStyle: live ? AssetPlaybackStyle.livePhoto : AssetPlaybackStyle.image,
  isEdited: false,
);

RemoteAsset _remoteAsset(String id, {String? localId}) => RemoteAsset(
  id: id,
  localId: localId,
  name: '$id.jpg',
  checksum: id,
  ownerId: 'owner',
  type: AssetType.image,
  createdAt: DateTime(2025),
  updatedAt: DateTime(2025),
  livePhotoVideoId: '$id-server-motion',
  isEdited: false,
);

class _PlaybackLog {
  final starts = <String>[];
  final stops = <String>[];
  final alive = <String>{};
  final completions = <String, VoidCallback>{};
  final playbackStarted = <String, VoidCallback>{};
  final failures = <String, VoidCallback>{};
  int maxConcurrent = 0;
}

class _FakePreview extends StatefulWidget {
  const _FakePreview({
    super.key,
    required this.asset,
    required this.log,
    required this.onCompleted,
    required this.onStarted,
    required this.onFailed,
    required this.startImmediately,
  });

  final BaseAsset asset;
  final _PlaybackLog log;
  final VoidCallback onCompleted;
  final VoidCallback onStarted;
  final VoidCallback onFailed;
  final bool startImmediately;

  @override
  State<_FakePreview> createState() => _FakePreviewState();
}

class _FakePreviewState extends State<_FakePreview> {
  @override
  void initState() {
    super.initState();
    widget.log.starts.add(widget.asset.id);
    widget.log.alive.add(widget.asset.id);
    widget.log.completions[widget.asset.id] = widget.onCompleted;
    widget.log.playbackStarted[widget.asset.id] = widget.onStarted;
    widget.log.failures[widget.asset.id] = widget.onFailed;
    if (widget.startImmediately) {
      widget.onStarted();
    }
    if (widget.log.alive.length > widget.log.maxConcurrent) {
      widget.log.maxConcurrent = widget.log.alive.length;
    }
  }

  @override
  void dispose() {
    widget.log.stops.add(widget.asset.id);
    widget.log.alive.remove(widget.asset.id);
    widget.log.completions.remove(widget.asset.id);
    widget.log.playbackStarted.remove(widget.asset.id);
    widget.log.failures.remove(widget.asset.id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.blue);
}

Future<ProviderContainer> _pumpScope(
  WidgetTester tester,
  _PlaybackLog log, {
  List<BaseAsset>? assets,
  ValueListenable<List<BaseAsset>>? assetList,
  Future<String?> Function(BaseAsset)? localVideoResolver,
  bool enabled = true,
  ScrollController? scrollController,
  ValueListenable<bool>? showFirst,
  ValueListenable<double>? height,
  VoidCallback? onTap,
  VoidCallback? onLongPress,
  GlobalKey<NavigatorState>? navigatorKey,
  bool startImmediately = true,
}) async {
  final tiles = assets ?? [_asset('first'), _asset('second'), _asset('third'), _asset('fourth')];

  Widget tile(BaseAsset asset, double tileHeight) => SizedBox(
    key: ValueKey('tile-${asset.id}'),
    height: tileHeight,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Hero(
            tag: asset.heroTag,
            child: ColoredBox(color: Colors.grey, child: Text('photo-${asset.id}')),
          ),
          TimelineLivePhotoTile(asset: asset),
          const Align(alignment: Alignment.bottomRight, child: Text('stack-count-3')),
        ],
      ),
    ),
  );

  Widget list(double tileHeight, bool firstVisible, List<BaseAsset> visibleAssets) => ListView(
    controller: scrollController,
    padding: EdgeInsets.zero,
    children: [
      for (var i = 0; i < visibleAssets.length; i++)
        if (i != 0 || firstVisible) tile(visibleAssets[i], tileHeight),
    ],
  );

  Widget listWithAssets(double tileHeight, bool firstVisible) => assetList == null
      ? list(tileHeight, firstVisible, tiles)
      : ValueListenableBuilder<List<BaseAsset>>(
          valueListenable: assetList,
          builder: (_, currentAssets, _) => list(tileHeight, firstVisible, currentAssets),
        );

  Widget listWithHeight(bool firstVisible) => height == null
      ? listWithAssets(120, firstVisible)
      : ValueListenableBuilder<double>(
          valueListenable: height,
          builder: (_, tileHeight, _) => listWithAssets(tileHeight, firstVisible),
        );

  final child = showFirst == null
      ? listWithHeight(true)
      : ValueListenableBuilder<bool>(
          valueListenable: showFirst,
          builder: (_, firstVisible, _) => listWithHeight(firstVisible),
        );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        _configProvider.overrideWith((_) => const AppConfig().copyWith.timeline(autoplayLivePhotos: enabled)),
        appConfigProvider.overrideWith((ref) => ref.watch(_configProvider)),
        multiSelectProvider.overrideWith(_TestSelection.new),
      ],
      child: MaterialApp(
        navigatorKey: navigatorKey,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 240,
              height: 240,
              child: TimelineLivePhotoScope(
                localVideoResolver: localVideoResolver ?? (asset) async => '/local/${asset.localId}.mp4',
                previewBuilder: (asset, onCompleted, onStarted, onFailed) => _FakePreview(
                  key: ValueKey('preview-${asset.id}'),
                  asset: asset,
                  log: log,
                  onCompleted: onCompleted,
                  onStarted: onStarted,
                  onFailed: onFailed,
                  startImmediately: startImmediately,
                ),
                child: child,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  await tester.pump();
  return ProviderScope.containerOf(tester.element(find.byType(TimelineLivePhotoScope)));
}

Future<void> _settlePlayback(WidgetTester tester) async {
  // Flush the local proof Future and its geometry frame before settling.
  await tester.pump();
  await tester.pump(livePhotoSettlingDelay);
  await tester.pump();
}

void main() {
  testWidgets('cold local motion resolves its local component and starts without opening a viewer', (tester) async {
    final log = _PlaybackLog();
    final resolved = <String?>[];
    final local = _asset('cold-local');
    await _pumpScope(
      tester,
      log,
      assets: [local],
      localVideoResolver: (asset) async {
        resolved.add(asset.localId);
        return '/local/cold-local-video.mp4';
      },
    );
    expect(log.starts, isEmpty);
    await _settlePlayback(tester);
    expect(resolved, ['cold-local']);
    expect(log.alive, {'cold-local'});
    expect(log.maxConcurrent, 1);
  });

  testWidgets('remote Live Photos stay static and never resolve or allocate autoplay video', (tester) async {
    final log = _PlaybackLog();
    var resolutions = 0;
    await _pumpScope(
      tester,
      log,
      assets: [_remoteAsset('server-first'), _remoteAsset('server-second')],
      localVideoResolver: (_) async {
        resolutions++;
        return '/local/incorrect-server-fallback.mp4';
      },
    );
    await tester.pump(const Duration(seconds: 5));
    expect(resolutions, 0);
    expect(log.starts, isEmpty);
    expect(find.byType(_FakePreview), findsNothing);
    expect(find.text('photo-server-first'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('merged Live Photo uses only the proven local component', (tester) async {
    final log = _PlaybackLog();
    final resolved = <String?>[];
    final merged = _remoteAsset('server-id', localId: 'device-id');
    await _pumpScope(
      tester,
      log,
      assets: [merged],
      localVideoResolver: (asset) async {
        resolved.add(asset.localId);
        return '/local/device-id.mp4';
      },
    );
    await _settlePlayback(tester);
    expect(resolved, ['device-id']);
    expect(log.alive, {'server-id'});
    expect(tester.widget<_FakePreview>(find.byType(_FakePreview)).asset, same(merged));
  });

  testWidgets('merged Live Photo without a local video stays static without a retry or server fallback', (
    tester,
  ) async {
    final log = _PlaybackLog();
    var resolutions = 0;
    await _pumpScope(
      tester,
      log,
      assets: [_remoteAsset('merged-no-video', localId: 'still-only')],
      localVideoResolver: (_) async {
        resolutions++;
        return null;
      },
    );
    await tester.pump(const Duration(seconds: 30));
    expect(resolutions, 1);
    expect(log.starts, isEmpty);
    expect(find.text('photo-merged-no-video'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a late local source cannot start after its merged asset becomes remote-only', (tester) async {
    final log = _PlaybackLog();
    final source = Completer<String?>();
    final assets = ValueNotifier<List<BaseAsset>>([_remoteAsset('changing', localId: 'old-device')]);
    addTearDown(assets.dispose);
    var resolutions = 0;
    await _pumpScope(
      tester,
      log,
      assetList: assets,
      localVideoResolver: (_) {
        resolutions++;
        return source.future;
      },
    );
    expect(resolutions, 1);
    assets.value = [_remoteAsset('changing')];
    await tester.pump();
    await tester.pump();
    source.complete('/local/old-device.mp4');
    await _settlePlayback(tester);
    expect(resolutions, 1);
    expect(log.starts, isEmpty);
    expect(log.maxConcurrent, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing only the merged local ID rejects the old asynchronous source', (tester) async {
    final log = _PlaybackLog();
    final staleSource = Completer<String?>();
    final assets = ValueNotifier<List<BaseAsset>>([_remoteAsset('same-remote', localId: 'old-device')]);
    addTearDown(assets.dispose);
    final resolved = <String?>[];
    await _pumpScope(
      tester,
      log,
      assetList: assets,
      localVideoResolver: (asset) {
        resolved.add(asset.localId);
        return asset.localId == 'old-device' ? staleSource.future : Future.value('/local/new-device.mp4');
      },
    );
    assets.value = [_remoteAsset('same-remote', localId: 'new-device')];
    await tester.pump();
    await tester.pump();
    staleSource.complete('/local/old-device.mp4');
    await tester.pump();
    await tester.pump();
    await _settlePlayback(tester);
    expect(resolved, ['old-device', 'new-device']);
    expect(log.alive, {'same-remote'});
    expect(tester.widget<_FakePreview>(find.byType(_FakePreview)).asset.localId, 'new-device');
    expect(log.maxConcurrent, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('checksum completion at the same mtime rejects a pending local source and resolves again', (
    tester,
  ) async {
    final log = _PlaybackLog();
    final staleSource = Completer<String?>();
    final unhashed = _asset('pending-hash', hashed: false);
    final hashed = unhashed.copyWith(checksum: 'completed-checksum');
    // HashService updates checksum without changing MediaStore's modification
    // time, and model equality intentionally ignores checksum.
    expect(hashed.updatedAt, unhashed.updatedAt);
    expect(hashed, unhashed);
    final assets = ValueNotifier<List<BaseAsset>>([unhashed]);
    addTearDown(assets.dispose);
    final resolvedChecksums = <String?>[];
    await _pumpScope(
      tester,
      log,
      assetList: assets,
      localVideoResolver: (asset) {
        resolvedChecksums.add(asset.checksum);
        return asset.checksum == null ? staleSource.future : Future.value('/local/verified-hash.mp4');
      },
    );
    expect(resolvedChecksums, [null]);
    assets.value = [hashed];
    await tester.pump();
    await tester.pump();
    expect(log.starts, isEmpty);
    expect(resolvedChecksums, [null], reason: 'source extraction remains serialized');
    staleSource.complete('/local/stale-unhashed.mp4');
    await tester.pump();
    await tester.pump();
    await _settlePlayback(tester);
    expect(resolvedChecksums, [null, 'completed-checksum']);
    expect(log.starts, ['pending-hash']);
    expect(log.alive, {'pending-hash'});
    expect(tester.widget<_FakePreview>(find.byType(_FakePreview)).asset.checksum, 'completed-checksum');
    expect(log.maxConcurrent, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('checksum completion at the same mtime revokes a ready source without retaining its lease', (
    tester,
  ) async {
    final log = _PlaybackLog();
    final verifiedSource = Completer<String?>();
    final unhashed = _asset('ready-hash', hashed: false);
    final hashed = unhashed.copyWith(checksum: 'completed-checksum');
    expect(hashed.updatedAt, unhashed.updatedAt);
    expect(hashed, unhashed);
    final assets = ValueNotifier<List<BaseAsset>>([unhashed]);
    addTearDown(assets.dispose);
    final resolvedChecksums = <String?>[];
    await _pumpScope(
      tester,
      log,
      assetList: assets,
      startImmediately: false,
      localVideoResolver: (asset) {
        resolvedChecksums.add(asset.checksum);
        return asset.checksum == null ? Future.value('/local/unhashed.mp4') : verifiedSource.future;
      },
    );
    await _settlePlayback(tester);
    expect(log.alive, {'ready-hash'});
    final staleStarted = log.playbackStarted['ready-hash']!;
    final staleCompleted = log.completions['ready-hash']!;
    assets.value = [hashed];
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(log.alive, isEmpty);
    expect(log.stops, ['ready-hash']);
    expect(resolvedChecksums, [null, 'completed-checksum']);
    verifiedSource.complete('/local/verified-hash.mp4');
    await tester.pump();
    await _settlePlayback(tester);
    expect(log.starts, ['ready-hash', 'ready-hash']);
    expect(log.alive, {'ready-hash'});
    expect(tester.widget<_FakePreview>(find.byType(_FakePreview)).asset.checksum, 'completed-checksum');
    staleStarted();
    staleCompleted();
    await tester.pump();
    expect(log.alive, {
      'ready-hash',
    }, reason: 'callbacks from the revoked checksum revision cannot affect its successor');
    log.playbackStarted['ready-hash']!();
    log.completions['ready-hash']!();
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(log.alive, isEmpty);
    expect(log.starts, ['ready-hash', 'ready-hash'], reason: 'the new revision still has a one-shot playback budget');
    expect(log.maxConcurrent, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cold feed mounts while backgrounded and starts only on the first resume', (tester) async {
    final log = _PlaybackLog();
    final stages = <String>[];
    final previousLevel = Logger.root.level;
    Logger.root.level = Level.INFO;
    addTearDown(() => Logger.root.level = previousLevel);
    final logs = Logger('TimelineLivePhoto').onRecord.listen((record) => stages.add(record.message));
    addTearDown(logs.cancel);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    try {
      await _pumpScope(tester, log);
      await _settlePlayback(tester);
      expect(log.starts, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await _settlePlayback(tester);
      expect(log.starts, ['first'], reason: stages.join(' | '));
    } finally {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('returning from viewer retries a cold preview cancelled before its first frame', (tester) async {
    final log = _PlaybackLog();
    final navigator = GlobalKey<NavigatorState>();
    await _pumpScope(tester, log, navigatorKey: navigator, startImmediately: false);
    await _settlePlayback(tester);
    expect(log.alive, {'first'});
    final staleStarted = log.playbackStarted['first']!;
    unawaited(navigator.currentState!.push<void>(MaterialPageRoute(builder: (_) => const Scaffold())));
    await tester.pumpAndSettle();
    expect(log.alive, isEmpty);
    staleStarted();
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    await _settlePlayback(tester);
    expect(log.starts, ['first', 'first']);
    expect(log.maxConcurrent, 1);
    log.playbackStarted['first']!();
    log.completions['first']!();
    await tester.pump();
    await _settlePlayback(tester);
    expect(log.starts, ['first', 'first'], reason: 'successful one-shot never cascades');
  });

  testWidgets('background during initialization releases and retries only the unplayed preview on resume', (
    tester,
  ) async {
    final log = _PlaybackLog();
    await _pumpScope(tester, log, startImmediately: false);
    await _settlePlayback(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(log.alive, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await _settlePlayback(tester);
    expect(log.starts, ['first', 'first']);
    expect(log.maxConcurrent, 1);
  });

  testWidgets('cold load failure retries the same asset once, then retains the still without a cascade', (
    tester,
  ) async {
    final log = _PlaybackLog();
    await _pumpScope(tester, log, startImmediately: false);
    await _settlePlayback(tester);
    log.failures['first']!();
    await tester.pump();
    expect(log.alive, isEmpty);
    await _settlePlayback(tester);
    expect(log.starts, ['first', 'first']);
    log.failures['first']!();
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(log.alive, isEmpty);
    expect(log.starts, ['first', 'first']);
    expect(log.maxConcurrent, 1);
  });

  testWidgets('a gesture interrupted by background does not leave the resumed cold feed suppressed', (tester) async {
    final log = _PlaybackLog();
    await _pumpScope(tester, log, startImmediately: false);
    await _settlePlayback(tester);
    final gesture = await tester.startGesture(tester.getCenter(find.text('photo-first')));
    await tester.pump();
    expect(log.alive, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await _settlePlayback(tester);
    expect(log.starts, ['first', 'first']);
    expect(log.maxConcurrent, 1);
    await gesture.cancel();
  });

  testWidgets('a fresh feed after restart does not require a viewer or a remembered native controller', (tester) async {
    final first = _PlaybackLog();
    await _pumpScope(tester, first);
    await _settlePlayback(tester);
    first.completions['first']!();
    await tester.pumpWidget(const SizedBox());
    final restarted = _PlaybackLog();
    await _pumpScope(tester, restarted);
    await _settlePlayback(tester);
    expect(restarted.starts, ['first']);
    expect(first.alive, isEmpty);
  });

  testWidgets('builds no previews ahead of time, then mounts only one visible live photo', (tester) async {
    final log = _PlaybackLog();
    await _pumpScope(tester, log);
    expect(log.starts, isEmpty);
    await tester.pump(const Duration(milliseconds: 349));
    expect(log.alive, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(log.starts, ['first']);
    expect(log.alive, {'first'});
    expect(find.byType(_FakePreview), findsOneWidget);
    expect(log.maxConcurrent, 1);
  });

  testWidgets('ordinary photos and videos remain thumbnails with no playback allocation', (tester) async {
    final log = _PlaybackLog();
    await _pumpScope(
      tester,
      log,
      assets: [
        _asset('photo', live: false),
        _asset('video', type: AssetType.video),
      ],
    );
    await tester.pump(const Duration(seconds: 2));
    expect(log.starts, isEmpty);
    expect(find.byType(Hero), findsNWidgets(2));
    expect(find.text('photo-photo'), findsOneWidget);
  });

  testWidgets('local Apple Live Photo uses existing playbackStyle and can autoplay', (tester) async {
    final log = _PlaybackLog();
    final local = LocalAsset(
      id: 'apple-local',
      name: 'IMG_001.HEIC',
      type: AssetType.image,
      createdAt: DateTime(2025),
      updatedAt: DateTime(2025),
      playbackStyle: AssetPlaybackStyle.livePhoto,
      isEdited: false,
    );
    await _pumpScope(tester, log, assets: [local]);
    await _settlePlayback(tester);
    expect(log.alive, {'apple-local'});
    expect(tester.widget<_FakePreview>(find.byType(_FakePreview)).asset, same(local));
  });

  testWidgets('disabled setting prevents playback, and turning it off releases the active preview', (tester) async {
    final log = _PlaybackLog();
    final container = await _pumpScope(tester, log, enabled: false);
    await tester.pump(const Duration(seconds: 1));
    expect(log.starts, isEmpty);
    container.read(_configProvider.notifier).state = const AppConfig();
    await tester.pump();
    await _settlePlayback(tester);
    expect(log.alive, {'first'});
    container.read(_configProvider.notifier).state = const AppConfig().copyWith.timeline(autoplayLivePhotos: false);
    // The derived config provider reevaluates during build; let the scheduled
    // unmount finish in the next frame, without advancing the settling timer.
    await tester.pump();
    await tester.pump();
    expect(log.alive, isEmpty);
    expect(log.stops, ['first']);
    await tester.pump(const Duration(seconds: 1));
    expect(log.starts, ['first']);
    container.read(_configProvider.notifier).state = const AppConfig();
    await tester.pump();
    await _settlePlayback(tester);
    expect(log.alive, isEmpty, reason: 'turning the setting back on does not replay the used viewport');
    expect(log.starts, ['first']);
  });

  testWidgets('scroll stops immediately, switches only after meaningful movement, and releases the old preview', (
    tester,
  ) async {
    final log = _PlaybackLog();
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await _pumpScope(tester, log, scrollController: scroll);
    await _settlePlayback(tester);
    expect(log.alive, {'first'});
    final gesture = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('tile-first'))));
    await tester.pump();
    expect(log.alive, isEmpty);
    expect(log.stops, ['first']);
    scroll.jumpTo(120);
    await tester.pump(const Duration(seconds: 1));
    expect(log.alive, isEmpty, reason: 'all scrolling and pointer interaction suppress autoplay');
    await gesture.up();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 349));
    expect(log.alive, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(log.alive, {'second'});
    expect(log.maxConcurrent, 1);
    expect(log.stops.first, 'first');
  });

  testWidgets('geometry changing below 80 percent restores the thumbnail without a scroll gesture', (tester) async {
    final log = _PlaybackLog();
    final height = ValueNotifier(300.0);
    addTearDown(height.dispose);
    await _pumpScope(tester, log, assets: [_asset('first'), _asset('second')], height: height);
    await _settlePlayback(tester);
    expect(log.alive, {'first'}, reason: '240 of 300 pixels is exactly 80 percent');
    height.value = 301;
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(log.alive, isEmpty);
    expect(log.stops, ['first']);
    expect(find.text('photo-first'), findsOneWidget);
  });

  testWidgets('completion restores the thumbnail and does not automatically play all nearby photos', (tester) async {
    final log = _PlaybackLog();
    await _pumpScope(tester, log);
    await _settlePlayback(tester);
    log.completions['first']!();
    await tester.pump();
    expect(log.alive, isEmpty);
    expect(log.stops, ['first']);
    await tester.pump(const Duration(seconds: 5));
    expect(log.starts, ['first']);
    expect(find.text('photo-first'), findsOneWidget);
  });

  testWidgets('one-shot completion does not loop or start another live photo without a new viewport', (tester) async {
    final log = _PlaybackLog();
    final height = ValueNotifier(80.0);
    addTearDown(height.dispose);
    await _pumpScope(tester, log, height: height);
    await _settlePlayback(tester);
    expect(log.alive, {'second'}, reason: 'the fully visible tile nearest the viewport centre wins');
    final complete = log.completions['second']!;
    complete();
    await tester.pump();
    expect(log.alive, isEmpty);
    complete();
    await tester.pump(const Duration(seconds: 30));
    expect(log.starts, ['second']);
    expect(log.stops, ['second']);
    expect(find.text('photo-second'), findsOneWidget);
    expect(find.byType(_FakePreview), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('small scrolls keep the viewport static until meaningful movement selects a new asset', (tester) async {
    final log = _PlaybackLog();
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await _pumpScope(tester, log, scrollController: scroll);
    await _settlePlayback(tester);
    log.completions['first']!();
    await tester.pump();
    for (final offset in [20.0, 40.0, 60.0, 80.0, 95.0]) {
      scroll.jumpTo(offset);
      await tester.pump();
      await _settlePlayback(tester);
      expect(log.alive, isEmpty);
      expect(log.starts, ['first']);
    }
    scroll.jumpTo(120);
    await tester.pump();
    await _settlePlayback(tester);
    expect(log.alive, {'second'});
    log.completions['second']!();
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(log.alive, isEmpty);
    expect(log.starts, ['first', 'second']);
    expect(log.maxConcurrent, 1);
  });

  testWidgets('scrolling away and back before settling cannot restart the original viewport', (tester) async {
    final log = _PlaybackLog();
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await _pumpScope(tester, log, scrollController: scroll);
    await _settlePlayback(tester);
    log.completions['first']!();
    await tester.pump();
    scroll.jumpTo(120);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(log.alive, isEmpty);
    scroll.jumpTo(0);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(log.alive, isEmpty);
    expect(log.starts, ['first']);
  });

  testWidgets('selection and forced selection stop playback without resuming the same viewport', (tester) async {
    final log = _PlaybackLog();
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    var taps = 0;
    var longPresses = 0;
    final container = await _pumpScope(
      tester,
      log,
      scrollController: scroll,
      onTap: () => taps++,
      onLongPress: () => longPresses++,
    );
    await _settlePlayback(tester);
    expect(find.descendant(of: find.byType(Hero), matching: find.byType(_FakePreview)), findsNothing);
    expect(find.text('stack-count-3'), findsWidgets);
    container.read(multiSelectProvider.notifier).selectAsset(_asset('first'));
    await tester.pump();
    expect(log.alive, isEmpty);
    container.read(multiSelectProvider.notifier).reset();
    await tester.pump();
    await _settlePlayback(tester);
    expect(log.alive, isEmpty);
    scroll.jumpTo(120);
    await tester.pump();
    await _settlePlayback(tester);
    expect(log.alive, {'second'});
    (container.read(multiSelectProvider.notifier) as _TestSelection).setForceEnable(true);
    await tester.pump();
    expect(log.alive, isEmpty);
    (container.read(multiSelectProvider.notifier) as _TestSelection).setForceEnable(false);
    await tester.pump();
    await _settlePlayback(tester);
    expect(log.alive, isEmpty);
    await tester.tap(find.byKey(const ValueKey('tile-second')));
    await tester.longPress(find.byKey(const ValueKey('tile-second')));
    await _settlePlayback(tester);
    expect(taps, 1);
    expect(longPresses, 1);
    expect(log.starts, ['first', 'second']);
    expect(log.maxConcurrent, 1);
    expect(find.text('stack-count-3'), findsWidgets);
  });

  testWidgets('a tap restores the thumbnail without replaying or changing the asset opening gesture', (tester) async {
    final log = _PlaybackLog();
    var taps = 0;
    await _pumpScope(tester, log, onTap: () => taps++);
    await _settlePlayback(tester);
    expect(log.alive, {'first'});
    await tester.tap(find.byKey(const ValueKey('tile-first')));
    await _settlePlayback(tester);
    expect(taps, 1);
    expect(log.alive, isEmpty);
    expect(log.starts, ['first']);
    expect(find.text('photo-first'), findsOneWidget);
  });

  testWidgets('a second finger keeps autoplay paused until all pointers leave', (tester) async {
    final log = _PlaybackLog();
    await _pumpScope(tester, log);
    await _settlePlayback(tester);
    final centre = tester.getCenter(find.byKey(const ValueKey('tile-first')));
    final first = await tester.startGesture(centre - const Offset(20, 0), pointer: 1);
    final second = await tester.startGesture(centre + const Offset(20, 0), pointer: 2);
    await tester.pump();
    expect(log.alive, isEmpty);
    await first.up();
    await tester.pump(const Duration(seconds: 1));
    expect(log.alive, isEmpty);
    await second.up();
    await tester.pump();
    await _settlePlayback(tester);
    expect(log.alive, isEmpty);
    expect(log.starts, ['first']);
    expect(log.maxConcurrent, 1);
  });

  testWidgets('backgrounding releases playback and returning rearms one visible preview after settling', (
    tester,
  ) async {
    final log = _PlaybackLog();
    await _pumpScope(tester, log);
    await _settlePlayback(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(log.alive, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    expect(log.starts, ['first']);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(log.alive, isEmpty);
    await _settlePlayback(tester);
    expect(log.alive, {'first'});
    expect(log.starts, ['first', 'first']);
    log.completions['first']!();
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(log.alive, isEmpty);
    expect(log.starts, ['first', 'first'], reason: 'one new activation does not loop or cascade');
    expect(log.maxConcurrent, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await _settlePlayback(tester);
    expect(log.starts, ['first', 'first'], reason: 'duplicate resume notifications are not new activations');
  });

  testWidgets('returning from a viewer rearms playback and ignores callbacks from the previous lease', (tester) async {
    final log = _PlaybackLog();
    final navigator = GlobalKey<NavigatorState>();
    await _pumpScope(tester, log, navigatorKey: navigator);
    await _settlePlayback(tester);
    final previousCompletion = log.completions['first']!;
    final previousFailure = log.failures['first']!;
    unawaited(navigator.currentState!.push<void>(MaterialPageRoute(builder: (_) => const Scaffold())));
    await tester.pumpAndSettle();
    expect(log.alive, isEmpty);
    expect(log.stops, ['first']);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    await _settlePlayback(tester);
    expect(log.alive, {'first'});
    expect(log.starts, ['first', 'first']);
    previousCompletion();
    previousFailure();
    await tester.pump();
    expect(log.alive, {'first'}, reason: 'old callbacks cannot revoke the new lease for the same asset');
    log.completions['first']!();
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(log.alive, isEmpty);
    expect(log.starts, ['first', 'first']);
    expect(log.maxConcurrent, 1);
  });

  testWidgets('opening the filter sheet stops playback and closing it cannot resume the same viewport', (tester) async {
    final log = _PlaybackLog();
    final container = await _pumpScope(tester, log);
    await _settlePlayback(tester);
    expect(log.alive, {'first'});
    container.read(photosFilterSheetProvider.notifier).state = FilterSheetVisibility.visible;
    await tester.pump();
    expect(log.alive, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    expect(log.starts, ['first']);
    container.read(photosFilterSheetProvider.notifier).state = FilterSheetVisibility.hidden;
    await tester.pump();
    expect(log.alive, isEmpty);
    await _settlePlayback(tester);
    expect(log.alive, isEmpty);
    expect(log.starts, ['first']);
    expect(log.maxConcurrent, 1);
  });

  testWidgets('a covering filter route does not consume a new viewer activation budget', (tester) async {
    final log = _PlaybackLog();
    final navigator = GlobalKey<NavigatorState>();
    final container = await _pumpScope(tester, log, navigatorKey: navigator);
    await _settlePlayback(tester);
    container.read(photosFilterSheetProvider.notifier).state = FilterSheetVisibility.visible;
    unawaited(navigator.currentState!.push<void>(MaterialPageRoute(builder: (_) => const Scaffold())));
    await tester.pumpAndSettle();
    expect(log.alive, isEmpty);
    container.read(photosFilterSheetProvider.notifier).state = FilterSheetVisibility.hidden;
    await tester.pump();
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    await _settlePlayback(tester);
    expect(log.starts, ['first'], reason: 'closing a filter remains an ordinary interaction');
    unawaited(navigator.currentState!.push<void>(MaterialPageRoute(builder: (_) => const Scaffold())));
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    await _settlePlayback(tester);
    expect(log.alive, {'first'}, reason: 'a subsequent genuine return to the feed rearms playback');
    expect(log.starts, ['first', 'first']);
    expect(log.maxConcurrent, 1);
  });

  testWidgets('removing an active tile disposes its preview without notifying disposed tile listeners', (tester) async {
    final log = _PlaybackLog();
    final showFirst = ValueNotifier(true);
    addTearDown(showFirst.dispose);
    await _pumpScope(tester, log, showFirst: showFirst);
    await _settlePlayback(tester);
    showFirst.value = false;
    await tester.pump();
    await tester.pump();
    expect(log.alive, isEmpty);
    expect(log.stops, ['first']);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('tile-second')), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(log.starts, ['first'], reason: 'a newly visible neighbour cannot use the played viewport');
    showFirst.value = true;
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(log.alive, isEmpty);
    expect(log.starts, ['first'], reason: 'remounting the original tile cannot replay it');
  });

  testWidgets('scope unmount cancels pending playback and disposes active previews without late callbacks', (
    tester,
  ) async {
    final pending = _PlaybackLog();
    await _pumpScope(tester, pending);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(pending.starts, isEmpty);
    expect(tester.takeException(), isNull);
    final active = _PlaybackLog();
    await _pumpScope(tester, active);
    await _settlePlayback(tester);
    expect(active.alive, {'first'});
    final lateCompletion = active.completions['first']!;
    await tester.pumpWidget(const SizedBox.shrink());
    lateCompletion();
    await tester.pump(const Duration(seconds: 1));
    expect(active.alive, isEmpty);
    expect(active.stops, ['first']);
    expect(tester.takeException(), isNull);
  });
}
