import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/table/remote/exif.drift.dart';
import 'package:immich_mobile/domain/models/album/album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/models/timeline_temporal_scope.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/sync_stream.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline.repository.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:openapi/api.dart' as api;

import '../../medium/repository_context.dart';

Future<List<TimeBucket>> _timeBuckets(TimelineQuery query) async => (await query.bucketSource().first).cast();

Future<List<String>> _ids(TimelineQuery query, {int offset = 0, int count = 100}) async =>
    (await query.assetSource(offset, count)).map((asset) => asset.remoteId!).toList();

api.SyncAssetV1 _syncAssetV1({required DateTime captured, required DateTime? deleted}) => api.SyncAssetV1(
  id: 'synced',
  checksum: 'synced-checksum',
  originalFileName: 'synced.jpg',
  type: api.AssetTypeEnum.IMAGE,
  ownerId: 'owner',
  isFavorite: false,
  fileCreatedAt: captured,
  fileModifiedAt: captured,
  createdAt: DateTime(2026, 1, 1),
  localDateTime: captured,
  visibility: api.AssetVisibility.timeline,
  width: 100,
  height: 200,
  deletedAt: deleted,
  duration: null,
  libraryId: null,
  livePhotoVideoId: null,
  stackId: null,
  thumbhash: null,
  isEdited: false,
);

api.SyncAssetV2 _syncAssetV2({required DateTime captured, required DateTime? deleted}) => api.SyncAssetV2(
  id: 'synced',
  checksum: 'synced-checksum',
  originalFileName: 'synced.jpg',
  type: api.AssetTypeEnum.IMAGE,
  ownerId: 'owner',
  isFavorite: false,
  fileCreatedAt: captured,
  fileModifiedAt: captured,
  createdAt: DateTime(2026, 1, 1),
  localDateTime: captured,
  visibility: api.AssetVisibility.timeline,
  width: 100,
  height: 200,
  deletedAt: deleted,
  duration: null,
  libraryId: null,
  livePhotoVideoId: null,
  stackId: null,
  thumbhash: null,
  isEdited: false,
);

