import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/setting.model.dart';
import 'package:immich_mobile/domain/services/setting.service.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/models/server_info/server_version.model.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/actions/action.widget.dart';
import 'package:immich_mobile/presentation/actions/edit_asset.action.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/bottom_bar.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_top_app_bar.widget.dart';
import 'package:immich_mobile/presentation/widgets/icons/proposal/foto_icon.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset_viewer/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/ocr.provider.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/infrastructure/setting.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/utils/asset_filter.dart';
import 'package:immich_mobile/utils/option.dart';
import 'package:mocktail/mocktail.dart';

import '../../../riverpod_mocks.dart';
import '../../../service.mocks.dart';
import '../../../unit/factories/remote_asset_factory.dart';
import '../../../unit/presentation/presentation_context.dart';

class _Viewer extends AssetViewerStateNotifier {
  _Viewer(this.asset);
  final BaseAsset asset;

  @override
  AssetViewerState build() => AssetViewerState(currentAsset: asset);
}

class _WritableMode extends ReadOnlyModeNotifier {
  @override
  bool build() => false;
}

class _DefaultSettings extends SettingsNotifier {
  @override
  SettingsService build() => SettingsService(storeService: MockStoreService());

  @override
  T get<T>(Setting<T> setting) => setting.defaultValue;
}

class _Timeline extends Mock implements TimelineService {}

void main() {
  late PresentationContext context;

  setUp(() async => context = await PresentationContext.create());
  tearDown(() async => context.dispose());

  Future<void> pumpViewer(
    WidgetTester tester,
    RemoteAsset asset, {
    double textScale = 1,
    EdgeInsets padding = EdgeInsets.zero,
  }) async {
    final timeline = _Timeline();
    when(() => timeline.origin).thenReturn(TimelineOrigin.main);
    await tester.pumpTestWidget(
      context,
      Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(padding: padding, textScaler: TextScaler.linear(textScale)),
          child: const Column(children: [ViewerTopAppBar(), Spacer(), ViewerBottomBar()]),
        ),
      ),
      overrides: [
        assetViewerProvider.overrideWith(() => _Viewer(asset)),
        assetsActionProvider(.viewer).overrideWithValue(AssetFilter<BaseAsset>({asset})),
        ownedAssetsActionProvider(.viewer).overrideWithValue(AssetFilter<RemoteAsset>({asset})),
        readonlyModeProvider.overrideWith(_WritableMode.new),
        settingsProvider.overrideWith(_DefaultSettings.new),
        timelineServiceProvider.overrideWithValue(timeline),
        assetExifProvider(asset).overrideWith((ref) async => null),
        ocrAssetProvider(asset.id).overrideWith((ref) async => const []),
        serverInfoProvider.overrideWith(
          (ref) => StubServerInfoNotifier(
            context.service.serverInfo,
            version: const ServerVersion(major: 2, minor: 6, patch: 0),
          ),
        ),
      ],
    );
  }

  for (final size in [const Size(320, 640), const Size(393, 852), const Size(852, 393)]) {
    testWidgets('real viewer panels keep equal 48 dp icon actions, SafeArea and large text at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final asset = RemoteAssetFactory.create(ownerId: context.currentUser.id);
      await pumpViewer(tester, asset, textScale: 2, padding: const EdgeInsets.fromLTRB(0, 24, 0, 24));
      final row = find.byKey(const ValueKey('viewer-action-row'));
      expect(tester.getSize(row).height, 56);
      expect(find.descendant(of: row, matching: find.byType(Text)), findsNothing);
      final actions = find.descendant(of: row, matching: find.byType(FotoIconButton));
      final boxes = [
        for (final widget in tester.widgetList<FotoIconButton>(actions)) tester.getRect(find.byWidget(widget)),
      ];
      expect(boxes.length, greaterThanOrEqualTo(3));
      for (final box in boxes) {
        expect(box.size, const Size.square(48));
        expect(box.bottom, lessThanOrEqualTo(size.height - 24));
      }
      final gaps = [for (var i = 1; i < boxes.length; i++) boxes[i].center.dx - boxes[i - 1].center.dx];
      for (final gap in gaps) {
        expect(gap, closeTo(gaps.first, .01));
      }
      final back = find.byWidgetPredicate((w) => w is FotoIconButton && w.kind == FotoIconKind.back);
      expect(tester.getRect(back).top, greaterThanOrEqualTo(24));
      final favorite = find.byWidgetPredicate((w) => w is FotoIconButton && w.kind == FotoIconKind.favorite);
      await tester.tap(favorite);
      await tester.pumpAndSettle();
      verify(() => context.service.asset.service.update([asset.id], isFavorite: const Option.some(true))).called(1);
      expect(tester.takeException(), isNull);
    });
  }

  for (final kind in ['photo', 'Live/Motion photo', 'video']) {
    testWidgets('$kind has no duplicate editor entry in the expanded top menu', (tester) async {
      var asset = RemoteAssetFactory.create(ownerId: context.currentUser.id, type: kind == 'video' ? .video : .image);
      if (kind == 'Live/Motion photo') {
        asset = asset.copyWith(livePhotoVideoId: 'motion-component');
      }
      await pumpViewer(tester, asset);

      final bottomPencil = find.descendant(
        of: find.byType(ViewerBottomBar),
        matching: find.byWidgetPredicate((w) => w is FotoIcon && w.kind == FotoIconKind.edit),
      );
      expect(bottomPencil, kind == 'video' ? findsNothing : findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ViewerTopAppBar),
          matching: find.byWidgetPredicate((w) => w is FotoIcon && w.kind == FotoIconKind.edit),
        ),
        findsNothing,
      );

      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      // Opening the real menu builds the lazy menu children too.
      expect(find.byWidgetPredicate((w) => w is FotoIcon && w.kind == FotoIconKind.info), findsOneWidget);
      expect(
        find.byWidgetPredicate((widget) => widget is ActionWidget && widget.action is EditAssetAction),
        findsNothing,
      );
      expect(
        find.byWidgetPredicate((w) => w is FotoIcon && w.kind == FotoIconKind.edit),
        kind == 'video' ? findsNothing : findsOneWidget,
      );

      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      if (kind != 'video') {
        await tester.tap(bottomPencil);
        await tester.pump();
        verify(() => context.repository.remoteAsset.repo.getAssetEdits(asset.id)).called(1);
        verify(() => context.repository.remoteAsset.repo.getExif(asset.id)).called(1);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
