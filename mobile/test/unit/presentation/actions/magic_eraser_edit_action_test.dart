import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/models/server_info/server_version.model.dart';
import 'package:immich_mobile/presentation/actions/action.widget.dart';
import 'package:immich_mobile/presentation/actions/edit_asset.action.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_ui/immich_ui.dart';

import '../../../riverpod_mocks.dart';
import '../../factories/local_asset_factory.dart';
import '../../factories/remote_asset_factory.dart';
import '../presentation_context.dart';

void main() {
  late PresentationContext context;

  setUp(() async => context = await PresentationContext.create());
  tearDown(() async => context.dispose());

  Future<void> pumpAction(WidgetTester tester, Set<BaseAsset> selection) => tester.pumpTestWidget(
    context,
    Consumer(
      builder: (_, _, _) => const ActionIconButton(action: EditAssetAction(source: .timeline)),
    ),
    overrides: [
      ...context.selected(selection),
      serverInfoProvider.overrideWith(
        (ref) => StubServerInfoNotifier(
          context.service.serverInfo,
          version: const ServerVersion(major: 5, minor: 7, patch: 1),
        ),
      ),
    ],
  );

  testWidgets('allows an owned Live/Motion still into the editor without relaxing its transform-edit eligibility', (
    tester,
  ) async {
    final live = RemoteAssetFactory.create(
      ownerId: context.currentUser.id,
      stackId: 'existing-stack',
    ).copyWith(livePhotoVideoId: 'linked-motion-video');

    await pumpAction(tester, {live});

    expect(find.byType(ImmichIconButton), findsOneWidget);
    expect(live.isEditable, isFalse);
    expect(live.livePhotoVideoId, 'linked-motion-video');
    expect(live.stackId, 'existing-stack');
  });

  testWidgets('does not expose editing of another owners Live Photo', (tester) async {
    final live = RemoteAssetFactory.create(ownerId: 'another-owner').copyWith(livePhotoVideoId: 'linked-motion-video');

    await pumpAction(tester, {live});

    expect(find.byType(ImmichIconButton), findsNothing);
  });

  testWidgets('does not offer a server editor without a selected photo', (tester) async {
    await pumpAction(tester, {});
    expect(find.byType(ImmichIconButton), findsNothing);
  });

  for (final remoteId in <String?>[null, 'backed-up-photo']) {
    testWidgets('does not treat a local asset as an owned server photo (remoteId: $remoteId)', (tester) async {
      await pumpAction(tester, {LocalAssetFactory.create(remoteId: remoteId)});
      expect(find.byType(ImmichIconButton), findsNothing);
    });
  }

  testWidgets('offers editing for an owned remote photo with a matching on-device original', (tester) async {
    final merged = RemoteAssetFactory.create(ownerId: context.currentUser.id, localId: 'local-original');
    expect(merged.isMerged, isTrue);

    await pumpAction(tester, {merged});
    expect(find.byType(ImmichIconButton), findsOneWidget);
  });

  for (final companion in ['local', 'shared', 'video', 'animated']) {
    testWidgets('does not silently choose one photo from a mixed selection containing $companion', (tester) async {
      final mine = RemoteAssetFactory.create(ownerId: context.currentUser.id);
      final BaseAsset other = switch (companion) {
        'local' => LocalAssetFactory.create(),
        'shared' => RemoteAssetFactory.create(ownerId: 'another-owner'),
        'video' => RemoteAssetFactory.create(ownerId: context.currentUser.id, type: .video),
        _ => RemoteAssetFactory.create(ownerId: context.currentUser.id).copyWith(durationMs: 1000),
      };

      await pumpAction(tester, {mine, other});
      expect(find.byType(ImmichIconButton), findsNothing);
    });
  }

  testWidgets('does not offer editing for a trashed photo', (tester) async {
    final trashed = RemoteAssetFactory.create(ownerId: context.currentUser.id, deletedAt: DateTime.utc(2026));
    await pumpAction(tester, {trashed});
    expect(find.byType(ImmichIconButton), findsNothing);
  });

  testWidgets('does not offer editing for a remote index tombstone', (tester) async {
    final removed = RemoteAssetFactory.create(ownerId: context.currentUser.id).copyWith(isIndexTombstone: true);
    await pumpAction(tester, {removed});
    expect(find.byType(ImmichIconButton), findsNothing);
  });

  testWidgets('keeps ordinary videos and animated images outside the photo eraser entry point', (tester) async {
    final video = RemoteAssetFactory.create(ownerId: context.currentUser.id, type: .video);
    await pumpAction(tester, {video});
    expect(find.byType(ImmichIconButton), findsNothing);

    final animated = RemoteAssetFactory.create(ownerId: context.currentUser.id).copyWith(durationMs: 1000);
    await pumpAction(tester, {animated});
    expect(find.byType(ImmichIconButton), findsNothing);
  });

  test('the editor loads a bounded unedited preview even when an original exists locally', () {
    for (final localId in [null, 'local-library-id']) {
      final photo = RemoteAssetFactory.create(ownerId: context.currentUser.id, localId: localId);
      final provider = getEditorImageProvider(photo);
      final uri = Uri.parse(provider.url);

      expect(uri.path, endsWith('/assets/${photo.id}/thumbnail'));
      expect(uri.queryParameters['size'], 'preview');
      expect(uri.queryParameters['edited'], 'false');
      expect(provider.edited, isFalse);
      expect(provider.url, isNot(contains('/original')));
    }
  });
}
