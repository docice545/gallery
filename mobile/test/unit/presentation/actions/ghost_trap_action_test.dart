import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/deletion_result.model.dart';
import 'package:immich_mobile/presentation/actions/action.widget.dart';
import 'package:immich_mobile/presentation/actions/delete.action.dart';
import 'package:immich_mobile/presentation/widgets/deletion/ghost_trap.dart';
import 'package:immich_mobile/presentation/widgets/icons/proposal/foto_icon.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../../factories/remote_asset_factory.dart';
import '../presentation_context.dart';

// Pump fake-zone repository futures and let real raster capture finish. Waiting
// for the request entirely inside runAsync deadlocks fake-zone continuations.
Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var frame = 0; frame < 200 && !done(); frame++) {
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
  }
  expect(done(), isTrue, reason: 'The bounded frame/raster loop must reach the requested state');
}

void main() {
  for (final reject in [false, true]) {
    testWidgets('real DeleteAction waits for server ACK; rejected=$reject never produces a false completed flight', (
      tester,
    ) async {
      final fixture = await PresentationContext.create();
      addTearDown(fixture.dispose);
      final asset = RemoteAssetFactory.create(ownerId: fixture.currentUser.id);
      final request = Completer<void>();
      final response = Completer<void>();
      when(() => fixture.service.asset.service.getAsset(asset)).thenAnswer((_) async => asset);
      when(() => fixture.service.asset.service.trash([asset.id])).thenAnswer((_) async {
        request.complete();
        await response.future;
        if (reject) {
          throw StateError('synthetic definite rejection');
        }
      });
      await tester.pumpTestWidget(
        fixture,
        Column(
          children: [
            GhostSource(
              assetKey: asset.heroTag,
              requireImage: false,
              child: const SizedBox(width: 120, height: 160, child: ColoredBox(color: Colors.blue)),
            ),
            const Spacer(),
            const ActionColumnButton(
              fotoKind: FotoIconKind.trash,
              action: DeleteAction(source: .timeline),
            ),
          ],
        ),
        overrides: fixture.selected({asset}),
      );
      final container = ProviderScope.containerOf(tester.element(find.byType(ActionColumnButton)));
      final button = tester.widget<ImmichColumnButton>(find.byType(ImmichColumnButton));
      var completed = false;
      final deletion = Future<void>.sync(button.onPressed).whenComplete(() => completed = true);
      await _until(tester, () => request.isCompleted);
      await tester.pump();
      final painter =
          tester.widget<CustomPaint>(find.byKey(const ValueKey('ghost-trap-flight'))).painter! as GhostTrapPainter;
      expect(painter.confirmed, isFalse);
      expect(container.read(multiSelectProvider).selectedAssets, {asset});
      expect(find.byType(SnackBar), findsNothing);
      response.complete();
      await tester.pump();
      await tester.pump();
      if (!reject) {
        final confirmed =
            tester.widget<CustomPaint>(find.byKey(const ValueKey('ghost-trap-flight'))).painter! as GhostTrapPainter;
        expect(confirmed.confirmed, isTrue);
        await tester.pump(ghostTrapDuration);
      }
      await tester.pump();
      await _until(tester, () => completed);
      await deletion;
      await tester.pump();
      expect(find.byKey(const ValueKey('ghost-trap-flight')), findsNothing);
      expect(container.read(multiSelectProvider).selectedAssets, reject ? {asset} : isEmpty);
      verify(() => fixture.service.asset.service.trash([asset.id])).called(1);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('partial OS receipt cannot animate a representative that was denied', (tester) async {
    final fixture = await PresentationContext.create();
    addTearDown(fixture.dispose);
    final first = RemoteAssetFactory.create(ownerId: fixture.currentUser.id, localId: 'denied');
    final second = RemoteAssetFactory.create(ownerId: fixture.currentUser.id, localId: 'accepted');
    for (final asset in [first, second]) {
      when(() => fixture.service.asset.service.getAsset(asset)).thenAnswer((_) async => asset);
    }
    final request = Completer<void>();
    final response = Completer<LocalDeletionResult>();
    when(() => fixture.service.cleanup.service.deleteLocalAssetsDetailed(any(), trash: true)).thenAnswer((_) {
      request.complete();
      return response.future;
    });
    await tester.pumpTestWidget(
      fixture,
      Column(
        children: [
          GhostSource(
            assetKey: first.heroTag,
            requireImage: false,
            child: const SizedBox(width: 120, height: 160, child: ColoredBox(color: Colors.blue)),
          ),
          const Spacer(),
          const ActionColumnButton(
            fotoKind: FotoIconKind.deviceTrash,
            action: CleanupLocalAction(source: .timeline),
          ),
        ],
      ),
      overrides: fixture.selected(<BaseAsset>{first, second}),
    );
    final container = ProviderScope.containerOf(tester.element(find.byType(ActionColumnButton)));
    final button = tester.widget<ImmichColumnButton>(find.byType(ImmichColumnButton));
    var completed = false;
    final deletion = Future<void>.sync(button.onPressed).whenComplete(() => completed = true);
    await _until(tester, () => request.isCompleted);
    await tester.pump();
    expect(
      (tester.widget<CustomPaint>(find.byKey(const ValueKey('ghost-trap-flight'))).painter! as GhostTrapPainter)
          .confirmed,
      isFalse,
    );
    response.complete(const LocalDeletionResult(deletedIds: ['accepted'], remainingIds: ['denied']));
    await tester.pump();
    await _until(tester, () => completed);
    await deletion;
    await tester.pump();
    expect(find.byKey(const ValueKey('ghost-trap-flight')), findsNothing);
    expect(container.read(multiSelectProvider).selectedAssets, {first});
    verifyNever(() => fixture.service.asset.service.trash(any()));
    await tester.pumpWidget(const SizedBox());
  });
}
