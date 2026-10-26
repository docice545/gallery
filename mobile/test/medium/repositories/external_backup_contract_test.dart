import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' hide isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/infrastructure/repositories/backup.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline.repository.dart';
import 'package:openapi/api.dart' as api;

import '../repository_context.dart';

// These are the existing wire fields understood by installed clients. There is
// no new checksum field, synthetic Managed UUID or client-side hiding rule.
Map<String, dynamic> _legacyAssetJson({
  required String owner,
  required String checksum,
  String id = 'external-original',
  String? deletedAt,
}) => {
  'id': id,
  'ownerId': owner,
  'originalFileName': '20261025_173327.jpg',
  'checksum': checksum,
  'type': 'IMAGE',
  'fileCreatedAt': '2026-10-25T17:33:27Z',
  'fileModifiedAt': '2026-10-25T17:33:27Z',
  'createdAt': '2026-10-25T17:33:27Z',
  'localDateTime': '2026-10-25T17:33:27Z',
  'isFavorite': false,
  'isEdited': false,
  'visibility': 'timeline',
  'libraryId': 'external-library',
  'deletedAt': deletedAt,
  'duration': null,
  'height': null,
  'width': null,
  'livePhotoVideoId': null,
  'stackId': null,
  'thumbhash': null,
};

void main() {
  const owner = 'photo-owner';
  final contentChecksum = base64Encode(sha1.convert(utf8.encode('synthetic original bytes')).bytes);
  final pathChecksum = base64Encode(sha1.convert(utf8.encode('path:/synthetic/external.jpg')).bytes);
  late MediumRepositoryContext ctx;
  late BackupRepository backups;
  late TimelineRepository timelines;

  setUp(() async {
    ctx = MediumRepositoryContext();
    await ctx.newUser(id: owner);
    await ctx.newAuthUser(id: owner);
    backups = BackupRepository(ctx.db);
    timelines = TimelineRepository(ctx.db);
    final album = await ctx.newLocalAlbum(backupSelection: BackupSelection.selected);
    final local = await ctx.newLocalAsset(id: 'phone-original', name: '20261025_173327.jpg', checksum: contentChecksum);
    await ctx.newLocalAlbumAsset(albumId: album.id, assetId: local.id);
  });

  tearDown(() => ctx.dispose());

  Future<List<BaseAsset>> mainTimeline() => timelines.main([owner], owner, GroupAssetsBy.day).assetSource(0, 50);

  for (final version in [1, 2]) {
    Future<void> sync(Map<String, dynamic> json) => version == 1
        ? ctx.db.syncStreamRepository.updateAssetsV1([api.SyncAssetV1.fromJson(json)!])
        : ctx.db.syncStreamRepository.updateAssetsV2([api.SyncAssetV2.fromJson(json)!]);

    test('legacy V$version checksum joins a verified External original into one backed-up tile', () async {
      await sync(_legacyAssetJson(owner: owner, checksum: pathChecksum));
      expect(await backups.getCandidates(owner), hasLength(1));
      expect(await mainTimeline(), hasLength(2));

      // Verified admission reuses the real External ID and updates its existing
      // checksum payload. The unmodified installed-client join now converges.
      final json = _legacyAssetJson(owner: owner, checksum: contentChecksum);
      await sync(json);
      final assets = await mainTimeline();
      expect(assets, hasLength(1));
      expect(assets.single.remoteId, 'external-original');
      expect(assets.single.localId, 'phone-original');
      expect(assets.single.storage, AssetState.merged);
      expect(await backups.getCandidates(owner), isEmpty);
      expect(await backups.getAllCounts(owner), (total: 1, remainder: 0, processing: 0));
      expect(await ctx.db.remoteAssetEntity.select().get(), hasLength(1));
      final local = await ctx.db.localAssetEntity.select().getSingle();
      expect(local.id, 'phone-original');
      expect(local.checksum, contentChecksum);

      // Delivery/restart sync and the library stream update the same row.
      await sync(json);
      await ctx.db.syncStreamRepository.updateLibraryAssetsV1([api.SyncAssetV1.fromJson(json)!]);
      expect(await mainTimeline(), hasLength(1));
      expect(await backups.getCandidates(owner), isEmpty);
      expect(await ctx.db.remoteAssetEntity.select().get(), hasLength(1));
      expect(await ctx.db.trashedLocalAssetEntity.select().get(), isEmpty);
    });

    test('legacy V$version makes a changed/unverified External original a backup candidate again', () async {
      await sync(_legacyAssetJson(owner: owner, checksum: contentChecksum));
      expect(await backups.getCandidates(owner), isEmpty);

      // A server-side failed revalidation clears the verified content digest;
      // the existing path identity cannot confirm a different local original.
      await sync(_legacyAssetJson(owner: owner, checksum: pathChecksum));
      expect(await backups.getCandidates(owner), hasLength(1));
      expect(await backups.getAllCounts(owner), (total: 1, remainder: 1, processing: 0));
      expect(await ctx.db.localAssetEntity.select().get(), hasLength(1));
      expect(await ctx.db.remoteAssetEntity.select().get(), hasLength(1));
      expect(await ctx.db.trashedLocalAssetEntity.select().get(), isEmpty);
    });

    test('legacy V$version does not confirm a same-name different-content photo', () async {
      final otherChecksum = base64Encode(sha1.convert(utf8.encode('edited synthetic bytes')).bytes);
      await sync(_legacyAssetJson(owner: owner, checksum: otherChecksum));
      expect(await backups.getCandidates(owner), hasLength(1));
      expect(await mainTimeline(), hasLength(2));
      expect(await backups.getAllCounts(owner), (total: 1, remainder: 1, processing: 0));
    });

    test('legacy V$version cannot use another owners equal-content original as this users backup', () async {
      await ctx.newUser(id: 'other-owner');
      await sync(_legacyAssetJson(owner: 'other-owner', checksum: contentChecksum));
      expect(await backups.getCandidates(owner), hasLength(1));
      final assets = await mainTimeline();
      expect(assets, hasLength(1));
      expect(assets.single.storage, AssetState.local);
      expect(await backups.getAllCounts(owner), (total: 1, remainder: 1, processing: 0));
    });
  }

  test('existing remote lookup retains the External UUID while resolving the local copy', () async {
    await ctx.db.syncStreamRepository.updateAssetsV1([
      api.SyncAssetV1.fromJson(_legacyAssetJson(owner: owner, checksum: contentChecksum))!,
    ]);
    final asset = await RemoteAssetRepository(ctx.db).get('external-original');
    expect(asset?.id, 'external-original');
    expect(asset?.localId, 'phone-original');
    expect(asset?.storage, AssetState.merged);
    expect(await ctx.db.remoteAssetEntity.select().getSingle(), isNotNull);
    expect(await ctx.db.localAssetEntity.select().getSingle(), isNotNull);
  });
}
