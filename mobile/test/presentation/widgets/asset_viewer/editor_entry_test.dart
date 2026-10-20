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
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset_viewer/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/ocr.provider.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/infrastructure/setting.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/utils/asset_filter.dart';
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

  Future<void> pumpViewer(WidgetTester tester, RemoteAsset asset) async {
    final timeline = _Timeline();
    when(() => timeline.origin).thenReturn(TimelineOrigin.main);
    await tester.pumpTestWidget(
      context,
      const Column(children: [ViewerTopAppBar(), Spacer(), ViewerBottomBar()]),
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

  for (final kind in ['photo', 'Live/Motion photo', 'video']) {
    testWidgets('$kind has no duplicate editor entry in the expanded top menu', (tester) async {
      var asset = RemoteAssetFactory.create(ownerId: context.currentUser.id, type: kind == 'video' ? .video : .image);
      if (kind == 'Live/Motion photo') {
        asset = asset.copyWith(livePhotoVideoId: 'motion-component');
      }
      await pumpViewer(tester, asset);

      final bottomPencil = find.descendant(of: find.byType(ViewerBottomBar), matching: find.byIcon(Icons.edit));
      expect(bottomPencil, kind == 'video' ? findsNothing : findsOneWidget);
      expect(find.descendant(of: find.byType(ViewerTopAppBar), matching: find.byIcon(Icons.edit)), findsNothing);

      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pumpAndSettle();
      // Opening the real menu builds the lazy menu children too.
      expect(find.byIcon(Icons.info_outline), findsOneWidget);
      expect(
        find.byWidgetPredicate((widget) => widget is ActionWidget && widget.action is EditAssetAction),
        findsNothing,
      );
      expect(find.byIcon(Icons.edit), kind == 'video' ? findsNothing : findsOneWidget);

      await tester.tap(find.byIcon(Icons.more_vert_rounded));
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
