import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/deletion_result.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/bottom_bar.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_control_surface.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/trash_action_bar.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/trash_bottom_sheet.widget.dart';
import 'package:immich_mobile/presentation/widgets/icons/proposal/foto_icon.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/widgets/common/confirm_dialog.dart';
import 'package:mocktail/mocktail.dart';

import '../../../unit/factories/remote_asset_factory.dart';
import '../../../unit/presentation/presentation_context.dart';

class _Viewer extends AssetViewerStateNotifier {
  _Viewer(this.asset);
  final RemoteAsset asset;
  @override
  AssetViewerState build() => AssetViewerState(currentAsset: asset);
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await (FontLoader('Roboto')..addFont(rootBundle.load('fonts/GoogleSans/GoogleSans-Regular.ttf'))).load();
  });

  for (final brightness in Brightness.values) {
    for (final locale in ['en', 'ru']) {
      for (final width in [320.0, 393.0]) {
        for (final scale in [1.0, 2.0]) {
          testWidgets('identical two-action trash capsule $brightness $locale width=$width scale=$scale', (
            tester,
          ) async {
            final fixture = await PresentationContext.create();
            addTearDown(fixture.dispose);
            tester.view.physicalSize = Size(width, 852);
            tester.view.devicePixelRatio = 1;
            tester.view.padding = const FakeViewPadding(bottom: 24);
            tester.platformDispatcher.textScaleFactorTestValue = scale;
            addTearDown(tester.view.reset);
            addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
            final asset = RemoteAssetFactory.create(ownerId: fixture.currentUser.id, deletedAt: DateTime(2026, 11, 5));
            final timeline = TimelineService((
              assetSource: (_, _) async => [asset],
              bucketSource: () => Stream.value(const []),
              origin: TimelineOrigin.trash,
            ));
            addTearDown(timeline.dispose);
            Rect? selectionRect;
            for (final viewer in [false, true]) {
              final boundary = GlobalKey();
              await tester.pumpTestWidget(
                fixture,
                RepaintBoundary(
                  key: boundary,
                  child: Theme(
                    data: ThemeData(brightness: brightness, colorSchemeSeed: Colors.teal, fontFamily: 'Roboto'),
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: viewer ? const ViewerBottomBar() : const TrashBottomBar(docked: true),
                    ),
                  ),
                ),
                overrides: [
                  ...fixture.selected({asset}),
                  timelineServiceProvider.overrideWithValue(timeline),
                  assetViewerProvider.overrideWith(() => _Viewer(asset)),
                ],
              );
              await EasyLocalization.of(tester.element(find.byType(TrashActionBar)))!.setLocale(Locale(locale));
              await tester.pumpAndSettle();
              final labels = locale == 'ru' ? ['Восстановить', 'Удалить навсегда'] : ['Restore', 'Delete permanently'];
              expect(find.byType(TrashActionBar), findsOneWidget);
              expect(find.byType(FotoIcon), findsNWidgets(2));
              expect(tester.widgetList<FotoIcon>(find.byType(FotoIcon)).map((w) => w.kind), [
                FotoIconKind.restore,
                FotoIconKind.trash,
              ]);
              final capsule = tester.getRect(find.byType(ViewerControlSurface));
              expect(capsule.bottom, closeTo(828, .01));
              expect(capsule.left, greaterThanOrEqualTo(12));
              if (viewer) {
                expect(capsule, selectionRect);
              } else {
                selectionRect = capsule;
              }
              for (final label in labels) {
                final text = find.text(label);
                expect(text, findsOneWidget);
                final widget = tester.widget<Text>(text);
                expect(widget.softWrap, isFalse);
                expect(widget.overflow, isNot(TextOverflow.ellipsis));
                final rect = tester.getRect(text);
                expect(capsule.contains(rect.topLeft) && capsule.contains(rect.bottomRight), isTrue);
              }
              for (final key in ['trash-restore', 'trash-delete-permanently']) {
                expect(tester.getSize(find.byKey(ValueKey(key))).shortestSide, greaterThanOrEqualTo(48));
              }
              const output = String.fromEnvironment('FOTO_TRASH_BAR_VISUAL_DIR');
              if (output.isNotEmpty && locale == 'ru' && width == 393) {
                await tester.runAsync(() async {
                  final image = await (boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage(
                    pixelRatio: 1,
                  );
                  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
                  await Directory(output).create(recursive: true);
                  await File(
                    '$output/${brightness.name}-${viewer ? 'viewer' : 'selection'}-$scale.png',
                  ).writeAsBytes(bytes!.buffer.asUint8List());
                  image.dispose();
                });
              }
              expect(tester.takeException(), isNull);
              await tester.pumpWidget(const SizedBox());
            }
          });
        }
      }
    }
  }

  for (final viewer in [false, true]) {
    testWidgets('trash viewer=$viewer preserves confirmation and cancellation before irreversible call', (
      tester,
    ) async {
      final fixture = await PresentationContext.create();
      addTearDown(fixture.dispose);
      final asset = RemoteAssetFactory.create(ownerId: fixture.currentUser.id, deletedAt: DateTime(2026, 11, 5));
      final service = fixture.service.asset.service;
      when(() => service.getAsset(asset)).thenAnswer((_) async => asset);
      when(
        () => service.acceptPermanentDeletion([asset.id]),
      ).thenAnswer((_) async => [PermanentDeletionResult(id: asset.id, state: 'pending', serverAccepted: true)]);
      final timeline = TimelineService((
        assetSource: (_, _) async => [asset],
        bucketSource: () => Stream.value(const []),
        origin: TimelineOrigin.trash,
      ));
      addTearDown(timeline.dispose);
      await tester.pumpTestWidget(
        fixture,
        Align(
          alignment: Alignment.bottomCenter,
          child: viewer ? const ViewerBottomBar() : const TrashBottomBar(docked: true),
        ),
        overrides: [
          ...fixture.selected({asset}),
          timelineServiceProvider.overrideWithValue(timeline),
          assetViewerProvider.overrideWith(() => _Viewer(asset)),
        ],
      );
      final delete = find.byKey(const ValueKey('trash-delete-permanently'));
      await tester.tap(delete);
      await tester.pumpAndSettle();
      expect(find.byType(ConfirmDialog), findsOneWidget);
      verifyNever(() => service.acceptPermanentDeletion(any()));
      await tester.tap(find.byType(TextButton).first);
      await tester.pumpAndSettle();
      verifyNever(() => service.acceptPermanentDeletion(any()));
      await tester.tap(delete);
      await tester.pumpAndSettle();
      expect(find.byType(ConfirmDialog), findsOneWidget);
      await tester.tap(find.byType(TextButton).last);
      await tester.pumpAndSettle();
      verify(() => service.acceptPermanentDeletion([asset.id])).called(1);
      verifyNever(() => service.trash(any()));
      expect(tester.takeException(), isNull);
    });
  }
  for (final viewer in [false, true]) {
    testWidgets('trash restore viewer=$viewer invokes only restore once while pending', (tester) async {
      final fixture = await PresentationContext.create();
      addTearDown(fixture.dispose);
      final asset = RemoteAssetFactory.create(ownerId: fixture.currentUser.id, deletedAt: DateTime(2026, 11, 5));
      final service = fixture.service.asset.service;
      final pending = Completer<void>();
      when(() => service.restoreTrash([asset.id])).thenAnswer((_) => pending.future);
      final timeline = TimelineService((
        assetSource: (_, _) async => [asset],
        bucketSource: () => Stream.value(const []),
        origin: TimelineOrigin.trash,
      ));
      addTearDown(timeline.dispose);
      await tester.pumpTestWidget(
        fixture,
        Align(
          alignment: Alignment.bottomCenter,
          child: viewer ? const ViewerBottomBar() : const TrashBottomBar(docked: true),
        ),
        overrides: [
          ...fixture.selected({asset}),
          timelineServiceProvider.overrideWithValue(timeline),
          assetViewerProvider.overrideWith(() => _Viewer(asset)),
        ],
      );
      final restore = find.byKey(const ValueKey('trash-restore'));
      await tester.tap(restore);
      await tester.tap(restore);
      await tester.pump();
      verify(() => service.restoreTrash([asset.id])).called(1);
      verifyNever(() => service.acceptPermanentDeletion(any()));
      pending.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
