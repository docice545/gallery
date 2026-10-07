import 'dart:async';
import 'dart:ffi' hide Size;

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_album.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/platform/remote_image_api.g.dart';
import 'package:immich_mobile/presentation/pages/library.page.dart';
import 'package:immich_mobile/providers/library/library_album_preview.provider.dart';
import 'package:immich_mobile/providers/sync_status.provider.dart';

const _emptyCover = (albumId: 'album', thumbnailId: null, thumbHash: null);

void _previewTestWidgets(String description, WidgetTesterCallback callback) {
  testWidgets(description, (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await callback(tester);
    } finally {
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

void main() {
  late Drift db;
  late StreamController<List<LibraryAlbumPreview>> previews;
  final requests = <String>[];
  var failBad = true;
  const request = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.RemoteImageApi.requestImage',
    RemoteImageApi.pigeonChannelCodec,
  );
  const cancel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.RemoteImageApi.cancelRequest',
    RemoteImageApi.pigeonChannelCodec,
  );

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    db = Drift(drift.DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await SettingsRepository.ensureInitialized(db);
    await StoreService.init(storeRepository: StoreRepository(db), listenUpdates: false);
    await Store.put(StoreKey.serverEndpoint, 'https://example.test/api');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockDecodedMessageHandler(request, (arguments) async {
      final url = (arguments! as List<Object?>).first! as String;
      requests.add(url);
      if (failBad && url.contains('/bad/')) {
        return <Object?>['thumbnail-failed', 'Fixture thumbnail failure', null];
      }
      final pointer = malloc<Uint8>(16);
      pointer.asTypedList(16).setAll(0, List.filled(16, 255));
      return <Object?>[
        <Object?, Object?>{'pointer': pointer.address, 'width': 2, 'height': 2, 'rowBytes': 8},
      ];
    });
    messenger.setMockDecodedMessageHandler(cancel, (_) async => <Object?>[null]);
  });

  setUp(() {
    previews = StreamController.broadcast();
    requests.clear();
    failBad = true;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });
  tearDown(() async {
    await previews.close();
  });
  tearDownAll(() async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockDecodedMessageHandler(request, null);
    messenger.setMockDecodedMessageHandler(cancel, null);
    await Store.clear();
    await SettingsRepository.reset();
    await db.close();
  });

  Future<void> mount(WidgetTester tester, {List<LibraryAlbumPreview>? cached}) async {
    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: locales.values.toList(),
        path: translationsPath,
        startLocale: locales.values.first,
        fallbackLocale: locales.values.first,
        saveLocale: false,
        useFallbackTranslations: true,
        assetLoader: const CodegenLoader(),
        child: ProviderScope(
          overrides: [
            libraryAlbumPreviewProvider.overrideWith((ref) => cached == null ? previews.stream : Stream.value(cached)),
          ],
          child: Builder(
            builder: (context) => MaterialApp(
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              home: const Scaffold(
                body: Center(child: SizedBox(width: 300, child: AlbumsCollectionCard())),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  _previewTestWidgets('slow initialization is loading, late album arrival automatically becomes mosaic', (
    tester,
  ) async {
    await mount(tester);
    expect(find.byKey(const Key('library-albums-loading')), findsOneWidget);
    expect(find.byKey(const Key('library-albums-empty')), findsNothing);
    await tester.pump(const Duration(seconds: 3));
    expect(find.byKey(const Key('library-albums-loading')), findsOneWidget);
    previews.add([_emptyCover]);
    await tester.pump();
    expect(find.byKey(const Key('library-albums-mosaic')), findsOneWidget);
    expect(find.byKey(const Key('library-albums-loading')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  _previewTestWidgets('cached albums do not depend on navigating to Albums first', (tester) async {
    await mount(tester, cached: [_emptyCover]);
    expect(find.byKey(const Key('library-albums-mosaic')), findsOneWidget);
    expect(find.byKey(const ValueKey('library-album-fallback-album')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  _previewTestWidgets('genuinely empty is explicit and later sync replaces it', (tester) async {
    await mount(tester);
    previews.add([]);
    await tester.pump();
    expect(find.byKey(const Key('library-albums-empty')), findsOneWidget);
    previews.add([_emptyCover]);
    await tester.pump();
    expect(find.byKey(const Key('library-albums-empty')), findsNothing);
    expect(find.byKey(const Key('library-albums-mosaic')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  _previewTestWidgets('empty snapshot during slow sync remains loading until sync completes', (tester) async {
    await mount(tester);
    final context = tester.element(find.byType(AlbumsCollectionCard));
    final container = ProviderScope.containerOf(context);
    container.read(syncStatusProvider.notifier).startRemoteSync();
    previews.add([]);
    await tester.pump();
    expect(find.byKey(const Key('library-albums-loading')), findsOneWidget);
    expect(find.byKey(const Key('library-albums-empty')), findsNothing);
    container.read(syncStatusProvider.notifier).completeRemoteSync();
    await tester.pump();
    expect(find.byKey(const Key('library-albums-empty')), findsOneWidget);
  });

  _previewTestWidgets('slow refresh preserves cached nonempty mosaic', (tester) async {
    await mount(tester, cached: [_emptyCover]);
    final context = tester.element(find.byType(AlbumsCollectionCard));
    ProviderScope.containerOf(context).read(syncStatusProvider.notifier).startRemoteSync();
    await tester.pump();
    expect(find.byKey(const Key('library-albums-mosaic')), findsOneWidget);
    expect(find.byKey(const Key('library-albums-loading')), findsNothing);
  });

  _previewTestWidgets('query error is retryable; retry resubscribes and does not cache blank state', (tester) async {
    await mount(tester);
    previews.addError(StateError('Fixture query error'));
    await tester.pump();
    expect(find.byKey(const Key('library-albums-error')), findsOneWidget);
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    expect(find.byKey(const Key('library-albums-loading')), findsOneWidget);
    previews.add([_emptyCover]);
    await tester.pump();
    expect(find.byKey(const Key('library-albums-mosaic')), findsOneWidget);
    expect(find.byKey(const Key('library-albums-error')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  _previewTestWidgets('one failed cover preserves other thumbnail and thumbnail-only cache path', (tester) async {
    await mount(
      tester,
      cached: [
        (albumId: 'bad-album', thumbnailId: 'bad', thumbHash: 'one'),
        (albumId: 'good-album', thumbnailId: 'good', thumbHash: 'two'),
      ],
    );
    await tester.runAsync(() => pumpEventQueue(times: 30));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('library-album-fallback-bad-album')), findsOneWidget);
    expect(find.byKey(const ValueKey('library-album-preview-good-album-good')), findsOneWidget);
    expect(find.byType(RawImage), findsOneWidget);
    expect(requests, hasLength(2));
    expect(requests.every((url) => Uri.parse(url).path.endsWith('/thumbnail')), isTrue);
    expect(requests.every((url) => Uri.parse(url).queryParameters['size'] == 'thumbnail'), isTrue);
    expect(tester.takeException(), isNull);
    failBad = false;
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    await tester.pump();
    await tester.runAsync(() => pumpEventQueue(times: 30));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('library-album-fallback-bad-album')), findsNothing);
    expect(find.byType(RawImage), findsNWidgets(2));
    expect(requests, hasLength(3), reason: 'retry only downloads failed image; good completed image stays cached');
    await tester.pumpWidget(const SizedBox());
    await mount(tester, cached: [(albumId: 'good-album', thumbnailId: 'good', thumbHash: 'two')]);
    await tester.runAsync(() => pumpEventQueue(times: 30));
    await tester.pumpAndSettle();
    expect(requests, hasLength(3), reason: 'existing completed Flutter thumbnail cache is reused');
    await tester.pumpWidget(const SizedBox());
  });
}
