import 'dart:async';

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/sqlite_health.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/sync_stream.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline.repository.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:openapi/api.dart' as api;

api.SyncAssetV2 _asset(
  String id, {
  String? livePhotoVideoId,
  api.AssetTypeEnum type = api.AssetTypeEnum.IMAGE,
  api.AssetVisibility visibility = api.AssetVisibility.timeline,
}) => api.SyncAssetV2(
  id: id,
  checksum: 'content-$id',
  originalFileName: '$id.jpg',
  type: type,
  ownerId: 'owner',
  isFavorite: false,
  fileCreatedAt: DateTime(2025, 1, 7, 12),
  fileModifiedAt: DateTime(2025, 1, 7, 12),
  createdAt: DateTime(2026, 11, 1, 12),
  localDateTime: DateTime(2025, 1, 7, 12),
  visibility: visibility,
  width: 600,
  height: 1000,
  deletedAt: null,
  duration: null,
  libraryId: null,
  livePhotoVideoId: livePhotoVideoId,
  stackId: null,
  thumbhash: 'thumb-$id',
  isEdited: false,
);

void main() {
  setUpAll(() => initializeDateFormatting('en_US'));

  test('Build28 normal remote sync makes the saved ID reactive and idempotent in the FOTO timeline', () async {
    SqliteRecoveryGate.clearAfterValidatedRecovery();
    final db = Drift(drift.DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    addTearDown(db.close);
    final sync = SyncStreamRepository(db);
    final remote = RemoteAssetRepository(db);
    final timeline = TimelineRepository(db).main(['owner'], 'owner', GroupAssetsBy.day);
    await sync.updateUsersV1([
      api.SyncUserV1(
        id: 'owner',
        email: 'owner@example.test',
        name: 'Owner',
        deletedAt: null,
        avatarColor: const api.Optional.absent(),
        hasProfileImage: false,
        profileChangedAt: DateTime(2026, 11, 1),
      ),
    ]);
    await sync.updateAssetsV2([
      _asset('original-motion', type: api.AssetTypeEnum.VIDEO, visibility: api.AssetVisibility.hidden),
      _asset('original', livePhotoVideoId: 'original-motion'),
    ]);
    final original = await remote.get('original');
    expect(original?.livePhotoVideoId, 'original-motion');
    expect((await timeline.assetSource(0, 10)).map((asset) => asset.id), ['original']);

    // Subscribe before the change, as the already-open timeline does. This is
    // the real normal sync-DTO -> Drift -> timeline path, with synthetic data.
    final buckets = StreamIterator(timeline.bucketSource());
    addTearDown(buckets.cancel);
    expect(await buckets.moveNext(), isTrue);
    expect(buckets.current.fold<int>(0, (total, bucket) => total + bucket.assetCount), 1);
    final copyAppeared = remote.watch('saved-server-copy').firstWhere((asset) => asset != null);
    final nextBuckets = buckets.moveNext();
    final copy = _asset('saved-server-copy');
    await sync.updateAssetsV2([copy]);
    expect(await nextBuckets.timeout(const Duration(seconds: 2)), isTrue);
    expect(buckets.current.fold<int>(0, (total, bucket) => total + bucket.assetCount), 2);
    final imported = await copyAppeared.timeout(const Duration(seconds: 2));
    expect(imported?.id, copy.id);
    expect(imported?.thumbHash, copy.thumbhash);
    expect(imported?.width, 600);
    expect(imported?.height, 1000);

    // Repeat the same server event and reopen the same query: one saved ID is
    // still one tile, with no second original or paired-motion resource.
    await sync.updateAssetsV2([copy]);
    await sync.updateAssetsV2([copy]);
    final cards = await timeline.assetSource(0, 10);
    expect(cards.map((asset) => asset.id), unorderedEquals(['original', copy.id]));
    expect(cards.where((asset) => asset.id == copy.id), hasLength(1));
    expect(imported?.livePhotoVideoId, isNull);
    expect(await remote.get('original'), original);
    expect(await db.remoteAssetEntity.select().get(), hasLength(3));
  });
}