void main() {
  late MediumRepositoryContext ctx;
  late TimelineRepository repository;

  setUpAll(() async => initializeDateFormatting('en'));

  setUp(() async {
    ctx = MediumRepositoryContext();
    repository = TimelineRepository(ctx.db);
    await ctx.newUser(id: 'owner');
  });

  tearDown(() async => ctx.dispose());

  test('most recently deleted old photo comes first, independently of capture and upload dates', () async {
    await ctx.newRemoteAsset(
      id: 'old-photo',
      ownerId: 'owner',
      createdAt: DateTime(2014, 1, 1),
      deletedAt: DateTime(2026, 10, 5, 12),
    );
    await ctx.newRemoteAsset(
      id: 'new-photo',
      ownerId: 'owner',
      createdAt: DateTime(2026, 10, 1),
      deletedAt: DateTime(2026, 10, 4, 12),
    );

    final query = repository.trash('owner', GroupAssetsBy.day);
    expect(await _ids(query), ['old-photo', 'new-photo']);
    expect(await _timeBuckets(query), [
      TimeBucket(date: DateTime(2026, 10, 5), assetCount: 1),
      TimeBucket(date: DateTime(2026, 10, 4), assetCount: 1),
    ]);
    final assets = await query.assetSource(0, 2);
    expect(assets.first.createdAt, DateTime(2014, 1, 1));
    expect((assets.first as RemoteAsset).deletedAt, DateTime(2026, 10, 5, 12));
  });

  test('deletion-day buckets combine captures from different years, exclude active assets and other owners', () async {
    await ctx.newRemoteAsset(
      id: 'image',
      ownerId: 'owner',
      createdAt: DateTime(2009, 1, 1),
      deletedAt: DateTime(2026, 10, 5, 10),
    );
    await ctx.newRemoteAsset(
      id: 'video',
      ownerId: 'owner',
      createdAt: DateTime(2025, 6, 2),
      deletedAt: DateTime(2026, 10, 5, 11),
      type: AssetType.video,
    );
    await ctx.newRemoteAsset(id: 'active', ownerId: 'owner');
    await ctx.newUser(id: 'other');
    await ctx.newRemoteAsset(id: 'foreign', ownerId: 'other', deletedAt: DateTime(2026, 10, 6));

    final query = repository.trash('owner', GroupAssetsBy.day);
    expect(await _ids(query), ['video', 'image']);
    expect(await _timeBuckets(query), [TimeBucket(date: DateTime(2026, 10, 5), assetCount: 2)]);
  });

  test('month and year overview buckets are deletion periods, with mixed assets and Live pair preserved', () async {
    await ctx.newRemoteAsset(
      id: 'live-photo',
      ownerId: 'owner',
      createdAt: DateTime(2018, 1, 1),
      deletedAt: DateTime(2026, 10, 5),
      livePhotoVideoId: 'motion-component',
    );
    await ctx.newRemoteAsset(
      id: 'video',
      ownerId: 'owner',
      createdAt: DateTime(2024, 2, 2),
      deletedAt: DateTime(2026, 9, 30),
      type: AssetType.video,
    );
    await ctx.newRemoteAsset(
      id: 'earlier-year',
      ownerId: 'owner',
      createdAt: DateTime(2026, 3, 3),
      deletedAt: DateTime(2025, 12, 31),
    );

    expect(await _timeBuckets(repository.trash('owner', GroupAssetsBy.month)), [
      TimeBucket(date: DateTime(2026, 10), assetCount: 1),
      TimeBucket(date: DateTime(2026, 9), assetCount: 1),
      TimeBucket(date: DateTime(2025, 12), assetCount: 1),
    ]);
    expect(await _timeBuckets(repository.trash('owner', GroupAssetsBy.year)), [
      TimeBucket(date: DateTime(2026), assetCount: 2),
      TimeBucket(date: DateTime(2025), assetCount: 1),
    ]);
    final asset = (await repository.trash('owner', GroupAssetsBy.month).assetSource(0, 1)).single as RemoteAsset;
    expect(asset.livePhotoVideoId, 'motion-component');
  });

  test('month drilldown filters by deletedAt, including original captures outside the selected period', () async {
    await ctx.newRemoteAsset(
      id: 'deleted-in-scope',
      ownerId: 'owner',
      createdAt: DateTime(2015, 1, 1),
      deletedAt: DateTime(2026, 10, 5),
    );
    await ctx.newRemoteAsset(
      id: 'captured-in-scope',
      ownerId: 'owner',
      createdAt: DateTime(2026, 10, 2),
      deletedAt: DateTime(2026, 9, 30),
    );
    final scope = TimelineTemporalScope.month(year: 2026, month: 10);
    final query = repository.trash('owner', GroupAssetsBy.day, temporalScope: scope);

    expect(await _ids(query), ['deleted-in-scope']);
    expect(await _timeBuckets(query), [TimeBucket(date: DateTime(2026, 10, 5), assetCount: 1)]);
    expect(await repository.trash('owner', GroupAssetsBy.none, temporalScope: scope).bucketSource().first, [
      const Bucket(assetCount: 1),
    ]);
  });

  test('year drilldown selects deletion year rather than capture year', () async {
    await ctx.newRemoteAsset(
      id: 'old-capture',
      ownerId: 'owner',
      createdAt: DateTime(2012, 1, 1),
      deletedAt: DateTime(2026, 10, 5),
    );
    await ctx.newRemoteAsset(
      id: 'current-capture',
      ownerId: 'owner',
      createdAt: DateTime(2026, 1, 1),
      deletedAt: DateTime(2025, 12, 31),
    );
    final query = repository.trash('owner', GroupAssetsBy.month, temporalScope: const TimelineTemporalScope.year(2026));

    expect(await _ids(query), ['old-capture']);
    expect(await _timeBuckets(query), [TimeBucket(date: DateTime(2026, 10), assetCount: 1)]);
  });

  test('equal deletion timestamps have deterministic pagination without omitted or repeated assets', () async {
    for (final id in ['c', 'a', 'b']) {
      await ctx.newRemoteAsset(id: id, ownerId: 'owner', deletedAt: DateTime(2026, 10, 5));
    }
    final query = repository.trash('owner', GroupAssetsBy.day);

    expect(await _ids(query, count: 2), ['a', 'b']);
    expect(await _ids(query, offset: 2, count: 2), ['c']);
    expect(await _ids(query), ['a', 'b', 'c']);
  });

  test('matched local original does not replace authoritative remote deletion/capture dates', () async {
    await ctx.newRemoteAsset(
      id: 'remote',
      ownerId: 'owner',
      checksum: 'matching-checksum',
      createdAt: DateTime(2010, 1, 1),
      deletedAt: DateTime(2026, 10, 5),
    );
    await ctx.newLocalAsset(id: 'local', checksum: 'matching-checksum', createdAt: DateTime(2026, 1, 1));
    final asset = (await repository.trash('owner', GroupAssetsBy.day).assetSource(0, 10)).single as RemoteAsset;

    expect(asset.localId, 'local');
    expect(asset.createdAt, DateTime(2010, 1, 1));
    expect(asset.deletedAt, DateTime(2026, 10, 5));
  });

  test('deletion bucket uses the device calendar for a server timestamp with explicit timezone', () async {
    final deletion = DateTime.parse('2026-10-05T00:30:00+03:00');
    await ctx.newRemoteAsset(id: 'timestamp', ownerId: 'owner', deletedAt: deletion);
    final local = deletion.toLocal();

    expect(await _timeBuckets(repository.trash('owner', GroupAssetsBy.day)), [
      TimeBucket(date: DateTime(local.year, local.month, local.day), assetCount: 1),
    ]);
  });

  for (final syncVersion in [1, 2]) {
    test(
      'sync V$syncVersion authoritative deletion updates regroup immediately and restore original chronology',
      () async {
        final sync = SyncStreamRepository(ctx.db);
        final capture = DateTime(2014, 4, 20, 12);
        Future<void> apply(DateTime? deleted) => syncVersion == 1
            ? sync.updateAssetsV1([_syncAssetV1(captured: capture, deleted: deleted)])
            : sync.updateAssetsV2([_syncAssetV2(captured: capture, deleted: deleted)]);

        await apply(DateTime(2026, 10, 4));
        final buckets = StreamIterator(repository.trash('owner', GroupAssetsBy.day).bucketSource());
        addTearDown(buckets.cancel);
        expect(await buckets.moveNext().timeout(const Duration(seconds: 2)), isTrue);
        expect(buckets.current, [TimeBucket(date: DateTime(2026, 10, 4), assetCount: 1)]);

        await apply(DateTime(2026, 10, 5));
        expect(await buckets.moveNext().timeout(const Duration(seconds: 2)), isTrue);
        expect(buckets.current, [TimeBucket(date: DateTime(2026, 10, 5), assetCount: 1)]);
        // A new repository instance reads the persisted server timestamp; no in-memory sorting state.
        expect(await _timeBuckets(TimelineRepository(ctx.db).trash('owner', GroupAssetsBy.day)), buckets.current);
        expect((await repository.trash('owner', GroupAssetsBy.day).assetSource(0, 1)).single.createdAt, capture);

        await sync.confirmRestore((await sync.getRestoreCandidates({'synced': 'owner'})).single);
        await apply(null);
        expect(await buckets.moveNext().timeout(const Duration(seconds: 2)), isTrue);
        expect(buckets.current, isEmpty);
        expect(await _timeBuckets(repository.remote('owner', GroupAssetsBy.day)), [
          TimeBucket(date: DateTime(2014, 4, 20), assetCount: 1),
        ]);
        expect((await repository.remote('owner', GroupAssetsBy.day).assetSource(0, 1)).single.createdAt, capture);
      },
    );
  }

  test('restore leaves EXIF untouched and returns the photo to original timeline/album chronology', () async {
    final capture = DateTime(2010, 7, 15, 12);
    await ctx.newRemoteAsset(
      id: 'restored',
      ownerId: 'owner',
      createdAt: capture,
      deletedAt: DateTime(2026, 10, 5),
      isFavorite: true,
    );
    await ctx.newRemoteAsset(id: 'recent', ownerId: 'owner', createdAt: DateTime(2025, 1, 1), isFavorite: true);
    final album = await ctx.newRemoteAlbum(ownerId: 'owner', order: AlbumAssetOrder.desc);
    await ctx.newRemoteAlbumAsset(albumId: album.id, assetId: 'restored');
    await ctx.newRemoteAlbumAsset(albumId: album.id, assetId: 'recent');
    await ctx.db
        .into(ctx.db.remoteExifEntity)
        .insert(
          RemoteExifEntityCompanion.insert(
            assetId: 'restored',
            dateTimeOriginal: Value(capture),
            timeZone: const Value('UTC+03:00'),
            orientation: const Value('6'),
          ),
        );
    final originalExif = await ctx.db.select(ctx.db.remoteExifEntity).getSingle();
    expect(await _ids(repository.remote('owner', GroupAssetsBy.day)), ['recent']);

    await RemoteAssetRepository(ctx.db).restoreTrash(['restored']);

    expect(await _ids(repository.trash('owner', GroupAssetsBy.day)), isEmpty);
    expect(await _ids(repository.main(['owner'], 'owner', GroupAssetsBy.day)), ['recent', 'restored']);
    expect(await _ids(repository.remoteAlbum(album.id, GroupAssetsBy.day)), ['recent', 'restored']);
    expect(await _ids(repository.favorite('owner', GroupAssetsBy.day)), ['recent', 'restored']);
    expect(await ctx.db.select(ctx.db.remoteExifEntity).getSingle(), originalExif);
    final captures = await repository.remote('owner', GroupAssetsBy.day).assetSource(0, 2);
    final searchQuery = repository.fromAssetsWithBuckets(captures, TimelineOrigin.search);
    expect(await _ids(searchQuery), ['recent', 'restored']);
    expect(await _timeBuckets(searchQuery), [
      TimeBucket(date: DateTime(2025, 1, 1), assetCount: 1),
      TimeBucket(date: DateTime(2010, 7, 15), assetCount: 1),
    ]);
  });
}
