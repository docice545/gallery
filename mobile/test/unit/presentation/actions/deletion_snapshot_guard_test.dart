import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/presentation/actions/action.widget.dart';
import 'package:immich_mobile/presentation/actions/delete.action.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';
import 'package:immich_mobile/widgets/common/confirm_dialog.dart';
import 'package:mocktail/mocktail.dart';

import '../../factories/remote_asset_factory.dart';
import '../presentation_context.dart';

void main() {
  late PresentationContext fixture;
  late RemoteAsset selected;

  setUp(() async {
    fixture = await PresentationContext.create();
    selected = RemoteAssetFactory.create(ownerId: fixture.currentUser.id, localId: 'phone-selected');
  });
  tearDown(() => fixture.dispose());

  Future<ProviderContainer> mount(WidgetTester tester, {bool permanent = false}) async {
    if (permanent) {
      selected = selected.copyWith(deletedAt: DateTime(2026));
    }
    when(() => fixture.service.asset.service.getAsset(selected)).thenAnswer((_) async => selected);
    await tester.pumpTestWidget(
      fixture,
      const ActionButton(action: DeleteAction(source: .timeline)),
      overrides: fixture.selected({selected}),
    );
    return ProviderScope.containerOf(tester.element(find.byType(ActionButton)), listen: false);
  }

  Future<void> confirm(WidgetTester tester) async {
    expect(find.byType(ConfirmDialog), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(ConfirmDialog), matching: find.byType(TextButton)).last);
    await tester.pumpAndSettle();
  }

  void noDeletion() {
    verifyNever(() => fixture.service.asset.service.trash(any()));
    verifyNever(() => fixture.service.asset.service.acceptPermanentDeletion(any()));
    verifyNever(() => fixture.service.cleanup.service.deleteLocalAssetsDetailed(any()));
  }

  for (final change in ['one-many-one', 'metadata', 'missing']) {
    testWidgets('$change while confirmation is visible rejects the whole snapshot', (tester) async {
      final scope = await mount(tester, permanent: true);
      await tester.tap(find.byType(ActionButton));
      await tester.pump(const Duration(milliseconds: 300));
      switch (change) {
        case 'one-many-one':
          final other = RemoteAssetFactory.create(ownerId: fixture.currentUser.id);
          scope.read(multiSelectProvider.notifier).selectAsset(other);
          scope.read(multiSelectProvider.notifier).deselectAsset(other);
        case 'metadata':
          when(
            () => fixture.service.asset.service.getAsset(selected),
          ).thenAnswer((_) async => selected.copyWith(checksum: 'replacement-file'));
        case 'missing':
          when(() => fixture.service.asset.service.getAsset(selected)).thenAnswer((_) async => null);
      }
      await confirm(tester);
      noDeletion();
      expect(scope.read(multiSelectProvider).selectedAssets, {selected});
      expect(find.text('The selection changed. Nothing was deleted. Select the items again.'), findsOneWidget);
    });
  }

  testWidgets('background timeline reload during lookup preserves exact captured IDs', (tester) async {
    final scope = await mount(tester);
    final lookup = Completer<BaseAsset?>();
    when(() => fixture.service.asset.service.getAsset(selected)).thenAnswer((_) => lookup.future);
    await tester.tap(find.text('Move to trash'));
    await tester.pump();
    EventStream.shared.emit(const TimelineReloadEvent());
    await tester.pump();
    lookup.complete(selected.copyWith(updatedAt: selected.updatedAt.add(const Duration(seconds: 1))));
    await tester.pumpAndSettle();
    verify(() => fixture.service.asset.service.trash([selected.id])).called(1);
    expect(scope.read(multiSelectProvider).selectedAssets, isEmpty);
    expect(find.text('The selection changed. Nothing was deleted. Select the items again.'), findsNothing);
  });

  testWidgets('selection changing during fresh-row lookup never submits the stale server batch', (tester) async {
    final scope = await mount(tester);
    final lookup = Completer<BaseAsset?>();
    when(() => fixture.service.asset.service.getAsset(selected)).thenAnswer((_) => lookup.future);
    await tester.tap(find.text('Move to trash'));
    await tester.pump();
    scope.read(multiSelectProvider.notifier).selectAsset(RemoteAssetFactory.create(ownerId: fixture.currentUser.id));
    lookup.complete(selected);
    await tester.pumpAndSettle();
    noDeletion();
    expect(scope.read(multiSelectProvider).selectedAssets, hasLength(2));
  });

  testWidgets('late successful server ACK only deselects captured IDs', (tester) async {
    final scope = await mount(tester);
    final response = Completer<void>();
    when(() => fixture.service.asset.service.trash(any())).thenAnswer((_) => response.future);
    await tester.tap(find.text('Move to trash'));
    await tester.pump();
    final later = RemoteAssetFactory.create(ownerId: fixture.currentUser.id);
    scope.read(multiSelectProvider.notifier).selectAsset(later);
    response.complete();
    await tester.pumpAndSettle();
    verify(() => fixture.service.asset.service.trash([selected.id])).called(1);
    expect(scope.read(multiSelectProvider).selectedAssets, {later});
  });
}
