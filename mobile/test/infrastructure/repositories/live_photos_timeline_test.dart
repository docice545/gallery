import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/table/local/asset.drift.dart';
import 'package:immich_mobile/data/db/main/table/remote/asset.drift.dart';
import 'package:immich_mobile/data/db/main/table/remote/shared_space_album_hidden.drift.dart';
import 'package:immich_mobile/data/db/main/table/remote/shared_space_member.drift.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/models/timeline_temporal_scope.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline.repository.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../../medium/repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;
  late TimelineRepository sut;

  setUpAll(() async => initializeDateFormatting('en'));
  setUp(() async {
    ctx = MediumRepositoryContext();
    sut = TimelineRepository(ctx.db);
    await ctx.newUser(id: 'viewer');
    await ctx.newUser(id: 'partner');
    await ctx.newUser(id: 'other');
  });
  tearDown(() => ctx.dispose());

  Future<void> live(
    String id, {
    String ownerId = 'viewer',
    DateTime? createdAt,
    AssetVisibility visibility = AssetVisibility.timeline,
    String? checksum,
    String? libraryId,
    String? stackId,
    DateTime? deletedAt,
  }) async {
    await ctx.newRemoteAsset(
      id: id,
      ownerId: ownerId,
      livePhotoVideoId: '$id-motion',
      createdAt: createdAt ?? DateTime(2025, 2, 1, 12),
      visibility: visibility,
      checksum: checksum,
      libraryId: libraryId,
      stackId: stackId,
      deletedAt: deletedAt,
    );
  }

  Future<void> local(
    String id, {
    String? checksum,
    DateTime? createdAt,
    AssetPlaybackStyle playbackStyle = AssetPlaybackStyle.livePhoto,
    BackupSelection selection = BackupSelection.selected,
  }) async {
    await ctx.newLocalAsset(id: id, checksum: checksum, createdAt: createdAt ?? DateTime(2025, 2, 1, 12));
    await (ctx.db.update(
      ctx.db.localAssetEntity,
    )..where((row) => row.id.equals(id))).write(LocalAssetEntityCompanion(playbackStyle: Value(playbackStyle)));
    final album = await ctx.newLocalAlbum(backupSelection: selection);
    await ctx.newLocalAlbumAsset(albumId: album.id, assetId: id);
  }

  TimelineQuery query({
    List<String> userIds = const ['viewer'],
    GroupAssetsBy groupBy = GroupAssetsBy.day,
    TimelineTemporalScope scope = const TimelineTemporalScope.none(),
  }) => sut.livePhotos(userIds, 'viewer', groupBy, temporalScope: scope);

  Future<List<String>> ids(TimelineQuery source, {int offset = 0, int count = 100}) async =>
      (await source.assetSource(offset, count)).map((asset) => asset.id).toList();

  Future<int> count(TimelineQuery source) async =>
      (await source.bucketSource().first).fold<int>(0, (total, bucket) => total + bucket.assetCount);

  test('only paired still images are tiles; ordinary photos/videos and hidden motion are excluded', () async {
    await live('samsung');
    await live('apple');
    await ctx.newRemoteAsset(id: 'ordinary-photo', ownerId: 'viewer');
    await ctx.newRemoteAsset(id: 'ordinary-video', ownerId: 'viewer', type: AssetType.video);
    await ctx.newRemoteAsset(
      id: 'samsung-motion',
      ownerId: 'viewer',
      type: AssetType.video,
      visibility: AssetVisibility.hidden,
    );
    await ctx.newRemoteAsset(
      id: 'video-with-pair-field',
      ownerId: 'viewer',
      type: AssetType.video,
      livePhotoVideoId: 'x',
    );
    await live('hidden-still', visibility: AssetVisibility.hidden);
    await live('archived-still', visibility: AssetVisibility.archive);
    await live('locked-still', visibility: AssetVisibility.locked);
    await live('deleted-still', deletedAt: DateTime(2025, 3, 1));

    final source = query();
    final assets = await source.assetSource(0, 100);
    expect(source.origin, TimelineOrigin.livePhotos);
    expect(assets.map((asset) => asset.id), unorderedEquals(['samsung', 'apple']));
    expect(assets.every((asset) => asset.isImage && asset.isMotionPhoto), isTrue);
    expect(await count(source), 2);
  });

  test('local native Live Photos follow selected/excluded backup boundaries', () async {
    await local('selected');
    await local('ordinary', playbackStyle: AssetPlaybackStyle.image);
    await local('unselected', selection: BackupSelection.none);
    await local('excluded', selection: BackupSelection.excluded);
    await local('selected-but-excluded');
    final excludedAlbum = await ctx.newLocalAlbum(backupSelection: BackupSelection.excluded);
    await ctx.newLocalAlbumAsset(albumId: excludedAlbum.id, assetId: 'selected-but-excluded');

    expect(await ids(query()), ['selected']);
    expect(await count(query()), 1);
    expect((await query().assetSource(0, 1)).single, isA<LocalAsset>());
  });

  test('a synced local/remote Live Photo is one merged tile preserving pair identity', () async {
    await local('local-copy', checksum: 'same-photo');
    await live('remote-copy', checksum: 'same-photo');

    final assets = await query().assetSource(0, 100);
    expect(assets, hasLength(1));
    final merged = assets.single as RemoteAsset;
    expect(merged.localId, 'local-copy');
    expect(merged.livePhotoVideoId, 'remote-copy-motion');
    expect(merged.isMerged, isTrue);
    expect(await count(query()), 1);
  });

  test('owner and allowed partner are visible; unrelated owner is excluded', () async {
    await live('owner');
    await live('partner', ownerId: 'partner');
    await live('stranger', ownerId: 'other');

    expect(await ids(query(userIds: ['viewer', 'partner'])), unorderedEquals(['owner', 'partner']));
    expect(await ids(query()), ['owner']);
  });

  test('space membership and multiple direct/library paths count the still exactly once', () async {
    await live('shared', ownerId: 'other', libraryId: 'library');
    for (final spaceId in ['space-a', 'space-b']) {
      await ctx.newSharedSpace(id: spaceId, createdById: 'other');
      await ctx.newSharedSpaceMember(spaceId: spaceId, userId: 'viewer');
      await ctx.insertSharedSpaceAsset(spaceId: spaceId, assetId: 'shared');
    }
    await ctx.insertSharedSpaceLibrary(spaceId: 'space-a', libraryId: 'library');

    expect(await ids(query()), ['shared']);
    expect(await count(query()), 1);
  });

  test('hidden viewer membership and another member never grant access', () async {
    await live('hidden-membership', ownerId: 'other');
    await live('partner-membership', ownerId: 'other');
    await ctx.newSharedSpace(id: 'hidden-space', createdById: 'other');
    await ctx.newSharedSpaceMember(spaceId: 'hidden-space', userId: 'viewer', showInTimeline: false);
    await ctx.insertSharedSpaceAsset(spaceId: 'hidden-space', assetId: 'hidden-membership');
    await ctx.newSharedSpace(id: 'partner-space', createdById: 'other');
    await ctx.newSharedSpaceMember(spaceId: 'partner-space', userId: 'partner');
    await ctx.insertSharedSpaceAsset(spaceId: 'partner-space', assetId: 'partner-membership');

    expect(await ids(query(userIds: ['viewer', 'partner'])), isEmpty);
    expect(await count(query()), 0);
  });

  test('album personal hide preference applies while shared album setting is isolated', () async {
    await live('album-live', ownerId: 'other');
    await ctx.newSharedSpace(id: 'space', createdById: 'other');
    await ctx.newSharedSpaceMember(spaceId: 'space', userId: 'viewer');
    await ctx.insertSharedSpaceAlbumLink(spaceId: 'space', albumId: 'album', showInTimeline: false);
    await ctx.insertSharedSpaceAlbumAsset(albumId: 'album', assetId: 'album-live');
    expect(await ids(query()), ['album-live']);
    await ctx.db
        .into(ctx.db.sharedSpaceAlbumHiddenEntity)
        .insert(SharedSpaceAlbumHiddenEntityCompanion.insert(spaceId: 'space', albumId: 'album', userId: 'viewer'));

    expect(await ids(query()), isEmpty);
    expect(await count(query()), 0);
  });

  test('owned hidden space path remains hidden unless another visible path exists', () async {
    await live('owned');
    await ctx.newSharedSpace(id: 'hidden', createdById: 'viewer');
    await ctx.newSharedSpaceMember(spaceId: 'hidden', userId: 'viewer', showInTimeline: false);
    await ctx.insertSharedSpaceAsset(spaceId: 'hidden', assetId: 'owned');
    expect(await ids(query()), isEmpty);
    await ctx.newSharedSpace(id: 'shown', createdById: 'viewer');
    await ctx.newSharedSpaceMember(spaceId: 'shown', userId: 'viewer');
    await ctx.insertSharedSpaceAsset(spaceId: 'shown', assetId: 'owned');

    expect(await ids(query()), ['owned']);
    expect(await count(query()), 1);
  });

  test('stack remains primary-only and keeps existing stack and paired-resource IDs', () async {
    await ctx.insertStack(id: 'stack', ownerId: 'viewer', primaryAssetId: 'primary');
    await live('primary', stackId: 'stack');
    await live('member', stackId: 'stack');

    final assets = await query().assetSource(0, 100);
    expect(assets.map((asset) => asset.id), ['primary']);
    expect((assets.single as RemoteAsset).stackId, 'stack');
    expect((assets.single as RemoteAsset).livePhotoVideoId, 'primary-motion');
    expect(await count(query()), 1);
  });

  test('SQL pagination is applied after merging local and remote stills', () async {
    await live('newest', createdAt: DateTime(2025, 2, 3, 12));
    await local('middle', createdAt: DateTime(2025, 2, 2, 12));
    await live('oldest', createdAt: DateTime(2025, 2, 1, 12));

    final source = query();
    expect(await ids(source, count: 1), ['newest']);
    expect(await ids(source, offset: 1, count: 1), ['middle']);
    expect(await ids(source, offset: 2, count: 1), ['oldest']);
    expect(await ids(source, offset: 3, count: 1), isEmpty);
    expect(await count(source), 3);
  });

  test('year/month scope filters both source arms and their grouping buckets', () async {
    await live('feb-remote', createdAt: DateTime(2025, 2, 1, 12));
    await local('feb-local', createdAt: DateTime(2025, 2, 2, 12));
    await live('mar-remote', createdAt: DateTime(2025, 3, 1, 12));
    await local('previous-year', createdAt: DateTime(2024, 2, 1, 12));
    final feb = query(groupBy: GroupAssetsBy.month, scope: TimelineTemporalScope.month(year: 2025, month: 2));

    expect(await ids(feb), ['feb-local', 'feb-remote']);
    expect(await feb.bucketSource().first, [TimeBucket(date: DateTime(2025, 2), assetCount: 2)]);
    expect(await count(query(groupBy: GroupAssetsBy.year, scope: const TimelineTemporalScope.year(2025))), 3);
  });

  test('scope uses server localDateTime provenance when different from UTC capture date', () async {
    await ctx.newRemoteAsset(
      id: 'local-date',
      ownerId: 'viewer',
      livePhotoVideoId: 'motion',
      createdAt: DateTime.utc(2024, 12, 31, 23, 30),
      localDateTime: Value(DateTime.utc(2025, 1, 1, 1, 30)),
    );

    expect(await ids(query(scope: const TimelineTemporalScope.year(2025))), ['local-date']);
    expect(await ids(query(scope: const TimelineTemporalScope.year(2024))), isEmpty);
  });

  test('empty Live Photo collection has zero buckets and no assets', () async {
    expect(await query().bucketSource().first, isEmpty);
    expect(await ids(query()), isEmpty);
  });

  test('bucket watch reacts when pairing identity or viewer space membership changes', () async {
    await ctx.newRemoteAsset(id: 'becomes-live', ownerId: 'other');
    await ctx.newSharedSpace(id: 'space', createdById: 'other');
    await ctx.newSharedSpaceMember(spaceId: 'space', userId: 'viewer');
    await ctx.insertSharedSpaceAsset(spaceId: 'space', assetId: 'becomes-live');
    final counts = <int>[];
    final subscription = query().bucketSource().listen((buckets) {
      counts.add(buckets.fold<int>(0, (sum, bucket) => sum + bucket.assetCount));
    });
    addTearDown(subscription.cancel);
    Future<void> waitFor(int expected) async {
      await Future<void>(() async {
        while (counts.isEmpty || counts.last != expected) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }).timeout(const Duration(seconds: 2));
    }

    await waitFor(0);
    await (ctx.db.update(ctx.db.remoteAssetEntity)..where((row) => row.id.equals('becomes-live'))).write(
      const RemoteAssetEntityCompanion(livePhotoVideoId: Value('motion')),
    );
    await waitFor(1);
    await (ctx.db.update(ctx.db.sharedSpaceMemberEntity)..where((row) => row.spaceId.equals('space'))).write(
      const SharedSpaceMemberEntityCompanion(showInTimeline: Value(false)),
    );
    await waitFor(0);
    expect(counts, containsAllInOrder([0, 1, 0]));
    expect(await ids(query()), isEmpty);
  });
}
