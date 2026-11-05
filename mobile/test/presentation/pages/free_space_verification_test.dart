import 'dart:io';
import 'dart:ui' as ui;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/cleanup_config.dart';
import 'package:immich_mobile/domain/models/deletion_result.model.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/providers/cleanup.provider.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/toast.provider.dart';
import 'package:immich_mobile/services/cleanup.service.dart';
import 'package:immich_mobile/services/toast.service.dart';
import 'package:immich_mobile/widgets/settings/free_up_space_settings.dart';
import 'package:intl/intl.dart';
import 'package:mocktail/mocktail.dart';

import '../../infrastructure/repository.mock.dart';
import '../../unit/factories/local_asset_factory.dart';
import '../../unit/factories/local_album_factory.dart';
import '../../unit/presentation/presentation_context.dart';

class _Cleanup extends Mock implements CleanupService {}

class _Toast extends Mock implements ToastService {}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    registerFallbackValue(DateTime(2026));
    registerFallbackValue(AssetKeepType.none);
    registerFallbackValue(() => true);
    await (FontLoader('Roboto')..addFont(rootBundle.load('fonts/GoogleSans/GoogleSans-Regular.ttf'))).load();
    await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      (_) async => const StandardMessageCodec().encodeMessage([null]),
    );
  });
  for (final brightness in Brightness.values) {
    for (final locale in ['en', 'ru']) {
      testWidgets('free space verification and retained files $brightness $locale', (tester) async {
        final fixture = await PresentationContext.create();
        // Match main.dart's locale bridge for ICU plural selection.
        final previousLocale = Intl.defaultLocale;
        Intl.defaultLocale = locale;
        addTearDown(() => Intl.defaultLocale = previousLocale);
        addTearDown(fixture.dispose);
        tester.view.physicalSize = const Size(393, 852);
        tester.view.devicePixelRatio = 1;
        tester.view.padding = const FakeViewPadding(bottom: 24);
        addTearDown(tester.view.reset);
        final protectedAlbums = List.generate(11, (i) => LocalAlbumFactory.create(id: 'kept-$i'));
        final settings = MockSettingsRepository();
        when(() => settings.appConfig).thenReturn(
          AppConfig(
            cleanup: CleanupConfig(
              cutoffDaysAgo: 30,
              defaultsInitialized: true,
              keepAlbumIds: protectedAlbums.map((a) => a.id).toList(),
            ),
          ),
        );
        final service = _Cleanup();
        final toast = _Toast();
        final List<LocalAsset> photos = [
          LocalAssetFactory.create(id: 'synthetic-1', remoteId: 'server-1').copyWith(checksum: 'synthetic-hash-1'),
          LocalAssetFactory.create(id: 'synthetic-2', remoteId: 'server-2').copyWith(checksum: 'synthetic-hash-2'),
        ];
        when(
          () => service.getRemovalCandidates(
            any(),
            any(),
            keepMediaType: any(named: 'keepMediaType'),
            keepFavorites: any(named: 'keepFavorites'),
            keepAlbumIds: any(named: 'keepAlbumIds'),
          ),
        ).thenAnswer(
          (_) async => RemovalCandidatesResult(
            assets: photos,
            totalBytes: 300,
            bytesByAssetId: {photos[0].id: 100, photos[1].id: 200},
          ),
        );
        when(
          () => service.deleteVerifiedBackups(
            any(),
            any(),
            any(),
            canContinue: any(named: 'canContinue'),
            keepMediaType: any(named: 'keepMediaType'),
            keepFavorites: any(named: 'keepFavorites'),
            keepAlbumIds: any(named: 'keepAlbumIds'),
          ),
        ).thenAnswer((_) async => LocalDeletionResult(deletedIds: [photos[0].id], remainingIds: [photos[1].id]));
        final notifier = CleanupNotifier(service, fixture.currentUser.id, settings);
        final boundary = GlobalKey();
        await tester.pumpTestWidget(
          fixture,
          Theme(
            data: ThemeData(brightness: brightness, colorSchemeSeed: Colors.teal, fontFamily: 'Roboto'),
            child: RepaintBoundary(
              key: boundary,
              child: const Scaffold(body: SafeArea(child: FreeUpSpaceSettings())),
            ),
          ),
          overrides: [
            cleanupProvider.overrideWith((_) => notifier),
            localAlbumProvider.overrideWith((_) => Stream.value(protectedAlbums)),
            toastServiceProvider.overrideWithValue(toast),
          ],
        );
        final context = tester.element(find.byType(FreeUpSpaceSettings));
        await EasyLocalization.of(context)!.setLocale(Locale(locale));
        await tester.pumpAndSettle();
        final t = context.t;
        expect(find.text(t.keeping(items: '${t.favorites}, ${t.keep_albums_count(count: 11)}')), findsOneWidget);
        if (locale == 'ru') {
          expect(t.keep_albums_count(count: 11), '11 альбомов');
          expect(t.select_cutoff_date, 'Фото и видео до даты');
        }
        Future<void> press(Finder finder) async {
          await tester.ensureVisible(finder);
          await tester.pumpAndSettle();
          await tester.tap(finder);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }

        Future<void> capture(String phase) async {
          final output = Platform.environment['FOTO_FREE_SPACE_EVIDENCE'];
          if (output == null) {
            return;
          }
          await tester.runAsync(() async {
            final render = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
            final image = await render.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
            await Directory(output).create(recursive: true);
            await File('$output/${brightness.name}-$locale-$phase.png').writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }

        await press(find.widgetWithText(ElevatedButton, t.continue$));
        await press(find.text(t.scan).first);
        await tester.ensureVisible(find.text(t.cleanup_verifies_originals).first);
        await tester.pumpAndSettle();
        expect(find.text(t.cleanup_verifies_originals).hitTestable(), findsOneWidget);
        await capture('verify');
        await press(find.widgetWithText(ElevatedButton, t.rescan));
        expect(notifier.state.assetsToDelete.length, 2);
        await tester.ensureVisible(find.widgetWithText(ElevatedButton, t.move_to_device_trash));
        await tester.pumpAndSettle();
        await capture('review');
        await press(find.widgetWithText(ElevatedButton, t.move_to_device_trash));
        expect(find.byType(AlertDialog), findsOneWidget);
        await press(find.widgetWithText(ElevatedButton, t.confirm));
        expect(find.byType(AlertDialog), findsNothing); // No false success dialog.
        expect(notifier.state.assetsToDelete.map((a) => a.id), [photos[1].id]);
        verify(() => toast.error(t.cleanup_unverified_remaining(count: 1))).called(1);
        await capture('remaining');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      });
    }
  }
}
