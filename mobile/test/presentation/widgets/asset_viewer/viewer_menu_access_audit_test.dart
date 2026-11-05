import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/album/album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/ocr.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/bottom_bar.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_top_app_bar.widget.dart';
import 'package:immich_mobile/presentation/widgets/icons/proposal/foto_icon.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset_viewer/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/current_album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/ocr.provider.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/routes.provider.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:mocktail/mocktail.dart';

import '../../../unit/factories/local_asset_factory.dart';
import '../../../unit/factories/remote_album_factory.dart';
import '../../../unit/factories/remote_asset_factory.dart';
import '../../../unit/presentation/presentation_context.dart';

enum _Scenario {
  local,
  localVideo,
  localAlbum,
  backedUpLocal,
  cloud,
  cloudVideo,
  motion,
  merged,
  foreign,
  remoteAlbum,
  localReadonly,
  cloudReadonly,
  localLocked,
  cloudLocked,
  trash,
  noOcr,
}

class _Viewer extends AssetViewerStateNotifier {
  _Viewer(this.asset);
  final BaseAsset asset;
  @override
  AssetViewerState build() => AssetViewerState(currentAsset: asset);
}

class _Readonly extends ReadOnlyModeNotifier {
  @override
  bool build() => true;
}

class _Album extends CurrentAlbumNotifier {
  _Album(this.album);
  final RemoteAlbum album;
  @override
  RemoteAlbum? build() => album;
}

Ocr _ocr(BaseAsset asset) => Ocr(
  id: 'ocr',
  assetId: asset.id,
  x1: 0,
  y1: 0,
  x2: 1,
  y2: 0,
  x3: 1,
  y3: 1,
  x4: 0,
  y4: 1,
  boxScore: 1,
  textScore: 1,
  text: 'FOTO',
  isVisible: true,
);

