import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/stack.model.dart';
import 'package:immich_mobile/presentation/actions/action.widget.dart';
import 'package:immich_mobile/presentation/actions/manage_stack.action.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../../../service.mocks.dart';
import '../../factories/remote_asset_factory.dart';
import '../presentation_context.dart';

void main() {
  late PresentationContext context;
  late MockAssetService assetService;

  setUp(() async {
    context = await PresentationContext.create();
    assetService = context.service.asset.service;
  });

  tearDown(() async {
    await context.dispose();
  });

  RemoteAsset owned({String? stackId}) => RemoteAssetFactory.create(ownerId: context.currentUser.id, stackId: stackId);

  Future<void> openManage(WidgetTester tester, Set<BaseAsset> selection) async {
    await tester.pumpTestAction(
      context,
      const ManageStackAction(source: .timeline),
      overrides: context.selected(selection),
    );
    // The action button keeps its progress animation while the sheet is open.
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> choose(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  group('ManageStackAction', () {
    testWidgets('adds the selected assets after the existing cover and clears selection', (tester) async {
      final first = owned();
      final second = owned();
      const stack = StackResponse(
        id: 'existing-stack',
        primaryAssetId: 'existing-cover',
        assetIds: ['existing-cover', 'existing-child'],
      );
      when(() => assetService.getStacks()).thenAnswer((_) async => [(stack: stack, name: 'Existing photo')]);

      await openManage(tester, {first, second});
      await choose(tester, 'Add to existing stack');
      await choose(tester, 'Existing photo (2)');

      verify(() => assetService.stack(context.currentUser.id, ['existing-cover', first.id, second.id])).called(1);
      expect(find.byType(ImmichIconButton), findsNothing, reason: 'successful stack changes clear the selection');
    });

    testWidgets('excludes assets owned by another user from adding to an existing stack', (tester) async {
      final mine = owned();
      final theirs = RemoteAssetFactory.create();
      const stack = StackResponse(id: 'existing-stack', primaryAssetId: 'existing-cover', assetIds: ['existing-cover']);
      when(() => assetService.getStacks()).thenAnswer((_) async => [(stack: stack, name: 'Existing photo')]);

      await openManage(tester, {mine, theirs});
      await choose(tester, 'Add to existing stack');
      await choose(tester, 'Existing photo (1)');

      verify(() => assetService.stack(context.currentUser.id, ['existing-cover', mine.id])).called(1);
    });

    testWidgets('does not expose the action for assets owned by another user', (tester) async {
      await tester.pumpTestWidget(
        context,
        const ActionIconButton(action: ManageStackAction(source: .timeline)),
        overrides: context.selected({RemoteAssetFactory.create(), RemoteAssetFactory.create()}),
      );

      expect(find.byType(ImmichIconButton), findsNothing);
      verifyNever(() => assetService.getStacks());
      verifyNever(() => assetService.stack(any(), any()));
    });

    testWidgets('does not offer a stack that already contains all selected assets', (tester) async {
      final asset = owned(stackId: 'existing-stack');
      final stack = StackResponse(
        id: 'existing-stack',
        primaryAssetId: asset.id,
        assetIds: [asset.id, 'existing-child'],
      );
      when(() => assetService.getStacks()).thenAnswer((_) async => [(stack: stack, name: 'Existing photo')]);

      await openManage(tester, {asset});
      await choose(tester, 'Add to existing stack');

      expect(find.text('Existing photo (2)'), findsNothing);
      verifyNever(() => assetService.stack(any(), any()));
    });

    testWidgets('changes the cover through the existing service and clears selection', (tester) async {
      final asset = owned(stackId: 'existing-stack');
      when(
        () => assetService.setStackPrimary(context.currentUser.id, 'existing-stack', asset.id),
      ).thenAnswer((_) async {});

      await openManage(tester, {asset});
      await choose(tester, 'Use as stack cover');

      verify(() => assetService.setStackPrimary(context.currentUser.id, 'existing-stack', asset.id)).called(1);
      expect(find.byType(ImmichIconButton), findsNothing);
    });

    testWidgets('removes an asset through the existing service and clears selection', (tester) async {
      final asset = owned(stackId: 'existing-stack');
      when(() => assetService.removeFromStack(context.currentUser.id, asset)).thenAnswer((_) async {});

      await openManage(tester, {asset});
      await choose(tester, 'Remove from stack');

      verify(() => assetService.removeFromStack(context.currentUser.id, asset)).called(1);
      expect(find.byType(ImmichIconButton), findsNothing);
    });
  });
}
