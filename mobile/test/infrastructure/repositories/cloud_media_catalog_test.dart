import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/table/remote/asset.drift.dart';
import 'package:immich_mobile/data/db/main/table/remote/exif.drift.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';

import '../../medium/repository_context.dart';

/// Execute the actual native provider SQL against the current Drift schema.
/// These are query/privacy tests, not mock evidence of an OEM picker install.
void main() {
  late MediumRepositoryContext ctx;
  late String projection;
  setUpAll(() async => projection = await File('android/app/src/main/res/raw/gallery_cloud_media.sql').readAsString());
  setUp(() async {
    ctx = MediumRepositoryContext();
    for (final id in ['viewer', 'partner', 'other']) {
      await ctx.newUser(id: id);
    }
  });
  tearDown(() => ctx.dispose());

  Future<void> media(
    String id, {
    String owner = 'viewer',
    AssetVisibility visibility = AssetVisibility.timeline,
    DateTime? deletedAt,
    String? pair,
    String? stack,
    String? library,
    String? checksum,
    AssetType type = AssetType.image,
    int? size = 200000,
  }) async {
    await ctx.newRemoteAsset(
      id: id,
      ownerId: owner,
      visibility: visibility,
      deletedAt: deletedAt,
      livePhotoVideoId: pair,
      stackId: stack,
      libraryId: library,
      checksum: checksum,
      type: type,
      createdAt: DateTime.utc(2026, 10, 7, 12),
      width: 4000,
      height: 3000,
      durationMs: type == AssetType.video ? 54321 : 0,
    );
    await ctx.db
        .into(ctx.db.remoteExifEntity)
        .insert(RemoteExifEntityCompanion.insert(assetId: id, fileSize: Value(size), orientation: const Value('6')));
  }

  Future<List<QueryRow>> rows({String owner = 'viewer', int limit = 200, int offset = 0}) => ctx.db
      .customSelect(
        'WITH eligible AS ($projection) SELECT * FROM eligible ORDER BY date_taken_millis DESC, asset_id LIMIT ? OFFSET ?',
        variables: [Variable(owner), Variable(limit), Variable(offset)],
      )
      .get();
  Future<List<String>> ids({String owner = 'viewer'}) async =>
      (await rows(owner: owner)).map((r) => r.read<String>('asset_id')).toList();

  test('only current owner and explicit timeline partner are returned', () async {
    await media('own');
    await media('partner', owner: 'partner');
    await media('stranger', owner: 'other');
    expect(await ids(), ['own']);
    await ctx.newPartner(sharedById: 'partner', sharedWithId: 'viewer', inTimeline: true);
    expect(await ids(), ['own', 'partner']);
    expect(await ids(owner: 'other'), ['stranger']);
  });
  test('Trash, archive, Locked and hidden cannot appear in the picker', () async {
    await media('ok');
    await media('trash', deletedAt: DateTime.utc(2026, 10, 7));
    await media('hidden', visibility: AssetVisibility.hidden);
    await media('archive', visibility: AssetVisibility.archive);
    await media('locked', visibility: AssetVisibility.locked);
    expect(await ids(), ['ok']);
  });
  test('restore and permanent deletion change catalog without recreating assets', () async {
    await media('item', deletedAt: DateTime.utc(2026, 10, 7));
    expect(await ids(), isEmpty);
    await (ctx.db.update(
      ctx.db.remoteAssetEntity,
    )..where((a) => a.id.equals('item'))).write(const RemoteAssetEntityCompanion(deletedAt: Value(null)));
    expect(await ids(), ['item']);
    await (ctx.db.delete(ctx.db.remoteAssetEntity)..where((a) => a.id.equals('item'))).go();
    expect(await ids(), isEmpty);
  });
  test('Live/Motion still is one item and a mis-visible companion remains excluded', () async {
    await media('still', pair: 'motion');
    await media('motion', type: AssetType.video);
    expect(await ids(), ['still']);
    expect((await rows()).single.read<String>('live_photo_video_id'), 'motion');
  });
  test('a hidden/trashed still does not leak its motion companion', () async {
    await media('still', pair: 'motion', deletedAt: DateTime.utc(2026, 10, 7));
    await media('motion', type: AssetType.video);
    expect(await ids(), isEmpty);
  });
  test('unknown original size is omitted, never replaced by thumbnail size', () async {
    await media('unknown', size: null);
    await media('zero', size: 0);
    await media('known');
    expect(await ids(), ['known']);
  });
  test('UTC capture date, actual dimensions, video duration and original size survive projection', () async {
    await media('video', type: AssetType.video, size: 5000000000);
    final row = (await rows()).single;
    expect(row.read<int>('date_taken_millis'), DateTime.utc(2026, 10, 7, 12).millisecondsSinceEpoch);
    expect(row.read<int>('duration_ms'), 54321);
    expect(row.read<int>('width'), 4000);
    expect(row.read<int>('height'), 3000);
    expect(row.read<int>('file_size'), 5000000000);
  });
  test('only an owned asset with verified matching checksum gets a MediaStore local ID', () async {
    await ctx.newLocalAsset(id: '123', checksum: 'same');
    await ctx.newLocalAsset(id: '124', checksum: 'unrelated');
    await media('own', checksum: 'same');
    await media('other', owner: 'partner', checksum: 'same');
    await ctx.newPartner(sharedById: 'partner', sharedWithId: 'viewer', inTimeline: true);
    final result = await rows();
    expect(result.singleWhere((r) => r.read<String>('asset_id') == 'own').readNullable<String>('local_id'), '123');
    expect(result.singleWhere((r) => r.read<String>('asset_id') == 'other').readNullable<String>('local_id'), isNull);
  });
  test('manual stacks retain primary tile without changing stack membership', () async {
    await ctx.insertStack(id: 'stack', ownerId: 'viewer', primaryAssetId: 'primary');
    await media('primary', stack: 'stack');
    await media('secondary', stack: 'stack');
    expect(await ids(), ['primary']);
    expect(await ctx.db.select(ctx.db.remoteAssetEntity).get(), hasLength(2));
    expect(await ctx.db.select(ctx.db.stackEntity).get(), hasLength(1));
  });
  test('space grants require this viewer and timeline-enabled membership', () async {
    await media('shared', owner: 'other');
    await ctx.newSharedSpace(id: 'space', createdById: 'other');
    await ctx.newSharedSpaceMember(spaceId: 'space', userId: 'partner');
    await ctx.insertSharedSpaceAsset(spaceId: 'space', assetId: 'shared');
    expect(await ids(), isEmpty);
    await ctx.newSharedSpaceMember(spaceId: 'space', userId: 'viewer', showInTimeline: true);
    expect(await ids(), ['shared']);
  });
  test('owner-hidden-space subtraction is preserved', () async {
    await media('own');
    await ctx.newSharedSpace(id: 'space', createdById: 'viewer');
    await ctx.newSharedSpaceMember(spaceId: 'space', userId: 'viewer', showInTimeline: false);
    await ctx.insertSharedSpaceAsset(spaceId: 'space', assetId: 'own');
    expect(await ids(), isEmpty);
  });
  test('30001 items paginate in bounded SQL pages without loading the full library', () async {
    await media('template');
    final columns = (await ctx.db.customSelect('PRAGMA table_info(remote_asset_entity)').get())
        .map((r) => r.read<String>('name'))
        .where((c) => c != 'id')
        .join(',');
    await ctx.db.customStatement('''
      WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n<30000)
      INSERT INTO remote_asset_entity(id,$columns)
      SELECT printf('bulk-%05d',n),${columns.split(',').map((c) => c == 'checksum' ? "printf('checksum-%05d',n)" : c).join(',')}
      FROM remote_asset_entity CROSS JOIN seq WHERE id='template'
    ''');
    await ctx.db.customStatement(
      'INSERT INTO remote_exif_entity(asset_id,file_size) SELECT id,200000 FROM remote_asset_entity WHERE id!=\'template\'',
    );
    final pages = [await rows(offset: 0), await rows(offset: 15000), await rows(offset: 30000)];
    expect(pages.map((p) => p.length), [200, 200, 1]);
    expect(pages.expand((p) => p).map((r) => r.read<String>('asset_id')).toSet(), hasLength(401));
  });
}