void main() {
  setUpAll(() async {
    await (FontLoader('GoogleSans')..addFont(rootBundle.load('fonts/GoogleSans/GoogleSans-Regular.ttf'))).load();
    await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final scenario in _Scenario.values) {
    for (final scale in [1.0, 1.5, 2.0]) {
      for (final brightness in Brightness.values) {
        testWidgets('viewer tools $scenario font=$scale $brightness', (tester) async {
          final fixture = await PresentationContext.create();
          addTearDown(fixture.dispose);
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.view.reset);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final readonly = [_Scenario.localReadonly, _Scenario.cloudReadonly].contains(scenario);
          final locked = [_Scenario.localLocked, _Scenario.cloudLocked].contains(scenario);
          final trash = scenario == _Scenario.trash;
          final local = [
            _Scenario.local,
            _Scenario.localVideo,
            _Scenario.localAlbum,
            _Scenario.backedUpLocal,
            _Scenario.localReadonly,
            _Scenario.localLocked,
          ].contains(scenario);
          final BaseAsset asset = local
              ? LocalAssetFactory.create(
                  remoteId: scenario == _Scenario.backedUpLocal ? 'backed-up' : null,
                ).copyWith(type: scenario == _Scenario.localVideo ? AssetType.video : AssetType.image)
              : RemoteAssetFactory.create(
                  ownerId: scenario == _Scenario.foreign ? 'another-owner' : fixture.currentUser.id,
                  type: scenario == _Scenario.cloudVideo ? AssetType.video : AssetType.image,
                  localId: scenario == _Scenario.merged ? 'device-copy' : null,
                  deletedAt: trash ? DateTime(2026, 11, 5) : null,
                ).copyWith(livePhotoVideoId: scenario == _Scenario.motion ? 'motion-component' : null);
          final timeline = TimelineService((
            assetSource: (_, _) async => [asset],
            bucketSource: () => Stream.value(const []),
            origin: trash
                ? TimelineOrigin.trash
                : scenario == _Scenario.localAlbum
                ? TimelineOrigin.localAlbum
                : TimelineOrigin.main,
          ));
          addTearDown(timeline.dispose);
          final expectedUpload = asset.storage == AssetState.local && !readonly && !locked && !trash;
          final expectedOcr = asset is RemoteAsset && asset.isImage && !trash && scenario != _Scenario.noOcr;
          await tester.pumpTestWidget(
            fixture,
            Theme(
              data: ThemeData(brightness: brightness, fontFamily: 'GoogleSans'),
              child: const Scaffold(appBar: ViewerTopAppBar(), bottomNavigationBar: ViewerBottomBar()),
            ),
            overrides: [
              assetViewerProvider.overrideWith(() => _Viewer(asset)),
              timelineServiceProvider.overrideWithValue(timeline),
              inLockedViewProvider.overrideWithValue(locked),
              if (readonly) readonlyModeProvider.overrideWith(_Readonly.new),
              if (scenario == _Scenario.remoteAlbum)
                currentRemoteAlbumProvider.overrideWith(
                  () => _Album(RemoteAlbumFactory.create(ownerId: fixture.currentUser.id)),
                ),
              assetExifProvider(asset).overrideWith((ref) async => null),
              if (asset is RemoteAsset)
                ocrAssetProvider(
                  asset.id,
                ).overrideWith((ref) async => scenario == _Scenario.noOcr ? [] : [_ocr(asset)]),
            ],
          );
          final more = find.byWidgetPredicate((w) => w is FotoIconButton && w.kind == FotoIconKind.more);
          final ocr = find.byWidgetPredicate((w) => w is FotoIcon && w.kind == FotoIconKind.ocr);
          final upload = find.text(StaticTranslations.instance.upload);
          if (!readonly && !trash) {
            expect(more, findsOneWidget);
            await tester.tap(more);
            await tester.pumpAndSettle();
          } else {
            expect(more, findsNothing);
          }
          expect(upload, expectedUpload ? findsOneWidget : findsNothing);
          expect(ocr, expectedOcr ? findsOneWidget : findsNothing);
          if (expectedOcr) {
            await tester.ensureVisible(ocr);
            await tester.pumpAndSettle();
            await tester.tap(ocr);
            await tester.pumpAndSettle();
            final container = ProviderScope.containerOf(tester.element(find.byType(ViewerBottomBar)));
            expect(container.read(assetViewerProvider).showingOcr, isTrue);
            if (!readonly) {
              await tester.tap(more);
              await tester.pumpAndSettle();
              await tester.ensureVisible(ocr);
              await tester.pumpAndSettle();
            }
            await tester.tap(ocr);
            await tester.pumpAndSettle();
            expect(container.read(assetViewerProvider).showingOcr, isFalse);
          }
          if (expectedUpload) {
            final uploading = Completer<void>();
            when(
              () => fixture.service.upload.uploadManual(
                any(),
                cancelToken: any(named: 'cancelToken'),
                callbacks: any(named: 'callbacks'),
              ),
            ).thenAnswer((invocation) async {
              await uploading.future;
              (invocation.namedArguments[#callbacks] as UploadCallbacks).onSuccess?.call(asset.id, 'uploaded');
            });
            await tester.ensureVisible(upload);
            await tester.pumpAndSettle();
            await tester.tap(upload);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            expect(find.byType(AlertDialog), findsOneWidget);
            expect(find.text(StaticTranslations.instance.uploading), findsOneWidget);
            final passed =
                verify(
                      () => fixture.service.upload.uploadManual(
                        captureAny(),
                        cancelToken: any(named: 'cancelToken'),
                        callbacks: any(named: 'callbacks'),
                      ),
                    ).captured.single
                    as List<LocalAsset>;
            expect(passed.map((a) => a.id), [asset.id]);
            uploading.complete();
            await tester.pumpAndSettle();
            await tester.pump(const Duration(seconds: 2));
            expect(find.byType(AlertDialog), findsNothing);
          } else {
            verifyNever(
              () => fixture.service.upload.uploadManual(
                any(),
                cancelToken: any(named: 'cancelToken'),
                callbacks: any(named: 'callbacks'),
              ),
            );
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        });
      }
    }
  }
}
