import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/table/remote/asset.drift.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline.repository.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../../medium/repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;
  late TimelineRepository sut;
  late String owner;

  setUpAll(() => initializeDateFormatting('en'));
  setUp(() async {
    ctx = MediumRepositoryContext();
    sut = TimelineRepository(ctx.db);
    owner = (await ctx.newUser()).id;
  });
  tearDown(() => ctx.dispose());

  Future<void> asset(
    String id, {
    required DateTime taken,
    DateTime? uploaded,
    AssetVisibility visibility = AssetVisibility.timeline,
    String? ownerId,
    String? stackId,
    DateTime? deletedAt,
    Value<DateTime?> localDateTime = const Value.absent(),
  }) async {
    await ctx.newRemoteAsset(
      id: id,
      ownerId: ownerId ?? owner,
      createdAt: taken,
      visibility: visibility,
      stackId: stackId,
      deletedAt: deletedAt,
      localDateTime: localDateTime,
    );
    await (ctx.db.update(
      ctx.db.remoteAssetEntity,
    )..where((row) => row.id.equals(id))).write(RemoteAssetEntityCompanion(uploadedAt: Value(uploaded)));
  }

  Future<List<String>> ids({int offset = 0, int count = 20}) async =>
      (await sut.recentlyAdded(owner, GroupAssetsBy.day).assetSource(offset, count)).map((asset) => asset.id).toList();

  test('uses capture chronology including archived photos instead of reverse upload chronology', () async {
    await asset('old', taken: DateTime.utc(2026, 10, 1), uploaded: DateTime.utc(2026, 11, 7));
    await asset('new', taken: DateTime.utc(2026, 11, 3), uploaded: DateTime.utc(2026, 11, 5));
    await asset(
      'archived',
      taken: DateTime.utc(2026, 11, 2),
      uploaded: DateTime.utc(2026, 11, 6),
      visibility: AssetVisibility.archive,
    );

    expect(await ids(), ['new', 'archived', 'old']);
    expect(await sut.recentlyAdded(owner, GroupAssetsBy.day).bucketSource().first, [
      TimeBucket(date: DateTime(2026, 11, 3), assetCount: 1),
      TimeBucket(date: DateTime(2026, 11, 2), assetCount: 1),
      TimeBucket(date: DateTime(2026, 10, 1), assetCount: 1),
    ]);
  });

  test('equal capture times have stable ID order across pages and repeated queries', () async {
    final taken = DateTime.utc(2026, 11, 3, 10);
    await asset('b', taken: taken, uploaded: DateTime.utc(2026, 11, 7));
    await asset('c', taken: taken, uploaded: DateTime.utc(2026, 11, 6));
    await asset('a', taken: taken, uploaded: DateTime.utc(2026, 11, 5));

    expect(await ids(count: 2), ['a', 'b']);
    expect(await ids(offset: 2, count: 2), ['c']);
    expect(await ids(), ['a', 'b', 'c']);
    expect(await ids(), ['a', 'b', 'c']);
  });

  test('preserves owner, upload, visibility and trash boundaries and raw stack members', () async {
    final taken = DateTime.utc(2026, 11, 3);
    final uploaded = DateTime.utc(2026, 11, 5);
    await asset('cover', taken: taken, uploaded: uploaded, stackId: 'stack');
    await asset('child', taken: taken.subtract(const Duration(seconds: 1)), uploaded: uploaded, stackId: 'stack');
    await ctx.insertStack(id: 'stack', ownerId: owner, primaryAssetId: 'cover');
    await asset('not-uploaded', taken: taken);
    await asset('locked', taken: taken, uploaded: uploaded, visibility: AssetVisibility.locked);
    await asset('hidden-video', taken: taken, uploaded: uploaded, visibility: AssetVisibility.hidden);
    await asset('trashed', taken: taken, uploaded: uploaded, deletedAt: uploaded);
    final other = (await ctx.newUser()).id;
    await asset('other-owner', taken: taken, uploaded: uploaded, ownerId: other);

    expect(await ids(), ['cover', 'child']);
    expect(await sut.recentlyAdded(owner, GroupAssetsBy.none).bucketSource().first, [const Bucket(assetCount: 2)]);
  });

  test('capture timezone calendar survives a later upload timestamp update', () async {
    await asset(
      'offset-photo',
      taken: DateTime.utc(2026, 11, 3, 21, 10),
      uploaded: DateTime.utc(2026, 11, 5),
      localDateTime: Value(DateTime.utc(2026, 11, 4, 0, 10)),
    );
    final query = sut.recentlyAdded(owner, GroupAssetsBy.day);

    expect(await query.bucketSource().first, [TimeBucket(date: DateTime(2026, 11, 4), assetCount: 1)]);
    await (ctx.db.update(ctx.db.remoteAssetEntity)..where((row) => row.id.equals('offset-photo'))).write(
      RemoteAssetEntityCompanion(uploadedAt: Value(DateTime.utc(2026, 11, 8))),
    );
    expect(await query.bucketSource().first, [TimeBucket(date: DateTime(2026, 11, 4), assetCount: 1)]);
    expect((await query.assetSource(0, 1)).single.createdAt, DateTime.utc(2026, 11, 3, 21, 10));
  });
}
