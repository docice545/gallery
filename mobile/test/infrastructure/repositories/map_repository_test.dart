// Visibility regression tests for MapRepository.remote().
//
// The bug we're guarding against: marker queries scoped only by `ownerId IN
// userIds` hide assets that the viewer can legitimately see via shared spaces
// where `showInTimeline=true`. These tests pin the new contract — markers
// follow the same visibility rules as the timeline buckets.

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/remote/asset.drift.dart';
import 'package:immich_mobile/data/db/main/table/remote/exif.drift.dart';
import 'package:immich_mobile/data/db/main/table/remote/shared_space.drift.dart';
import 'package:immich_mobile/data/db/main/table/remote/shared_space_asset.drift.dart';
import 'package:immich_mobile/data/db/main/table/remote/shared_space_member.drift.dart';
import 'package:immich_mobile/data/db/main/table/user/user.drift.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/map.model.dart';
import 'package:immich_mobile/infrastructure/repositories/map.repository.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '_shared_permission_matrix.dart';

void main() {
  late Drift db;
  late MapRepository sut;

  setUpAll(() async {
    await initializeDateFormatting('en_US');
  });

  setUp(() {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    sut = MapRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  // Shared fixture helpers — duplicated from timeline_repository_test.dart
  // because each test file is independent (no cross-file imports of test
  // helpers).
  Future<void> insertUser(String id) =>
      db.into(db.userEntity).insert(UserEntityCompanion.insert(id: id, email: '$id@test', name: id));

  Future<void> insertImage(String id, String ownerId) {
    final createdAt = DateTime(2024, 1, 1, 12);
    return db
        .into(db.remoteAssetEntity)
        .insert(
          RemoteAssetEntityCompanion.insert(
            id: id,
            name: '$id.jpg',
            type: AssetType.image,
            checksum: 'c-$id',
            ownerId: ownerId,
            visibility: AssetVisibility.timeline,
            createdAt: Value(createdAt),
            updatedAt: Value(createdAt),
            localDateTime: Value(createdAt),
          ),
        );
  }

  Future<void> insertExifAt(String assetId, double lat, double lng) => db
      .into(db.remoteExifEntity)
      .insert(RemoteExifEntityCompanion.insert(assetId: assetId, latitude: Value(lat), longitude: Value(lng)));

  Future<void> insertSpace(String id, String ownerId) =>
      db.into(db.sharedSpaceEntity).insert(SharedSpaceEntityCompanion.insert(id: id, name: id, createdById: ownerId));

  Future<void> insertMember(String spaceId, String userId, {bool showInTimeline = true}) => db
      .into(db.sharedSpaceMemberEntity)
      .insert(
        SharedSpaceMemberEntityCompanion.insert(
          spaceId: spaceId,
          userId: userId,
          role: 'viewer',
          showInTimeline: Value(showInTimeline),
        ),
      );

  Future<void> linkAssetToSpace(String spaceId, String assetId) => db
      .into(db.sharedSpaceAssetEntity)
      .insert(SharedSpaceAssetEntityCompanion.insert(spaceId: spaceId, assetId: assetId));

  LatLngBounds globeBounds() => LatLngBounds(southwest: const LatLng(-89, -179), northeast: const LatLng(89, 179));

  group('MapRepository.remote()', () {
    test('owner marker returned', () async {
      await insertUser('viewer');
      await insertImage('a1', 'viewer');
      await insertExifAt('a1', 48.85, 2.35);

      final markers = await sut
          .remote(['viewer'], 'viewer', TimelineMapOptions(bounds: globeBounds()))
          .markerSource(globeBounds());
      expect(markers, hasLength(1));
    });

    test('photos without GPS are excluded without modifying EXIF or coordinates', () async {
      await insertUser('viewer');
      await insertImage('no-exif', 'viewer');
      await insertImage('no-gps', 'viewer');
      await insertImage('latitude-only', 'viewer');
      await insertImage('zero', 'viewer');
      await insertImage('invalid-lat', 'viewer');
      await insertImage('invalid-lng', 'viewer');
      await db.into(db.remoteExifEntity).insert(RemoteExifEntityCompanion.insert(assetId: 'no-gps'));
      await db
          .into(db.remoteExifEntity)
          .insert(RemoteExifEntityCompanion.insert(assetId: 'latitude-only', latitude: const Value(55.75)));
      await insertExifAt('zero', 0, 0);
      await insertExifAt('invalid-lat', 91, 37);
      await insertExifAt('invalid-lng', 55, 181);

      final source = sut.remote(['viewer'], 'viewer', TimelineMapOptions(bounds: globeBounds())).markerSource;
      for (final bounds in [null, globeBounds()]) {
        final markers = await source(bounds);
        expect(markers.map((marker) => marker.assetId), ['zero']);
        expect(markers.single.location, const LatLng(0, 0));
      }
      final exif = await db.remoteExifEntity.select().get();
      expect(exif.singleWhere((row) => row.assetId == 'latitude-only').latitude, 55.75);
      expect(exif.singleWhere((row) => row.assetId == 'latitude-only').longitude, isNull);
      expect(exif.singleWhere((row) => row.assetId == 'invalid-lat').latitude, 91);
      expect(exif.singleWhere((row) => row.assetId == 'invalid-lng').longitude, 181);
    });

    test('space-visible marker returned', () async {
      await insertUser('viewer');
      await insertUser('owner');
      await insertImage('a1', 'owner');
      await insertExifAt('a1', 48.85, 2.35);
      await insertSpace('space1', 'owner');
      await insertMember('space1', 'viewer');
      await linkAssetToSpace('space1', 'a1');

      final markers = await sut
          .remote(['viewer'], 'viewer', TimelineMapOptions(bounds: globeBounds()))
          .markerSource(globeBounds());
      expect(markers, hasLength(1));
    });
  });

  group('MapRepository.getInitialViewport()', () {
    test('fits eligible library rather than newest point and handles the date line', () async {
      await insertUser('viewer');
      await insertImage('west', 'viewer');
      await insertExifAt('west', 10, 179);
      await insertImage('east', 'viewer');
      await insertExifAt('east', 20, -179);
      final viewport = await sut.getInitialViewport(['viewer'], 'viewer', TimelineMapOptions(bounds: globeBounds()));
      expect(viewport!.photoCount, 2);
      expect(viewport.bounds.southwest, const LatLng(10, 179));
      expect(viewport.bounds.northeast, const LatLng(20, -179));
    });

    test('same favorites/archive/deleted/GPS policy as markers; no EXIF writes', () async {
      await insertUser('viewer');
      for (final id in ['favorite', 'ordinary', 'archived', 'deleted', 'invalid', 'noGPS']) {
        await insertImage(id, 'viewer');
        if (id != 'noGPS') {
          await insertExifAt(id, id == 'invalid' ? 91 : 55, 37);
        }
      }
      await (db.update(db.remoteAssetEntity)..where((row) => row.id.isIn(['favorite', 'archived']))).write(
        const RemoteAssetEntityCompanion(isFavorite: Value(true)),
      );
      await (db.update(db.remoteAssetEntity)..where((row) => row.id.equals('archived'))).write(
        const RemoteAssetEntityCompanion(visibility: Value(AssetVisibility.archive)),
      );
      await (db.update(
        db.remoteAssetEntity,
      )..where((row) => row.id.equals('deleted'))).write(RemoteAssetEntityCompanion(deletedAt: Value(DateTime(2025))));
      for (final options in [
        TimelineMapOptions(bounds: globeBounds()),
        TimelineMapOptions(bounds: globeBounds(), onlyFavorites: true),
        TimelineMapOptions(bounds: globeBounds(), onlyFavorites: true, includeArchived: true),
      ]) {
        final markers = await sut.remote(['viewer'], 'viewer', options).markerSource(null);
        final viewport = await sut.getInitialViewport(['viewer'], 'viewer', options);
        expect(viewport!.photoCount, markers.length);
      }
      expect((await db.remoteExifEntity.select().get()).singleWhere((row) => row.assetId == 'invalid').latitude, 91);
    });

    test('empty/no GPS library has no invented point; zero is valid', () async {
      await insertUser('viewer');
      final options = TimelineMapOptions(bounds: globeBounds());
      expect(await sut.getInitialViewport(['viewer'], 'viewer', options), isNull);
      await insertImage('zero', 'viewer');
      expect(await sut.getInitialViewport(['viewer'], 'viewer', options), isNull);
      await insertExifAt('zero', 0, 0);
      expect((await sut.getInitialViewport(['viewer'], 'viewer', options))!.bounds.southwest, const LatLng(0, 0));
    });

    test('aggregate includes photos beyond the existing 10000 marker cap', () async {
      await insertUser('viewer');
      await db.batch((batch) {
        batch.insertAll(
          db.remoteAssetEntity,
          List.generate(
            10001,
            (index) => RemoteAssetEntityCompanion.insert(
              id: 'asset-$index',
              name: '$index.jpg',
              type: AssetType.image,
              checksum: '$index',
              ownerId: 'viewer',
              visibility: AssetVisibility.timeline,
            ),
          ),
        );
        batch.insertAll(
          db.remoteExifEntity,
          List.generate(
            10001,
            (index) => RemoteExifEntityCompanion.insert(
              assetId: 'asset-$index',
              latitude: Value(index == 10000 ? -33.8 : 55.7),
              longitude: Value(index == 10000 ? 151.2 : 37.6),
            ),
          ),
        );
      });
      final options = TimelineMapOptions(bounds: globeBounds());
      final viewport = await sut.getInitialViewport(['viewer'], 'viewer', options);
      expect(viewport!.photoCount, 10001);
      expect(viewport.bounds.southwest.latitude, -33.8);
      expect(viewport.bounds.northeast.latitude, 55.7);
      expect(await sut.remote(['viewer'], 'viewer', options).markerSource(null), hasLength(10000));
    });
  });

  group('Cross-method permission matrix — initial viewport', () {
    runPermissionMatrix(
      methodName: 'initial viewport',
      fixtures: MatrixFixtures(
        db: () => db,
        insertAsset: (assetId, ownerId) async {
          await insertImage(assetId, ownerId);
          await insertExifAt(assetId, 48.85, 2.35);
        },
      ),
      count: (userIds, currentUserId) async =>
          (await sut.getInitialViewport(
            userIds,
            currentUserId,
            TimelineMapOptions(bounds: globeBounds()),
          ))?.photoCount ??
          0,
    );
  });

  group('Cross-method permission matrix — MapRepository.remote() markers', () {
    final bounds = LatLngBounds(southwest: const LatLng(-89, -179), northeast: const LatLng(89, 179));
    runPermissionMatrix(
      methodName: 'marker',
      fixtures: MatrixFixtures(
        db: () => db,
        insertAsset: (assetId, ownerId) async {
          await insertImage(assetId, ownerId);
          await insertExifAt(assetId, 48.85, 2.35);
        },
      ),
      count: (userIds, currentUserId) async {
        final markers = await sut
            .remote(userIds, currentUserId, TimelineMapOptions(bounds: bounds))
            .markerSource(bounds);
        return markers.length;
      },
    );
  });
}
