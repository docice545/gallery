import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/album/album.model.dart';
import 'package:immich_mobile/domain/models/album/album_trash_snapshot.model.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/models/albums/album_search.model.dart';
import 'package:immich_mobile/presentation/pages/local_album.page.dart';
import 'package:immich_mobile/presentation/widgets/album/album_selector.widget.dart';
import 'package:immich_mobile/presentation/widgets/album/album_trash_reveal.dart';
import 'package:immich_mobile/providers/album/album_sort_by_options.provider.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/remote_album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/repositories/album_api_repository.dart';
import 'package:immich_mobile/widgets/common/confirm_dialog.dart';
import 'package:mocktail/mocktail.dart';

import '../../../infrastructure/repository.mock.dart';
import '../../factories/local_asset_factory.dart';
import '../../factories/remote_album_factory.dart';
import '../../factories/remote_asset_factory.dart';
import '../presentation_context.dart';

class _AlbumApi extends Mock implements AlbumApiRepository {}

class _Albums extends RemoteAlbumNotifier {
  _Albums(this.album);
  final RemoteAlbum album;
  int metadataDeletes = 0;
  @override
  RemoteAlbumState build() => const RemoteAlbumState(albums: []);
  @override
  Future<void> refresh() async => state = RemoteAlbumState(albums: [album]);
  @override
  Future<List<RemoteAlbum>> sortAlbums(List<RemoteAlbum> albums, AlbumSortMode mode, {bool isReverse = false}) async =>
      albums;
  @override
  List<RemoteAlbum> searchAlbums(
    List<RemoteAlbum> albums,
    String query,
    String? userId, [
    QuickFilterMode filterMode = QuickFilterMode.all,
  ]) => albums;
  @override
  Future<void> deleteAlbum(String id) async {
    metadataDeletes++;
    state = const RemoteAlbumState(albums: []);
  }
}

void main() {
  late PresentationContext fixture;
  setUp(() async {
    fixture = await PresentationContext.create();
    when(() => fixture.service.asset.service.getRemoteAsset(any())).thenAnswer((_) async => null);
  });
  tearDown(() => fixture.dispose());

  Future<void> reveal(WidgetTester tester) async {
    await tester.drag(find.byType(AlbumTrashReveal), const Offset(-200, 0));
    await tester.pumpAndSettle();
    expect(find.byType(ConfirmDialog), findsNothing);
    expect(find.text('Camera'), findsOneWidget);
  }

  Future<void> respond(WidgetTester tester, bool confirm) async {
    expect(find.byType(ConfirmDialog), findsOneWidget);
    expect(find.text('Are you sure you want to delete the album Camera?'), findsOneWidget);
    await tester.tap(
      find.descendant(of: find.byType(ConfirmDialog), matching: find.byType(TextButton)).at(confirm ? 1 : 0),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('actual On this device list: swipe, reverse, cancel, confirm; no server mutation', (tester) async {
    final repository = MockLocalAlbumRepository();
    final drift = MockDrift();
    final assets = [LocalAssetFactory.create(remoteId: 'server-copy')];
    when(() => drift.localAlbumRepository).thenReturn(repository);
    when(() => repository.getAssets('device-album')).thenAnswer((_) async => assets);
    await tester.pumpTestWidget(
      fixture,
      const LocalAlbumsPage(),
      overrides: [
        driftProvider.overrideWithValue(drift),
        localAlbumProvider.overrideWith(
          (ref) =>
              Stream.value([LocalAlbum(id: 'device-album', name: 'Camera', updatedAt: DateTime(2026), assetCount: 1)]),
        ),
        localAlbumThumbnailProvider.overrideWith((ref, id) => Stream.value(null)),
      ],
    );
    await reveal(tester);
    verifyNever(() => repository.getAssets(any()));
    await tester.drag(find.text('Camera'), const Offset(200, 0));
    await tester.pumpAndSettle();
    expect(find.byType(ConfirmDialog), findsNothing);
    await reveal(tester);
    await tester.tap(find.byTooltip('Delete album'));
    await tester.pumpAndSettle();
    await respond(tester, false);
    verifyNever(() => fixture.service.cleanup.service.deleteLocalAssetsDetailed(any()));
    await reveal(tester);
    await tester.tap(find.byTooltip('Delete album'));
    await tester.pumpAndSettle();
    await respond(tester, true);
    verify(() => fixture.service.cleanup.service.deleteLocalAssetsDetailed([assets.single.id])).called(1);
    verifyNever(() => fixture.service.asset.service.trash(any()));
    verifyNever(() => repository.deleteAlbum(any()));
    expect(tester.takeException(), isNull);
  });

  for (final scenario in ['success', 'changed', 'denied', 'shared']) {
    testWidgets('actual server album list $scenario: explicit trash button and exact asset operation', (tester) async {
      final api = _AlbumApi();
      final album = RemoteAlbumFactory.create(
        id: 'server-album',
        name: 'Camera',
        ownerId: fixture.currentUser.id,
        assetCount: 1,
      );
      final albums = _Albums(album);
      final asset = RemoteAssetFactory.create(ownerId: fixture.currentUser.id);
      var lookups = 0;
      AlbumTrashSnapshot snapshot(List<RemoteAsset> assets) => AlbumTrashSnapshot(
        id: album.id,
        name: album.name,
        ownerId: album.ownerId,
        updatedAt: DateTime(2026),
        assets: assets,
      );
      when(() => api.getTrashSnapshot(album.id, fixture.currentUser.id)).thenAnswer((_) async {
        lookups++;
        if (scenario == 'shared') {
          throw const AlbumTrashScopeException();
        }
        if (lookups >= 3) {
          return snapshot([]);
        }
        if (scenario == 'changed' && lookups == 2) {
          return snapshot([asset.copyWith(checksum: 'replacement')]);
        }
        return snapshot([asset]);
      });
      if (scenario == 'denied') {
        when(() => fixture.service.asset.service.trash(any())).thenThrow(StateError('synthetic rejection'));
      }
      await tester.pumpTestWidget(
        fixture,
        CustomScrollView(slivers: [AlbumSelector(onAlbumSelected: (_) {})]),
        overrides: [
          albumApiRepositoryProvider.overrideWithValue(api),
          remoteAlbumProvider.overrideWith(() => albums),
          appConfigProvider.overrideWithValue(const AppConfig()),
        ],
      );
      await reveal(tester);
      expect(lookups, 0);
      expect(albums.metadataDeletes, 0);
      await tester.tap(find.byTooltip('Delete album'));
      await tester.pumpAndSettle();
      if (scenario == 'shared') {
        expect(find.byType(ConfirmDialog), findsNothing);
      } else {
        await respond(tester, true);
      }
      if (scenario == 'success') {
        verify(() => fixture.service.asset.service.trash([asset.id])).called(1);
        expect(albums.metadataDeletes, 1);
        expect(find.text('Camera'), findsNothing);
        expect(find.text('Album deleted'), findsOneWidget);
      } else {
        expect(albums.metadataDeletes, 0);
        expect(find.text('Camera'), findsOneWidget);
        expect(find.text('Album deleted'), findsNothing);
        if (scenario != 'denied') {
          verifyNever(() => fixture.service.asset.service.trash(any()));
        }
      }
      verifyNever(() => fixture.service.cleanup.service.deleteLocalAssetsDetailed(any()));
      verifyNever(() => fixture.service.asset.service.acceptPermanentDeletion(any()));
    });
  }
}
