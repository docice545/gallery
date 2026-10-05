import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/models/server_info/server_version.model.dart';
import 'package:immich_mobile/presentation/actions/action.widget.dart';
import 'package:immich_mobile/presentation/actions/edit_asset.action.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_ui/immich_ui.dart';

import '../../../riverpod_mocks.dart';
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
