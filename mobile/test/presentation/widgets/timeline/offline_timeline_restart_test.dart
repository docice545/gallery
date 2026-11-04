import 'dart:async';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/domain/services/user.service.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/user_api.repository.dart';
import 'package:immich_mobile/platform/local_image_api.g.dart';
import 'package:immich_mobile/platform/remote_image_api.g.dart';
import 'package:immich_mobile/presentation/widgets/images/face_aware_thumbnail_scope.widget.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_empty_state.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_route_scope.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/infrastructure/user.provider.dart';
import 'package:immich_mobile/providers/photos_filter/timeline_query.provider.dart';
import 'package:immich_mobile/providers/sync_status.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:mocktail/mocktail.dart';

import '../../../medium/repository_context.dart';
import '../../../test_utils.dart';
import '../../../widget_tester_extensions.dart';

class _UserApi extends Mock implements UserApiRepository {}

class _Readonly extends ReadOnlyModeNotifier {
  @override
  bool build() => false;
}

const _red = [216, 38, 54, 255];
const _green = [27, 176, 88, 255];
const _blue = [24, 86, 212, 255];

List<Object?> _pixels(List<int> color) {
  final pointer = malloc<Uint8>(16 * 16 * 4);
  final bytes = pointer.asTypedList(16 * 16 * 4);
  for (var offset = 0; offset < bytes.length; offset += 4) {
    bytes.setRange(offset, offset + 4, color);
  }
  return [
    <Object?, Object?>{'pointer': pointer.address, 'width': 16, 'height': 16, 'rowBytes': 64},
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(TestUtils.init);

  for (final source in ['mixed', 'local-only', 'empty']) {
    testWidgets('$source SQLite Timeline survives offline process restart without waiting for user refresh', (
      tester,
    ) async {
      Future<T?> real<T>(String stage, Future<T> Function() action) {
        return tester.runAsync(() async {
          debugPrint('C9 $source: $stage');
          return await action().timeout(
            const Duration(seconds: 15),
            onTimeout: () => throw TimeoutException('C9 $source: $stage did not complete'),
          );
        });
      }

      final directory = Directory.systemTemp.createTempSync('foto-offline-restart-');
      final file = File('${directory.path}/catalog.sqlite');
      final thumbnail = File('${directory.path}/cached-thumbnail.rgba');
      var ctx = MediumRepositoryContext(
        database: Drift(drift.DatabaseConnection(NativeDatabase(file), closeStreamsSynchronously: true)),
      );
      late StoreService store;
      final api = _UserApi();
      final refresh = Completer<UserDto?>();
      when(api.getMyUser).thenAnswer((_) => refresh.future);
      final pendingPreviews = <Completer<Object?>>[];
      var offline = source != 'mixed';
      final remoteCalls = <String>[];
      final localCalls = <String>[];
      final boundary = GlobalKey();
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const remoteChannel = BasicMessageChannel<Object?>(
        'dev.flutter.pigeon.immich_mobile.RemoteImageApi.requestImage',
        RemoteImageApi.pigeonChannelCodec,
      );
      const remoteCancel = BasicMessageChannel<Object?>(
        'dev.flutter.pigeon.immich_mobile.RemoteImageApi.cancelRequest',
        RemoteImageApi.pigeonChannelCodec,
      );
      const localChannel = BasicMessageChannel<Object?>(
        'dev.flutter.pigeon.immich_mobile.LocalImageApi.requestImage',
        LocalImageApi.pigeonChannelCodec,
      );
      const localCancel = BasicMessageChannel<Object?>(
        'dev.flutter.pigeon.immich_mobile.LocalImageApi.cancelRequest',
        LocalImageApi.pigeonChannelCodec,
      );
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockDecodedMessageHandler(remoteChannel, (message) async {
        final url = (message! as List).first! as String;
        remoteCalls.add(url);
        if (offline && Uri.parse(url).queryParameters['size'] == 'preview') {
          final pending = Completer<Object?>();
          pendingPreviews.add(pending);
          return pending.future;
        }
        // Message handlers run in the widget test's FakeAsync zone. This tiny
        // four-byte fixture must not await real filesystem work in that zone.
        return _pixels(thumbnail.readAsBytesSync());
      });
      messenger.setMockDecodedMessageHandler(remoteCancel, (_) async => [null]);
      messenger.setMockDecodedMessageHandler(localChannel, (message) async {
        final id = (message! as List).first! as String;
        localCalls.add(id);
        return _pixels(id == 'device-copy' ? _blue : _green);
      });
      messenger.setMockDecodedMessageHandler(localCancel, (_) async => [null]);

      Future<void> openStore() async {
        store = await StoreService.init(storeRepository: StoreRepository(ctx.db));
        await SettingsRepository.ensureInitialized(ctx.db);
      }

      Future<ProviderContainer> mount() async {
        final service = UserService(userApiRepository: api, userRepository: ctx.db.userRepository, storeService: store);
        await tester.pumpConsumerWidgetRaw(
          MediaQuery(
            // Samsung-scale decode demand requires a preview, while only the
            // warmed smaller thumbnail may survive the bounded native cache.
            data: const MediaQueryData(size: Size(390, 844), devicePixelRatio: 3),
            child: RepaintBoundary(
              key: boundary,
              child: const TimelineRouteScope(
                timelineServiceBuilder: buildPhotosTimelineRouteService,
                child: FaceAwareThumbnailScope(
                  child: Timeline(
                    appBar: null,
                    bottomSheet: null,
                    denseLayout: true,
                    emptyWidget: TimelineEmptyState(),
                  ),
                ),
              ),
            ),
          ),
          overrides: [
            driftProvider.overrideWithValue(ctx.db),
            userServiceProvider.overrideWithValue(service),
            readonlyModeProvider.overrideWith(_Readonly.new),
            stackCountsProvider.overrideWith((_) => Stream.value({})),
          ],
        );
        debugPrint('C9 $source: initial widget frame mounted');
        final container = ProviderScope.containerOf(tester.element(find.byType(Timeline)));
        unawaited(container.read(currentUserProvider.notifier).refresh());
        for (var i = 0; i < 8; i++) {
          await real('allow native/SQLite work', () => Future<void>.delayed(const Duration(milliseconds: 25)));
          await tester.pump(const Duration(milliseconds: 100));
        }
        return container;
      }

      Future<void> assertPhotos() async {
        final tiles = tester.widgetList<ThumbnailTile>(find.byType(ThumbnailTile)).toList();
        final expected = source == 'mixed'
            ? ['device-only', 'server-only', 'server-copy']
            : source == 'local-only'
            ? ['device-only']
            : <String>[];
        expect(tiles.map((tile) => tile.asset!.id).toSet(), expected.toSet());
        expect(tiles, hasLength(expected.length), reason: 'checksum-linked device/server copy stays one tile');
        if (source == 'empty') {
          expect(find.byType(FilledButton), findsOneWidget, reason: 'real empty state, not an unending grey grid');
          return;
        }
        final capture = (await real('capture decoded photo pixels', () async {
          final image = await (boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage();
          try {
            final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
            return (pixels: bytes, width: image.width);
          } finally {
            image.dispose();
          }
        }))!;
        final pixels = capture.pixels;
        final origin = tester.getTopLeft(find.byKey(boundary));
        for (final tile in tiles) {
          final finder = find.byWidgetPredicate((widget) => identical(widget, tile));
          final point = tester.getCenter(finder) - origin;
          final offset = (point.dy.floor() * capture.width + point.dx.floor()) * 4;
          final color = tile.asset!.id == 'server-only'
              ? _red
              : tile.asset!.id == 'server-copy'
              ? _blue
              : _green;
          expect(pixels.sublist(offset, offset + 4), color, reason: '${tile.asset!.id} must show decoded photo pixels');
        }
      }

      try {
        debugPrint('C9 $source: seed durable SQLite and thumbnail fixture');
        await real('open and seed database', () async {
          await openStore();
          await store.put(StoreKey.serverEndpoint, 'https://offline.example.test/api');
          await store.put(StoreKey.accessToken, 'synthetic-offline-token');
          await store.put(
            StoreKey.currentUser,
            UserDto(id: 'owner', email: 'owner@example.test', name: 'Owner', profileChangedAt: DateTime(2026)),
          );
          await ctx.newUser(id: 'owner');
          await ctx.newAuthUser(id: 'owner');
          if (source != 'empty') {
            await ctx.newLocalAlbum(id: 'camera', backupSelection: BackupSelection.selected);
            await ctx.newLocalAsset(
              id: 'device-only',
              checksum: 'local',
              createdAt: DateTime(2026),
              width: 500,
              height: 500,
            );
            await ctx.newLocalAlbumAsset(albumId: 'camera', assetId: 'device-only');
          }
          if (source == 'mixed') {
            await ctx.newLocalAsset(
              id: 'device-copy',
              checksum: 'shared',
              createdAt: DateTime(2026),
              width: 500,
              height: 500,
            );
            await ctx.newLocalAlbumAsset(albumId: 'camera', assetId: 'device-copy');
            await ctx.newRemoteAsset(
              id: 'server-copy',
              ownerId: 'owner',
              checksum: 'shared',
              createdAt: DateTime(2026),
              width: 500,
              height: 500,
            );
            await ctx.newRemoteAsset(
              id: 'server-only',
              ownerId: 'owner',
              checksum: 'remote',
              createdAt: DateTime(2026),
              width: 500,
              height: 500,
            );
            await thumbnail.writeAsBytes(_red, flush: true);
          }
        });
        debugPrint('C9 $source: first mount');
        var container = await mount();
        await assertPhotos();
        debugPrint('C9 $source: loaded pixels survive sync error');
        container.read(syncStatusProvider.notifier).errorRemoteSync('SocketException: Backend unavailable');
        await tester.pump();
        await assertPhotos();
        await tester.pumpWidget(const SizedBox());
        await real('close database and reopen durable state', () async {
          await SettingsRepository.reset();
          await store.dispose();
          await ctx.dispose();
          ctx = MediumRepositoryContext(
            database: Drift(drift.DatabaseConnection(NativeDatabase(file), closeStreamsSynchronously: true)),
          );
          await openStore();
        });
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
        offline = true;
        debugPrint('C9 $source: cold mount from reopened SQLite and native cache');
        container = await mount();
        await assertPhotos();
        expect(refresh.isCompleted, isFalse, reason: 'remote authorization/user refresh cannot gate SQLite photos');
        if (source == 'mixed') {
          expect(thumbnail.readAsBytesSync(), _red);
          expect(localCalls, containsAll(['device-only', 'device-copy']));
          expect(pendingPreviews, isNotEmpty, reason: 'cached pixels render while Backend preview is still pending');
        } else {
          expect(remoteCalls, isEmpty, reason: 'local-only and real-empty startup need no remote thumbnails');
        }
        offline = false;
        debugPrint('C9 $source: Backend returns');
        for (final pending in pendingPreviews) {
          pending.complete(_pixels(_red));
        }
        refresh.complete(null);
        container.read(syncStatusProvider.notifier).completeRemoteSync();
        for (var i = 0; i < 3; i++) {
          await real('allow native/SQLite work', () => Future<void>.delayed(const Duration(milliseconds: 25)));
          await tester.pump(const Duration(milliseconds: 100));
        }
        await assertPhotos();
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        for (final pending in pendingPreviews.where((pending) => !pending.isCompleted)) {
          pending.complete([null]);
        }
        if (!refresh.isCompleted) {
          refresh.complete(null);
        }
        messenger.setMockDecodedMessageHandler(remoteChannel, null);
        messenger.setMockDecodedMessageHandler(remoteCancel, null);
        messenger.setMockDecodedMessageHandler(localChannel, null);
        messenger.setMockDecodedMessageHandler(localCancel, null);
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
        await real('dispose database fixture', () async {
          await SettingsRepository.reset();
          await store.dispose();
          await ctx.dispose();
          await directory.delete(recursive: true);
        });
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  }
}
