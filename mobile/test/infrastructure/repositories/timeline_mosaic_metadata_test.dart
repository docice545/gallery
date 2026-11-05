import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/table/remote/asset.drift.dart';
import 'package:immich_mobile/data/db/main/table/remote/stack.drift.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/models/timeline_temporal_scope.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline.repository.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../../medium/repository_context.dart';

double _ratio(BaseAsset asset) => (asset.width ?? 0) > 0 && (asset.height ?? 0) > 0 ? asset.width! / asset.height! : 1;

void main() {
  late MediumRepositoryContext ctx;
  late TimelineRepository repository;
  final day = DateTime.utc(2026, 11, 1, 12);

  setUpAll(() => initializeDateFormatting('en'));
  setUp(() async {
    ctx = MediumRepositoryContext();
    repository = TimelineRepository(ctx.db);
    await ctx.newUser(id: 'owner');
    await ctx.newUser(id: 'other');
    await ctx.newLocalAlbum(id: 'camera', backupSelection: BackupSelection.selected);
  });
  tearDown(() => ctx.dispose());

  Future<void> local(String id, {required double ratio, String? checksum, DateTime? date}) async {
    await ctx.newLocalAsset(
      id: id,
      checksum: checksum ?? 'checksum-$id',
      createdAt: date ?? day,
      width: (1000 * ratio).round(),
      height: 1000,
    );
    await ctx.newLocalAlbumAsset(albumId: 'camera', assetId: id);
  }

  Future<void> remote(String id, {required double ratio, String? checksum, DateTime? date}) async {
    await ctx.newRemoteAsset(
      id: id,
      ownerId: 'owner',
      checksum: checksum ?? 'checksum-$id',
      createdAt: date ?? day,
      width: (1000 * ratio).round(),
      height: 1000,
    );
  }

  Future<void> assertPagedGeometry(TimelineQuery query, {int pageSize = 2}) async {
    final buckets = await query.bucketSource().first;
    final count = buckets.fold<int>(0, (count, bucket) => count + bucket.assetCount);
    final paged = <BaseAsset>[];
    for (var offset = 0; offset < count; offset += pageSize) {
      paged.addAll(await query.assetSource(offset, pageSize));
    }
    expect(paged, hasLength(count));
    expect(paged.map((asset) => asset.id).toSet(), hasLength(count));
    expect(buckets.expand((bucket) => bucket.aspectRatios!), orderedEquals(paged.map(_ratio)));
    var offset = 0;
    for (final bucket in buckets) {
      expect(bucket.aspectRatios, hasLength(bucket.assetCount));
      expect(bucket.aspectRatios, orderedEquals((await query.assetSource(offset, bucket.assetCount)).map(_ratio)));
      offset += bucket.assetCount;
    }
    expect(await query.assetSource(count, pageSize), isEmpty);
  }

  test('main metadata matches paged remote/local/merged order, including identical capture times', () async {
    await remote('remote-a', ratio: .5);
    await remote('remote-z', ratio: 2);
    await remote('remote-m', ratio: 1.25, checksum: 'merged-checksum');
    await local('local-copy', ratio: 1.25, checksum: 'merged-checksum');
    await local('local-a', ratio: .75);
    await local('local-z', ratio: 1.5);
    final query = repository.main(['owner'], 'owner', GroupAssetsBy.day);
    await assertPagedGeometry(query, pageSize: 1);
    final assets = await query.assetSource(0, 20);
    expect(assets, hasLength(5));
    expect(assets.singleWhere((asset) => asset.id == 'remote-m').storage, AssetState.merged);
    expect(assets.map((asset) => asset.id), isNot(contains('local-copy')));
    // Repeated reads retain the same tie order, which row geometry must share.
    expect((await query.assetSource(0, 20)).map((asset) => asset.id), orderedEquals(assets.map((asset) => asset.id)));
  });

  for (final grouping in [GroupAssetsBy.day, GroupAssetsBy.month, GroupAssetsBy.year]) {
    test('ordered geometry follows $grouping boundaries without borrowing the next bucket', () async {
      await remote('november', ratio: .5, date: DateTime.utc(2026, 11, 1, 12));
      await remote('october-late', ratio: 1.5, date: DateTime.utc(2026, 10, 31, 12));
      await local('october-earlier', ratio: .75, date: DateTime.utc(2026, 10, 20, 12));
      await remote('previous-year', ratio: 2, date: DateTime.utc(2025, 11, 1, 12));
      final query = repository.main(['owner'], 'owner', grouping);
      await assertPagedGeometry(query);
      final dates = (await query.bucketSource().first).cast<TimeBucket>().map((bucket) => bucket.date).toList();
      expect(dates, orderedEquals([...dates]..sort((a, b) => b.compareTo(a))));
    });
  }

  test('effective local capture dates determine bucket and source order across midnight', () async {
    await ctx.newRemoteAsset(
      id: 'later-local-day',
      ownerId: 'owner',
      createdAt: DateTime.utc(2026, 10, 31, 22),
      localDateTime: Value(DateTime.utc(2026, 11, 1, 1)),
      width: 500,
      height: 1000,
    );
    await ctx.newRemoteAsset(
      id: 'earlier-local-day',
      ownerId: 'owner',
      createdAt: DateTime.utc(2026, 10, 31, 23),
      localDateTime: Value(DateTime.utc(2026, 10, 31, 23)),
      width: 2000,
      height: 1000,
    );
    final query = repository.main(['owner'], 'owner', GroupAssetsBy.day);
    await assertPagedGeometry(query, pageSize: 1);
    expect((await query.assetSource(0, 20)).map((asset) => asset.id), ['later-local-day', 'earlier-local-day']);
  });

  test('zero, negative or absent dimensions use square geometry without removing photographs', () async {
    await remote('valid', ratio: 1.5);
    await remote('zero', ratio: 0);
    await remote('negative', ratio: -1);
    await remote('missing', ratio: 1);
    await (ctx.db.remoteAssetEntity.update()..where((row) => row.id.equals('missing'))).write(
      const RemoteAssetEntityCompanion(width: Value(null), height: Value(null)),
    );
    final query = repository.main(['owner'], 'owner', GroupAssetsBy.day);
    await assertPagedGeometry(query);
    final assets = await query.assetSource(0, 20);
    final geometry = (await query.bucketSource().first).single.aspectRatios!;
    expect(geometry.where((ratio) => ratio == 1), hasLength(3));
    expect(assets, hasLength(4));
    expect(geometry.every((ratio) => ratio.isFinite && ratio > 0), isTrue);
  });

  test('metadata obeys the same owner, Trash, visibility, stack-primary and backup fences as assets', () async {
    await remote('visible', ratio: 1.5);
    await ctx.newRemoteAsset(id: 'foreign', ownerId: 'other', createdAt: day, width: 900, height: 1000);
    await ctx.newRemoteAsset(id: 'trash', ownerId: 'owner', createdAt: day, deletedAt: day, width: 700, height: 1000);
    await ctx.newRemoteAsset(
      id: 'hidden',
      ownerId: 'owner',
      visibility: AssetVisibility.hidden,
      createdAt: day,
      width: 800,
      height: 1000,
    );
    await ctx.db
        .into(ctx.db.stackEntity)
        .insert(StackEntityCompanion.insert(id: 'stack', ownerId: 'owner', primaryAssetId: 'primary'));
    await ctx.newRemoteAsset(
      id: 'primary',
      ownerId: 'owner',
      stackId: 'stack',
      createdAt: day,
      width: 500,
      height: 1000,
    );
    await ctx.newRemoteAsset(
      id: 'child',
      ownerId: 'owner',
      stackId: 'stack',
      createdAt: day,
      width: 3000,
      height: 1000,
    );
    await ctx.newLocalAsset(id: 'not-backed-up', createdAt: day, width: 4000, height: 1000);
    final query = repository.main(['owner'], 'owner', GroupAssetsBy.day);
    await assertPagedGeometry(query);
    expect((await query.assetSource(0, 20)).map((asset) => asset.id).toSet(), {'visible', 'primary'});
    expect((await query.bucketSource().first).single.aspectRatios, unorderedEquals([1.5, .5]));
  });

  test('dimension-only updates refresh bucket geometry while preserving date, count and asset identity', () async {
    await remote('photo', ratio: .5);
    final query = repository.main(['owner'], 'owner', GroupAssetsBy.day);
    final updates = StreamIterator(query.bucketSource());
    addTearDown(updates.cancel);
    expect(await updates.moveNext().timeout(const Duration(seconds: 2)), isTrue);
    final initial = updates.current.single as TimeBucket;
    expect(initial.aspectRatios, [.5]);
    final next = updates.moveNext();
    await (ctx.db.remoteAssetEntity.update()..where((row) => row.id.equals('photo'))).write(
      const RemoteAssetEntityCompanion(width: Value(2000)),
    );
    expect(await next.timeout(const Duration(seconds: 2)), isTrue);
    final changed = updates.current.single as TimeBucket;
    expect(changed.date, initial.date);
    expect(changed.assetCount, 1);
    expect(changed.aspectRatios, [2]);
    expect((await query.assetSource(0, 1)).single.id, 'photo');
  });

  test('temporal month scope uses ordered metadata for exactly its paged catalogue', () async {
    await remote('november', ratio: .5, date: DateTime.utc(2026, 11, 1, 12));
    await remote('october-a', ratio: 1.5, date: DateTime.utc(2026, 10, 31, 12));
    await local('october-b', ratio: .75, date: DateTime.utc(2026, 10, 20, 12));
    final query = repository.main(
      ['owner'],
      'owner',
      GroupAssetsBy.day,
      temporalScope: TimelineTemporalScope.month(year: 2026, month: 10),
    );
    await assertPagedGeometry(query, pageSize: 1);
    expect((await query.assetSource(0, 20)).map((asset) => asset.id), ['october-a', 'october-b']);
    expect((await query.bucketSource().first).expand((bucket) => bucket.aspectRatios!), [1.5, .75]);
  });

  test('in-memory sources expose matching aspect geometry and preserve their intended ordering', () async {
    await remote('later', ratio: .5, date: day);
    await remote('earlier', ratio: 2, date: day.subtract(const Duration(days: 1)));
    final original = await repository.main(['owner'], 'owner', GroupAssetsBy.day).assetSource(0, 20);
    final reversed = original.reversed.toList();
    final dateless = repository.fromAssets(reversed, TimelineOrigin.search);
    await assertPagedGeometry(dateless, pageSize: 1);
    expect((await dateless.assetSource(0, 20)).map((asset) => asset.id), ['earlier', 'later']);
    final dated = repository.fromAssetsWithBuckets(reversed, TimelineOrigin.search);
    await assertPagedGeometry(dated, pageSize: 1);
    expect((await dated.assetSource(0, 20)).map((asset) => asset.id), ['later', 'earlier']);
    final streamed = repository.fromAssetStream(
      () => reversed,
      const Stream.empty(),
      TimelineOrigin.search,
      groupBy: GroupAssetsBy.day,
    );
    await assertPagedGeometry(streamed, pageSize: 1);
    expect((await streamed.assetSource(0, 20)).map((asset) => asset.id), ['later', 'earlier']);
    expect(await repository.fromAssets([], TimelineOrigin.search).bucketSource().first, isEmpty);
  });

  test('a large catalogue retains page slicing and one scalar ratio per displayed asset', () async {
    await ctx.db.batch((batch) {
      batch.insertAll(ctx.db.remoteAssetEntity, [
        for (var i = 0; i < 600; i++)
          RemoteAssetEntityCompanion.insert(
            id: 'asset-${i.toString().padLeft(4, '0')}',
            name: 'synthetic-$i.jpg',
            ownerId: 'owner',
            checksum: 'checksum-$i',
            type: AssetType.image,
            visibility: AssetVisibility.timeline,
            createdAt: Value(day.subtract(Duration(minutes: i))),
            localDateTime: Value(day.subtract(Duration(minutes: i))),
            updatedAt: Value(day),
            width: Value(500 + (i % 5) * 500),
            height: const Value(1000),
          ),
      ]);
    });
    final query = repository.main(['owner'], 'owner', GroupAssetsBy.day);
    await assertPagedGeometry(query, pageSize: 37);
    final page = await query.assetSource(370, 37);
    expect(page, hasLength(37));
    expect(page.first.id, 'asset-0370');
    expect(page.last.id, 'asset-0406');
  });
}
