import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:auto_route/auto_route.dart';
import 'package:crop_image/crop_image.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/edited_copy.service.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/models/server_info/server_version.model.dart';
import 'package:immich_mobile/platform/remote_image_api.g.dart';
import 'package:immich_mobile/presentation/pages/edit/edit.page.dart';
import 'package:immich_mobile/presentation/pages/edit/editor.provider.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_viewer.page.dart';
import 'package:immich_mobile/presentation/widgets/icons/proposal/foto_icon.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset_viewer/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/ocr.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/repositories/file_media.repository.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/edited_image_exporter.dart';
import 'package:mocktail/mocktail.dart';
import 'package:photo_manager/photo_manager.dart' show AssetEntity;

import '../../../fixtures/editor_raster.dart';
import '../../../riverpod_mocks.dart';
import '../../../unit/factories/remote_asset_factory.dart';
import '../../../unit/presentation/presentation_context.dart';
import '../../../widget_tester_extensions.dart';

class _Media extends Mock implements FileMediaRepository {}

class _Importer extends Mock implements EditedCopyService {}

class _SingleTimeline extends TimelineService {
  _SingleTimeline(this.asset)
    : super((
        origin: TimelineOrigin.main,
        assetSource: (index, count) async => index == 0 && count > 0 ? [asset] : [],
        bucketSource: () => Stream.value([const Bucket(assetCount: 1)]),
      ));
  final RemoteAsset asset;
  @override
  int get totalAssets => 1;
  @override
  BaseAsset? getAssetSafe(int index) => index == 0 ? asset : null;
  @override
  Future<BaseAsset?> getAssetAsync(int index) async => getAssetSafe(index);
}

class _Viewer extends AssetViewerStateNotifier {
  _Viewer(this.asset);
  final RemoteAsset asset;
  @override
  AssetViewerState build() {
    super.build();
    return AssetViewerState(currentAsset: asset);
  }
}

