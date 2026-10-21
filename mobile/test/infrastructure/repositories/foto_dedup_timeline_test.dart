import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/table/remote/asset.drift.dart';
import 'package:immich_mobile/data/db/main/table/remote/shared_space_album_asset.drift.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline.repository.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../../medium/repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;
  late TimelineRepository repository;
  final captured = DateTime(2026, 10, 1, 12);

  setUpAll(() async => initializeDateFormatting('en'));
  setUp(() async {
    ctx = MediumRepositoryContext();
    repository = TimelineRepository(ctx.db);
    await ctx.newUser(id: 'owner');
    await ctx.newAuthUser(id: 'owner');
    await ctx.newRemoteAsset(id: 'original', ownerId: 'owner', checksum: 'actual-bytes', createdAt: captured);
    for (final id in ['local-b', 'local-a']) {
      await ctx.newLocalAsset(id: id, checksum: 'actual-bytes', createdAt: captured);
    }
    await ctx.newSharedSpace(id: 'space', createdById: 'owner');
    await ctx.newSharedSpaceMember(spaceId: 'space', userId: 'owner');
    await ctx.insertSharedSpaceAsset(spaceId: 'space', assetId: 'original');
  });
  tearDown(() async => ctx.dispose());

  Future<void> oneCard(TimelineQuery query) async {
    final buckets = await query.bucketSource().first;
    expect(buckets.fold<int>(0, (n, b) => n + (b as TimeBucket).assetCount), 1);
    final assets = await query.assetSource(0, 100);
    expect(assets.map((a) => a.remoteId), ['original']);
    expect(assets.single.localId, anyOf('local-a', 'local-b'));
    expect((await query.assetSource(0, 1)).single.remoteId, 'original');
    expect(await query.assetSource(1, 1), isEmpty, reason: 'Pagination must not replay another local match');
  }

  test('main timeline has one card for one original with two device copies', () async {
    await oneCard(repository.main(['owner'], 'owner', GroupAssetsBy.day));
  });

  test('shared space has one card for one original with two device copies', () async {
    await oneCard(repository.sharedSpace('space', GroupAssetsBy.day));
  });

  test('shared album has one card for one original with two device copies', () async {
    await ctx.newSharedSpaceAlbum(id: 'album');
    await ctx.db
        .into(ctx.db.sharedSpaceAlbumAssetEntity)
        .insert(SharedSpaceAlbumAssetEntityCompanion.insert(albumId: 'album', assetId: 'original'));
    await oneCard(repository.spaceAlbum('space', 'album', GroupAssetsBy.day));
  });

  test('Trash and restored timeline agree with counts and pagination with two device copies', () async {
    await (ctx.db.update(ctx.db.remoteAssetEntity)..where((r) => r.id.equals('original'))).write(
      RemoteAssetEntityCompanion(deletedAt: Value(DateTime(2026, 10, 2))),
    );
    await oneCard(repository.trash('owner', GroupAssetsBy.day));
    expect(await repository.main(['owner'], 'owner', GroupAssetsBy.day).assetSource(0, 100), isEmpty);
    await (ctx.db.update(
      ctx.db.remoteAssetEntity,
    )..where((r) => r.id.equals('original'))).write(const RemoteAssetEntityCompanion(deletedAt: Value(null)));
    await oneCard(repository.main(['owner'], 'owner', GroupAssetsBy.day));
  });

  test('one original linked directly and through its external library is not duplicated', () async {
    await ctx.newLibrary(id: 'nas-library', ownerId: 'owner');
    await (ctx.db.update(
      ctx.db.remoteAssetEntity,
    )..where((r) => r.id.equals('original'))).write(const RemoteAssetEntityCompanion(libraryId: Value('nas-library')));
    await ctx.insertSharedSpaceLibrary(spaceId: 'space', libraryId: 'nas-library');
    await oneCard(repository.sharedSpace('space', GroupAssetsBy.day));
  });

  test('different owners keep separate asset identities even with the same bytes', () async {
    await ctx.newUser(id: 'other');
    await ctx.newRemoteAsset(id: 'other-original', ownerId: 'other', checksum: 'actual-bytes', createdAt: captured);
    final assets = await repository.main(['owner', 'other'], 'owner', GroupAssetsBy.day).assetSource(0, 100);
    expect(assets.map((a) => a.remoteId), unorderedEquals(['original', 'other-original']));
    expect(await repository.main(['owner'], 'owner', GroupAssetsBy.day).assetSource(0, 100), hasLength(1));
  });

  test('an edited version with different bytes remains a separate card', () async {
    await ctx.newRemoteAsset(id: 'edited', ownerId: 'owner', checksum: 'edited-bytes', createdAt: captured);
    final assets = await repository.main(['owner'], 'owner', GroupAssetsBy.day).assetSource(0, 100);
    expect(assets.map((a) => a.remoteId), unorderedEquals(['original', 'edited']));
  });

  test('Live Photo still keeps its motion link with multiple local copies', () async {
    await ctx.newRemoteAsset(
      id: 'motion',
      ownerId: 'owner',
      type: AssetType.video,
      checksum: 'motion-bytes',
      visibility: AssetVisibility.hidden,
      createdAt: captured,
    );
    await (ctx.db.update(ctx.db.remoteAssetEntity)..where((r) => r.id.equals('original'))).write(
      const RemoteAssetEntityCompanion(livePhotoVideoId: Value('motion')),
    );
    final assets = await repository.sharedSpace('space', GroupAssetsBy.day).assetSource(0, 100);
    expect(assets, hasLength(1));
    expect((assets.single as RemoteAsset).livePhotoVideoId, 'motion');
  });
}
