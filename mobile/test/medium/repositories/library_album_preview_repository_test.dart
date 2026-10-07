import 'dart:async';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/table/remote/album.drift.dart';
import 'package:immich_mobile/data/db/main/table/remote/album_user.drift.dart';
import 'package:immich_mobile/data/db/main/table/remote/asset.drift.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_album.repository.dart';

import '../repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;
  late RemoteAlbumRepository repository;
  late String owner;

  setUp(() async {
    ctx = MediumRepositoryContext();
    repository = ctx.db.remoteAlbumRepository;
    owner = (await ctx.newUser()).id;
  });
  tearDown(() => ctx.dispose());

  Future<List<LibraryAlbumPreview>> nextWhere(
    StreamIterator<List<LibraryAlbumPreview>> iterator,
    bool Function(List<LibraryAlbumPreview>) predicate,
  ) async {
    while (await iterator.moveNext().timeout(const Duration(seconds: 5))) {
      if (predicate(iterator.current)) {
        return iterator.current;
      }
    }
    throw StateError('Preview stream ended');
  }

  test('initial empty is real data; late album and member sync update without refresh', () async {
    final iterator = StreamIterator(repository.watchLibraryPreview(owner));
    addTearDown(iterator.cancel);
    expect(await nextWhere(iterator, (_) => true), isEmpty);
    final album = await ctx.newRemoteAlbum(ownerId: owner);
    final albums = await nextWhere(iterator, (items) => items.isNotEmpty);
    expect(albums.single.albumId, album.id);
    expect(albums.single.thumbnailId, isNull);
    final asset = await ctx.newRemoteAsset(ownerId: owner);
    await ctx.newRemoteAlbumAsset(albumId: album.id, assetId: asset.id);
    expect(
      (await nextWhere(iterator, (items) => items.firstOrNull?.thumbnailId == asset.id)).single.thumbnailId,
      asset.id,
    );
  });

  test('cached server-only album is available immediately without original download', () async {
    final asset = await ctx.newRemoteAsset(ownerId: owner, thumbHash: 'hash');
    final album = await ctx.newRemoteAlbum(ownerId: owner, thumbnailAssetId: asset.id);
    await ctx.newRemoteAlbumAsset(albumId: album.id, assetId: asset.id);
    final previews = await repository.watchLibraryPreview(owner).first;
    expect(previews.single, (albumId: album.id, thumbnailId: asset.id, thumbHash: 'hash'));
  });

  test('album row arriving before user membership becomes visible when membership sync arrives', () async {
    await ctx.db
        .into(ctx.db.remoteAlbumEntity)
        .insert(const RemoteAlbumEntityCompanion(id: Value('late-album'), name: Value('Album'), order: Value(.asc)));
    final iterator = StreamIterator(repository.watchLibraryPreview(owner));
    addTearDown(iterator.cancel);
    expect(await nextWhere(iterator, (_) => true), isEmpty);
    await ctx.db
        .into(ctx.db.remoteAlbumUserEntity)
        .insert(
          RemoteAlbumUserEntityCompanion(
            albumId: const Value('late-album'),
            userId: Value(owner),
            role: const Value(.owner),
          ),
        );
    expect((await nextWhere(iterator, (items) => items.isNotEmpty)).single.albumId, 'late-album');
  });

  test('cover asset and album junction arriving later replace the album icon automatically', () async {
    final album = await ctx.newRemoteAlbum(ownerId: owner);
    final iterator = StreamIterator(repository.watchLibraryPreview(owner));
    addTearDown(iterator.cancel);
    expect((await nextWhere(iterator, (_) => true)).single.thumbnailId, isNull);
    final lateAsset = await ctx.newRemoteAsset(ownerId: owner, thumbHash: 'late-cover-hash');
    await (ctx.db.update(ctx.db.remoteAlbumEntity)..where((row) => row.id.equals(album.id))).write(
      RemoteAlbumEntityCompanion(thumbnailAssetId: Value(lateAsset.id)),
    );
    await ctx.newRemoteAlbumAsset(albumId: album.id, assetId: lateAsset.id);
    final updated = await nextWhere(iterator, (items) => items.single.thumbnailId == lateAsset.id);
    expect(updated.single.thumbHash, 'late-cover-hash');
  });

  test('configured eligible cover takes priority over newest member', () async {
    final cover = await ctx.newRemoteAsset(ownerId: owner, createdAt: DateTime(2020));
    final newest = await ctx.newRemoteAsset(ownerId: owner, createdAt: DateTime(2025));
    final album = await ctx.newRemoteAlbum(ownerId: owner, thumbnailAssetId: cover.id);
    await ctx.newRemoteAlbumAsset(albumId: album.id, assetId: cover.id);
    await ctx.newRemoteAlbumAsset(albumId: album.id, assetId: newest.id);
    expect((await repository.watchLibraryPreview(owner).first).single.thumbnailId, cover.id);
  });

  test('trash cover immediately falls back and restore makes it eligible again', () async {
    final cover = await ctx.newRemoteAsset(ownerId: owner);
    final other = await ctx.newRemoteAsset(ownerId: owner);
    final album = await ctx.newRemoteAlbum(ownerId: owner, thumbnailAssetId: cover.id);
    await ctx.newRemoteAlbumAsset(albumId: album.id, assetId: cover.id);
    await ctx.newRemoteAlbumAsset(albumId: album.id, assetId: other.id);
    final iterator = StreamIterator(repository.watchLibraryPreview(owner));
    addTearDown(iterator.cancel);
    expect((await nextWhere(iterator, (_) => true)).single.thumbnailId, cover.id);
    await (ctx.db.update(
      ctx.db.remoteAssetEntity,
    )..where((asset) => asset.id.equals(cover.id))).write(RemoteAssetEntityCompanion(deletedAt: Value(DateTime(2026))));
    expect((await nextWhere(iterator, (items) => items.single.thumbnailId == other.id)).single.thumbnailId, other.id);
    await (ctx.db.update(
      ctx.db.remoteAssetEntity,
    )..where((asset) => asset.id.equals(cover.id))).write(const RemoteAssetEntityCompanion(deletedAt: Value(null)));
    expect((await nextWhere(iterator, (items) => items.single.thumbnailId == cover.id)).single.thumbnailId, cover.id);
  });

  test('hidden, Locked, trashed and motion companion cannot be representatives', () async {
    final album = await ctx.newRemoteAlbum(ownerId: owner);
    for (final visibility in [AssetVisibility.hidden, AssetVisibility.locked]) {
      final asset = await ctx.newRemoteAsset(ownerId: owner, visibility: visibility);
      await ctx.newRemoteAlbumAsset(albumId: album.id, assetId: asset.id);
    }
    final trash = await ctx.newRemoteAsset(ownerId: owner, deletedAt: DateTime(2026));
    final motion = await ctx.newRemoteAsset(ownerId: owner, type: AssetType.video);
    await ctx.newRemoteAsset(ownerId: owner, livePhotoVideoId: motion.id);
    await ctx.newRemoteAlbumAsset(albumId: album.id, assetId: trash.id);
    await ctx.newRemoteAlbumAsset(albumId: album.id, assetId: motion.id);
    expect((await repository.watchLibraryPreview(owner).first).single.thumbnailId, isNull);
    final safe = await ctx.newRemoteAsset(ownerId: owner, visibility: AssetVisibility.archive);
    await ctx.newRemoteAlbumAsset(albumId: album.id, assetId: safe.id);
    expect((await repository.watchLibraryPreview(owner).first).single.thumbnailId, safe.id);
  });

  test('album with every member trashed stays a real album with icon fallback', () async {
    final album = await ctx.newRemoteAlbum(ownerId: owner);
    final asset = await ctx.newRemoteAsset(ownerId: owner, deletedAt: DateTime(2026));
    await ctx.newRemoteAlbumAsset(albumId: album.id, assetId: asset.id);
    final previews = await repository.watchLibraryPreview(owner).first;
    expect(previews, hasLength(1));
    expect(previews.single.thumbnailId, isNull);
  });

  test('account membership excludes another user albums', () async {
    final otherOwner = (await ctx.newUser()).id;
    final other = await ctx.newRemoteAlbum(ownerId: otherOwner);
    final own = await ctx.newRemoteAlbum(ownerId: owner);
    expect((await repository.watchLibraryPreview(owner).first).map((item) => item.albumId), [own.id]);
    expect((await repository.watchLibraryPreview(otherOwner).first).map((item) => item.albumId), [other.id]);
  });

  test('mosaic is bounded to four; usable covers precede empty albums', () async {
    for (var i = 0; i < 10; i++) {
      await ctx.newRemoteAlbum(ownerId: owner, updatedAt: DateTime(2026));
    }
    final asset = await ctx.newRemoteAsset(ownerId: owner);
    final older = await ctx.newRemoteAlbum(ownerId: owner, updatedAt: DateTime(2020));
    await ctx.newRemoteAlbumAsset(albumId: older.id, assetId: asset.id);
    final previews = await repository.watchLibraryPreview(owner).first;
    expect(previews, hasLength(4));
    expect(previews.first.thumbnailId, asset.id);
  });

  test('resubscribe after background/disposal reads sync writes made while absent', () async {
    expect(await repository.watchLibraryPreview(owner).first, isEmpty);
    final asset = await ctx.newRemoteAsset(ownerId: owner);
    final album = await ctx.newRemoteAlbum(ownerId: owner);
    await ctx.newRemoteAlbumAsset(albumId: album.id, assetId: asset.id);
    expect((await repository.watchLibraryPreview(owner).first).single.thumbnailId, asset.id);
  });
}
