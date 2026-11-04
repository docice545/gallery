import 'package:async/async.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/infrastructure/repositories/local_album.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline.repository.dart';

import '../../test_utils/medium_factory.dart';

void main() {
  late Drift db;
  late MediumFactory mediumFactory;

  setUp(() {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    mediumFactory = MediumFactory(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('confirmed removal resolves exact albums before cascade removes links', () async {
    final albums = LocalAlbumRepository(db);
    final assets = LocalAssetRepository(db);
    final removed = _localAsset('removed');
    final retained = _localAsset('retained');
    await albums.upsert(mediumFactory.localAlbum(id: 'camera'), toUpsert: [removed]);
    await albums.upsert(mediumFactory.localAlbum(id: 'favorites'), toUpsert: [removed, retained]);
    await albums.upsert(mediumFactory.localAlbum(id: 'unrelated'), toUpsert: [_localAsset('other')]);
    expect(await assets.getAlbumIdsForAssets(['removed']), {'camera', 'favorites'});
    expect(await assets.getAlbumIdsForAssets([]), isEmpty);
    await assets.deleteAssets(['removed']);
    expect(await albums.getAssets('camera'), isEmpty);
    expect((await albums.getAssets('favorites')).map((asset) => asset.id), ['retained']);
    expect((await albums.getAssets('unrelated')).map((asset) => asset.id), ['other']);
  });

  test('an open main Timeline observes new media deltas, deduplicates and keeps chronological order', () async {
    final albums = LocalAlbumRepository(db);
    final old = _localAsset('old');
    final screenshot = _localAsset('screenshot').copyWith(createdAt: DateTime(2026, 11, 4));
    final camera = _localAsset('camera').copyWith(createdAt: DateTime(2026, 11, 3));
    await albums.upsert(
      mediumFactory.localAlbum(id: 'screenshots', backupSelection: BackupSelection.selected),
      toUpsert: [old],
    );
    await albums.upsert(mediumFactory.localAlbum(id: 'camera', backupSelection: BackupSelection.selected));
    final query = TimelineRepository(db).main(['owner'], 'owner', GroupAssetsBy.day);
    final buckets = StreamQueue(query.bucketSource());
    expect((await buckets.next).fold<int>(0, (n, b) => n + b.assetCount), 1);
    await albums.processDelta(
      updates: [screenshot, camera],
      deletes: [],
      assetAlbums: {
        screenshot.id: ['screenshots'],
        camera.id: ['camera'],
      },
    );
    expect((await buckets.next).fold<int>(0, (n, b) => n + b.assetCount), 3);
    expect((await query.assetSource(0, 20)).map((a) => a.id), ['screenshot', 'camera', 'old']);
    // Replayed notifications must upsert, never append duplicate asset IDs.
    await albums.processDelta(
      updates: [screenshot, camera],
      deletes: [],
      assetAlbums: {
        screenshot.id: ['screenshots'],
        camera.id: ['camera'],
      },
    );
    expect((await query.assetSource(0, 20)).map((a) => a.id), ['screenshot', 'camera', 'old']);
    // Metadata and folder moves keep identity; chronological order follows the new date.
    await albums.processDelta(
      updates: [camera.copyWith(createdAt: DateTime(2026, 11, 5))],
      deletes: [],
      assetAlbums: {
        camera.id: ['screenshots'],
      },
    );
    expect((await query.assetSource(0, 20)).map((a) => a.id), ['camera', 'screenshot', 'old']);
    expect(await albums.getAssetIds('camera'), isEmpty);
    await albums.processDelta(updates: [], deletes: ['screenshot'], assetAlbums: {});
    expect((await query.assetSource(0, 20)).map((a) => a.id), ['camera', 'old']);
    await buckets.cancel();
  });

  group('getAll', () {
    test('sorts albums by backupSelection & isIosSharedAlbum', () async {
      final localAlbumRepo = mediumFactory.getRepository<LocalAlbumRepository>();
      await localAlbumRepo.upsert(mediumFactory.localAlbum(id: '1', backupSelection: BackupSelection.none));
      await localAlbumRepo.upsert(mediumFactory.localAlbum(id: '2', backupSelection: BackupSelection.excluded));
      await localAlbumRepo.upsert(
        mediumFactory.localAlbum(id: '3', backupSelection: BackupSelection.selected, isIosSharedAlbum: true),
      );
      await localAlbumRepo.upsert(mediumFactory.localAlbum(id: '4', backupSelection: BackupSelection.selected));
      final albums = await localAlbumRepo.getAll(
        sortBy: {SortLocalAlbumsBy.backupSelection, SortLocalAlbumsBy.isIosSharedAlbum},
      );
      expect(albums.length, 4);
      expect(albums[0].id, '4'); // selected
      expect(albums[1].id, '3'); // selected & isIosSharedAlbum
      expect(albums[2].id, '1'); // none
      expect(albums[3].id, '2'); // excluded
    });
  });

  group('processDelta', () {
    // Regression for #22844: an asset moved (not copied) into a backup album on
    // Android was dropped. The delta reports only the asset's new album, and the
    // stale link to its old album made the per-album delete sweep wipe the asset.
    test('keeps an asset moved to another album that still holds other assets', () async {
      final localAlbumRepo = mediumFactory.getRepository<LocalAlbumRepository>();

      final moved = _localAsset('moved');
      final other = _localAsset('other');
      await localAlbumRepo.upsert(
        mediumFactory.localAlbum(id: 'src', backupSelection: BackupSelection.none),
        toUpsert: [moved, other],
      );
      final anchor = _localAsset('anchor');
      await localAlbumRepo.upsert(
        mediumFactory.localAlbum(id: 'dst', backupSelection: BackupSelection.selected),
        toUpsert: [anchor],
      );

      // Delta reports the moved asset now living only in the destination album.
      await localAlbumRepo.processDelta(
        updates: [moved],
        deletes: [],
        assetAlbums: {
          'moved': ['dst'],
        },
      );

      // Per-album delete sweep, as sync() runs on Android. src now physically
      // holds only `other`; dst holds `anchor` and the moved asset.
      await localAlbumRepo.syncDeletes('src', ['other']);
      await localAlbumRepo.syncDeletes('dst', ['anchor', 'moved']);

      final dstIds = (await localAlbumRepo.getAssets('dst')).map((a) => a.id).toSet();
      final srcIds = await localAlbumRepo.getAssetIds('src');

      expect(dstIds, contains('moved')); // survived and linked to the backed-up album
      expect(srcIds, isNot(contains('moved'))); // stale source link cleared
      expect(srcIds, contains('other')); // untouched asset stays put
    });

    test('replaces album membership with exactly what the delta reports', () async {
      final localAlbumRepo = mediumFactory.getRepository<LocalAlbumRepository>();

      final moved = _localAsset('moved');
      await localAlbumRepo.upsert(mediumFactory.localAlbum(id: 'src'), toUpsert: [moved]);
      await localAlbumRepo.upsert(mediumFactory.localAlbum(id: 'dst'));

      await localAlbumRepo.processDelta(
        updates: [moved],
        deletes: [],
        assetAlbums: {
          'moved': ['dst'],
        },
      );

      expect(await localAlbumRepo.getAssetIds('src'), isEmpty);
      expect(await localAlbumRepo.getAssetIds('dst'), ['moved']);
    });
  });
}

LocalAsset _localAsset(String id) => LocalAsset(
  id: id,
  name: '$id.jpg',
  type: AssetType.image,
  createdAt: DateTime(2024),
  updatedAt: DateTime(2024),
  playbackStyle: AssetPlaybackStyle.image,
  isEdited: false,
);
