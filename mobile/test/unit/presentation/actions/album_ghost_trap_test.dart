import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/album/album_trash_snapshot.model.dart';
import 'package:immich_mobile/domain/models/deletion_result.model.dart';
import 'package:immich_mobile/presentation/actions/delete.action.dart';
import 'package:immich_mobile/presentation/widgets/album/album_trash_reveal.dart';
import 'package:immich_mobile/presentation/widgets/album/animated_album_grid.dart';
import 'package:immich_mobile/presentation/widgets/album/animated_album_rows.dart';
import 'package:immich_mobile/presentation/widgets/deletion/ghost_trap.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/remote_album.provider.dart';
import 'package:immich_mobile/repositories/album_api_repository.dart';
import 'package:immich_mobile/widgets/common/confirm_dialog.dart';
import 'package:mocktail/mocktail.dart';

import '../../../infrastructure/repository.mock.dart';
import '../../factories/local_asset_factory.dart';
import '../../factories/remote_asset_factory.dart';
import '../presentation_context.dart';

class _Api extends Mock implements AlbumApiRepository {}

class _Albums extends RemoteAlbumNotifier {
  _Albums(this.onDelete);
  final Future<void> Function() onDelete;
  @override
  RemoteAlbumState build() => const RemoteAlbumState(albums: []);
  @override
  Future<void> deleteAlbum(String id) => onDelete();
}

Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var frame = 0; frame < 200 && !done(); frame++) {
    await tester.pump(const Duration(milliseconds: 5));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
  }
  expect(done(), isTrue);
}