void main() {
  for (final live in [false, true]) {
    testWidgets('actual Viewer pencil opens raster editor and saves a distinct copy; Live Photo=$live', (tester) async {
      final fixture = await PresentationContext.create();
      addTearDown(fixture.dispose);
      final media = _Media();
      final importer = _Importer();
      final asset = RemoteAssetFactory.create(
        ownerId: fixture.currentUser.id,
      ).copyWith(width: 64, height: 48, livePhotoVideoId: live ? 'unchanged-motion-companion' : null);
      final timeline = _SingleTimeline(asset);
      addTearDown(timeline.dispose);
      const exif = ExifInfo(width: 64, height: 48, orientation: '1');
      when(() => fixture.repository.remoteAsset.repo.getExif(asset.id)).thenAnswer((_) async => exif);
      when(() => fixture.service.asset.service.watchAsset(any())).thenAnswer((_) => const Stream.empty());
      final directory = (await tester.runAsync(() => Directory.systemTemp.createTemp('foto-viewer-copy-')))!;
      addTearDown(() => directory.delete(recursive: true));
      final source = (await tester.runAsync(createEditorRaster))!;
      addTearDown(source.dispose);
      final bytes = (await tester.runAsync(() => EditedImageExporter.encodePng(source)))!;
      final original = File('${directory.path}/original.png');
      final motion = File('${directory.path}/original-motion.bin');
      final motionBytes = [1, 3, 3, 7, 0, 9]; // Byte-identity fixture, no claim of video decoding.
      await tester.runAsync(() async {
        await original.writeAsBytes(bytes);
        await motion.writeAsBytes(motionBytes);
      });
      final requests = <Uri>[];
      const request = BasicMessageChannel<Object?>(
        'dev.flutter.pigeon.immich_mobile.RemoteImageApi.requestImage',
        RemoteImageApi.pigeonChannelCodec,
      );
      const cancel = BasicMessageChannel<Object?>(
        'dev.flutter.pigeon.immich_mobile.RemoteImageApi.cancelRequest',
        RemoteImageApi.pigeonChannelCodec,
      );
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockDecodedMessageHandler(request, (message) async {
        final uri = Uri.parse((message! as List<Object?>).first! as String);
        requests.add(uri);
        expect(uri.path, contains('/assets/${asset.id}/'));
        final pointer = malloc<Uint8>(bytes.length);
        pointer.asTypedList(bytes.length).setAll(0, bytes);
        return <Object?>[
          <String, int>{'pointer': pointer.address, 'length': bytes.length},
        ];
      });
      messenger.setMockDecodedMessageHandler(cancel, (_) async => <Object?>[null]);
      messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
      addTearDown(() {
        messenger.setMockDecodedMessageHandler(request, null);
        messenger.setMockDecodedMessageHandler(cancel, null);
        messenger.setMockMethodCallHandler(paths, null);
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
      });
      final copy = AssetEntity(id: 'new-still-copy', typeInt: 1, width: 48, height: 64);
      List<int>? savedPixels;
      when(() => importer.importSavedCopy(copy)).thenAnswer((_) async {});
      when(
        () => media.saveImageWithFile(
          any(),
          title: any(named: 'title'),
          relativePath: 'DCIM/Noodle Gallery',
          preserveCreatedAssetOnFailure: true,
        ),
      ).thenAnswer((call) async {
        final path = call.positionalArguments.single as String;
        expect(path, isNot(original.path));
        expect(path, isNot(motion.path));
        savedPixels = await File(path).readAsBytes();
        return copy;
      });
      final router = RootStackRouter.build(
        routes: [
          AutoRoute(initial: true, page: PageInfo('ActualViewer', builder: (_) => const AssetViewer(initialIndex: 0))),
          AutoRoute(page: EditImageRoute.page),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        router.dispose();
      });
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(
        () => tester.pumpWidget(
          localizedForTest(
            ProviderScope(
              overrides: fixture.overrides,
              child: ProviderScope(
                overrides: [
                  timelineServiceProvider.overrideWithValue(timeline),
                  assetViewerProvider.overrideWith(() => _Viewer(asset)),
                  assetExifProvider(asset).overrideWith((ref) async => exif),
                  ocrAssetProvider(asset.id).overrideWith((ref) async => const []),
                  fileMediaRepositoryProvider.overrideWithValue(media),
                  editedCopyServiceProvider.overrideWithValue(importer),
                  serverInfoProvider.overrideWith(
                    (ref) => StubServerInfoNotifier(
                      fixture.service.serverInfo,
                      version: const ServerVersion(major: 5, minor: 7, patch: 3),
                    ),
                  ),
                ],
                child: Builder(
                  builder: (context) => MaterialApp.router(
                    locale: context.locale,
                    localizationsDelegates: context.localizationDelegates,
                    supportedLocales: context.supportedLocales,
                    routerConfig: router.config(),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      Future<void> advanceUntil(bool Function() done) async {
        for (var step = 0; step < 150 && !done(); step++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(done(), isTrue);
      }

      final pencil = find.byWidgetPredicate((w) => w is FotoIconButton && w.kind == FotoIconKind.edit);
      await advanceUntil(() => pencil.hitTestable().evaluate().isNotEmpty);
      expect(find.byType(AssetViewer), findsOneWidget);
      await tester.tap(pencil);
      await advanceUntil(() => find.byType(CropImage).evaluate().isNotEmpty);
      expect(router.current.name, EditImageRoute.name);
      expect(find.byKey(const Key('editor-fixed-dock')), findsOneWidget);
      expect(find.byType(EditImagePage), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('editor-mode-crop')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('editor-rotate-left')));
      await tester.pump();
      final container = ProviderScope.containerOf(tester.element(find.byType(EditImagePage)));
      expect(container.read(editorStateProvider).rotationAngle, -90);
      await tester.tap(find.byKey(const Key('editor-save')));
      await advanceUntil(() => savedPixels != null && find.byType(EditImagePage).evaluate().isEmpty);
      expect(savedPixels, isNot(orderedEquals(bytes)));
      final dimensions = await tester.runAsync(() async {
        final codec = await ui.instantiateImageCodec(Uint8List.fromList(savedPixels!));
        final frame = await codec.getNextFrame();
        final result = Size(frame.image.width.toDouble(), frame.image.height.toDouble());
        frame.image.dispose();
        codec.dispose();
        return result;
      });
      expect(dimensions, const Size(48, 64));
      expect(await tester.runAsync(original.readAsBytes), orderedEquals(bytes));
      expect(await tester.runAsync(motion.readAsBytes), orderedEquals(motionBytes));
      expect(asset.livePhotoVideoId, live ? 'unchanged-motion-companion' : null);
      expect(asset.isEditable, !live);
      expect(requests.any((uri) => uri.path.endsWith('/original') && uri.queryParameters['edited'] == 'false'), isTrue);
      expect(requests.any((uri) => uri.path.contains('unchanged-motion-companion')), isFalse);
      verify(() => importer.importSavedCopy(copy)).called(1);
      verifyNever(() => fixture.service.asset.service.applyEdits(any(), any()));
      expect(find.byType(AssetViewer), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      expect(tester.takeException(), isNull);
    });
  }
}