void main() {
  for (final scope in ['remote', 'local']) {
    for (final reduced in [false, true]) {
      for (final grid in [false, if (scope == 'remote') true]) {
        testWidgets('$scope album ACK flight/reflow reduced=$reduced grid=$grid', (tester) async {
          final fixture = await PresentationContext.create();
          addTearDown(fixture.dispose);
          tester.view.physicalSize = const Size(393, 852);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final rows = ValueNotifier(['album', 'other']);
          addTearDown(rows.dispose);
          final entered = Completer<void>();
          final accepted = Completer<void>();
          final metadataEntered = Completer<void>();
          final metadataAccepted = Completer<void>();
          var trashed = false;
          final remote = RemoteAssetFactory.create(ownerId: fixture.currentUser.id);
          final local = LocalAssetFactory.create(remoteId: remote.id);
          final assetId = scope == 'remote' ? remote.id : local.id;
          final api = _Api();
          when(() => api.getTrashSnapshot('album', fixture.currentUser.id)).thenAnswer(
            (_) async => AlbumTrashSnapshot(
              id: 'album',
              name: 'Camera',
              ownerId: fixture.currentUser.id,
              updatedAt: DateTime(2026),
              assets: trashed ? [] : [remote],
            ),
          );
          when(() => fixture.service.asset.service.trash([remote.id])).thenAnswer((_) async {
            entered.complete();
            await accepted.future;
            trashed = true;
          });
          final albums = _Albums(() async {
            metadataEntered.complete();
            await metadataAccepted.future;
            rows.value = ['other'];
          });
          final repository = MockLocalAlbumRepository();
          final db = MockDrift();
          when(() => db.localAlbumRepository).thenReturn(repository);
          when(() => repository.getAssets('album')).thenAnswer((_) async => [local]);
          when(() => fixture.service.cleanup.service.deleteLocalAssetsDetailed([local.id], trash: true)).thenAnswer((
            _,
          ) async {
            entered.complete();
            await accepted.future;
            rows.value = ['other'];
            return LocalDeletionResult(deletedIds: [local.id], remainingIds: []);
          });
          late ProviderContainer container;
          await tester.pumpTestWidget(
            fixture,
            Consumer(
              builder: (context, ref, _) {
                container = ProviderScope.containerOf(context);
                final held = ref.watch(albumDeletionHoldsProvider);
                return MediaQuery(
                  data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
                  child: ValueListenableBuilder(
                    valueListenable: rows,
                    builder: (_, items, _) => CustomScrollView(
                      slivers: [
                        _albumItems(
                          grid: grid,
                          items: items,
                          keyOf: (id) => ghostAlbumKey(scope, id),
                          heldKeys: held,
                          builder: (rowContext, id) => AlbumTrashReveal(
                            key: ValueKey('row-$id'),
                            ghostKey: ghostAlbumKey(scope, id),
                            onTrash: () async => scope == 'remote'
                                ? TrashRemoteAlbumAction(albumId: id).create(rowContext, ref).onAction()
                                : CleanupLocalAlbumAction(
                                    albumId: id,
                                    albumName: 'Camera',
                                  ).create(rowContext, ref).onAction(),
                            child: SizedBox(
                              height: 88,
                              child: Row(
                                children: [
                                  GhostSource(
                                    assetKey: ghostAlbumCoverKey(scope, id, assetId),
                                    requireImage: false,
                                    child: SizedBox(
                                      key: ValueKey('cover-$id'),
                                      width: 80,
                                      height: 80,
                                      child: const ColoredBox(color: Colors.blue),
                                    ),
                                  ),
                                  const Expanded(child: Text('Camera')),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            overrides: [
              albumApiRepositoryProvider.overrideWithValue(api),
              remoteAlbumProvider.overrideWith(() => albums),
              driftProvider.overrideWithValue(db),
            ],
          );
          final cover = find.byKey(const ValueKey('cover-album'));
          final original = tester.getRect(cover);
          final originalRowOrigin = tester.getTopLeft(find.byKey(const ValueKey('row-album')));
          final other = tester.getRect(find.byKey(const ValueKey('row-other')));
          await tester.drag(find.byKey(const ValueKey('row-album')), const Offset(-150, 0));
          await tester.pumpAndSettle();
          expect(tester.getRect(cover), original, reason: 'The actual cover stays visible after revealing the bin');
          expect(find.byType(ConfirmDialog), findsNothing);
          final bin = find.descendant(
            of: find.byKey(const ValueKey('row-album')),
            matching: find.byTooltip('Delete album'),
          );
          await tester.tap(bin);
          await tester.pumpAndSettle();
          final confirm = find.descendant(of: find.byType(ConfirmDialog), matching: find.byType(TextButton)).last;
          await tester.tap(confirm);
          await _until(tester, () => entered.isCompleted);
          await tester.pump();
          final flightFinder = find.byKey(const ValueKey('ghost-trap-flight'));
          GhostTrapPainter paint() => tester.widget<CustomPaint>(flightFinder).painter! as GhostTrapPainter;
          expect(paint().confirmed, isFalse);
          expect(paint().target, tester.getCenter(bin));
          expect(container.read(albumDeletionHoldsProvider), {ghostAlbumKey(scope, 'album')});
          accepted.complete();
          if (scope == 'remote') {
            await _until(tester, () => metadataEntered.isCompleted);
            expect(paint().confirmed, isFalse, reason: 'Asset trash alone is not an album deletion receipt');
            metadataAccepted.complete();
          }
          await _until(tester, () => flightFinder.evaluate().isNotEmpty && paint().confirmed);
          expect(rows.value, ['other']);
          expect(
            find.byKey(const ValueKey('row-album')),
            findsOneWidget,
            reason: 'The real target must remain visible while the cover flies',
          );
          expect(tester.getRect(find.byKey(const ValueKey('row-other'))), other);
          await tester.pump(reduced ? const Duration(milliseconds: 121) : const Duration(milliseconds: 521));
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
          await tester.pump();
          expect(flightFinder, findsNothing);
          await tester.pump(reduced ? ghostTrapAlbumReducedReflowDuration : ghostTrapAlbumReflowDuration);
          await tester.pump();
          expect(find.byKey(const ValueKey('row-album')), findsNothing);
          expect(tester.getTopLeft(find.byKey(const ValueKey('row-other'))), originalRowOrigin);
          expect(container.read(albumDeletionHoldsProvider), isEmpty);
          if (scope == 'local') {
            verifyNever(() => fixture.service.asset.service.trash(any()));
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        }, timeout: const Timeout(Duration(seconds: 45)));
      }
    }
  }
}

Widget _albumItems({
  required bool grid,
  required List<String> items,
  required String Function(String) keyOf,
  required Set<String> heldKeys,
  required Widget Function(BuildContext, String) builder,
}) => grid
    ? AnimatedAlbumGrid<String>(items: items, keyOf: keyOf, heldKeys: heldKeys, builder: builder)
    : AnimatedAlbumRows<String>(items: items, keyOf: keyOf, heldKeys: heldKeys, builder: builder);
