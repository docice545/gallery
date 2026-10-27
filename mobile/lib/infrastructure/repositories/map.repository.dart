import 'package:drift/drift.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/remote/asset.drift.dart';
import 'package:immich_mobile/data/db/main/table/remote/exif.drift.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/map.model.dart';
import 'package:immich_mobile/domain/services/map.service.dart';
import 'package:immich_mobile/infrastructure/repositories/map.repository.drift.dart';
import 'package:immich_mobile/infrastructure/repositories/viewer_visibility.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

@DriftAccessor()
class MapRepository extends DatabaseAccessor<Drift> with $MapRepositoryMixin {
  MapRepository(super.attachedDatabase);

  Drift get _db => attachedDatabase;

  /// A deterministic library anchor, without requiring device-location access.
  /// Read the newest eligible photo rather than a demo city or an arbitrary
  /// unordered map-marker row. EXIF and asset membership remain unchanged.
  Future<LatLng?> getInitialLocation(String userId) async {
    final asset = _db.remoteAssetEntity;
    final exif = _db.remoteExifEntity;
    final query = exif.selectOnly()
      ..addColumns([exif.latitude, exif.longitude])
      ..join([innerJoin(asset, asset.id.equalsExp(exif.assetId), useColumns: false)])
      ..where(
        asset.ownerId.equals(userId) &
            asset.deletedAt.isNull() &
            asset.visibility.equals(AssetVisibility.timeline.index) &
            exif.latitude.isBetweenValues(-90, 90) &
            exif.longitude.isBetweenValues(-180, 180),
      )
      ..orderBy([OrderingTerm.desc(asset.createdAt), OrderingTerm.asc(asset.id)])
      ..limit(1);
    final row = await query.getSingleOrNull();
    return row == null ? null : LatLng(row.read(exif.latitude)!, row.read(exif.longitude)!);
  }

  Expression<bool> _eligibleAssets(List<String> userIds, String currentUserId, TimelineMapOptions options) {
    final row = _db.remoteAssetEntity;
    Expression<bool> condition =
        row.deletedAt.isNull() &
        viewerVisibilityPredicate(_db, row, userIds, currentUserId) &
        row.visibility.isIn([
          AssetVisibility.timeline.index,
          if (options.includeArchived) AssetVisibility.archive.index,
        ]);
    if (options.onlyFavorites) {
      condition = condition & row.isFavorite.equals(true);
    }
    final timeRange = options.timeRange;
    if (timeRange.from != null || timeRange.to != null) {
      if (timeRange.from != null) {
        condition = condition & row.createdAt.isBiggerOrEqualValue(timeRange.from!);
      }
      if (timeRange.to != null) {
        condition = condition & row.createdAt.isSmallerOrEqualValue(timeRange.to!);
      }
    } else if (options.relativeDays > 0) {
      condition =
          condition &
          row.createdAt.isBiggerOrEqualValue(DateTime.now().toUtc().subtract(Duration(days: options.relativeDays)));
    }
    return condition;
  }

  MapQuery remote(List<String> userIds, String currentUserId, TimelineMapOptions options) =>
      _mapQueryBuilder(assetFilter: (_) => _eligibleAssets(userIds, currentUserId, options));

  /// One aggregate result, including points beyond the marker rendering cap.
  /// The circular longitude gap keeps a Pacific library around the date line.
  /// Sorting/aggregation stays in SQLite; no library-sized Dart list is created.
  Future<MapViewport?> getInitialViewport(
    List<String> userIds,
    String currentUserId,
    TimelineMapOptions options,
  ) async {
    final exif = _db.remoteExifEntity;
    final asset = _db.remoteAssetEntity;
    final points = exif.selectOnly()
      ..addColumns([exif.latitude, exif.longitude])
      ..join([innerJoin(asset, asset.id.equalsExp(exif.assetId), useColumns: false)])
      ..where(
        _eligibleAssets(userIds, currentUserId, options) &
            exif.latitude.isBetweenValues(-90, 90) &
            exif.longitude.isBetweenValues(-180, 180),
      );
    final compiled = points.constructQuery();
    final pointSql = compiled.sql.replaceFirst(RegExp(r';\s*$'), '');
    final row = await _db
        .customSelect(
          '''WITH points(lat, lng) AS ($pointSql),
      stats AS (SELECT COUNT(*) AS photo_count, MIN(lat) AS south, MAX(lat) AS north FROM points),
      longitudes AS (SELECT DISTINCT CASE WHEN lng < 0 THEN lng + 360 ELSE lng END AS lng FROM points),
      gaps AS (
        SELECT lng AS east, COALESCE(LEAD(lng) OVER (ORDER BY lng),
          (SELECT MIN(lng) + 360 FROM longitudes)) AS west FROM longitudes
      ),
      arc AS (SELECT west, east FROM gaps ORDER BY west - east DESC, east LIMIT 1)
      SELECT photo_count, south, north, west, east FROM stats LEFT JOIN arc ON 1 = 1''',
          variables: compiled.introducedVariables,
          readsFrom: compiled.watchedTables.toSet(),
        )
        .getSingle();
    final count = row.read<int>('photo_count');
    if (count == 0) {
      return null;
    }
    double longitude(double value) => (value + 180) % 360 - 180;
    return MapViewport(
      photoCount: count,
      bounds: LatLngBounds(
        southwest: LatLng(row.read<double>('south'), longitude(row.read<double>('west'))),
        northeast: LatLng(row.read<double>('north'), longitude(row.read<double>('east'))),
      ),
    );
  }

  MapQuery _mapQueryBuilder({Expression<bool> Function($RemoteAssetEntityTable row)? assetFilter}) {
    return (markerSource: (bounds) => _watchMapMarker(assetFilter: assetFilter, bounds: bounds));
  }

  Future<List<Marker>> _watchMapMarker({
    Expression<bool> Function($RemoteAssetEntityTable row)? assetFilter,
    LatLngBounds? bounds,
  }) async {
    final assetId = _db.remoteExifEntity.assetId;
    final latitude = _db.remoteExifEntity.latitude;
    final longitude = _db.remoteExifEntity.longitude;

    final query = _db.remoteExifEntity.selectOnly()
      ..addColumns([assetId, latitude, longitude])
      ..join([innerJoin(_db.remoteAssetEntity, _db.remoteAssetEntity.id.equalsExp(assetId), useColumns: false)])
      // NOTE: The 10000-row limit is pre-existing. Under shared-space
      // visibility, the cap now applies to the combined (owner + partners +
      // shared-space) set, which on large deployments could silently drop
      // some of the user's own pins if shared-space pins dominate the
      // most-recent window. Follow-up ticket should either raise the limit,
      // rank owner pins first, or paginate properly. Tracked out-of-scope
      // for the visibility fix.
      ..limit(10000);

    if (assetFilter != null) {
      query.where(assetFilter(_db.remoteAssetEntity));
    }

    // Validate raw EXIF before LatLng clamps/normalizes invalid coordinates.
    // This is a read predicate only; metadata and originals remain unchanged.
    query.where(latitude.isBetweenValues(-90, 90) & longitude.isBetweenValues(-180, 180));

    if (bounds != null) {
      query.where(_db.remoteExifEntity.inBounds(bounds));
    } else {
      query.where(latitude.isNotNull() & longitude.isNotNull());
    }

    final rows = await query.get();
    return List.generate(rows.length, (i) {
      final row = rows[i];
      return Marker(assetId: row.read(assetId)!, location: LatLng(row.read(latitude)!, row.read(longitude)!));
    }, growable: false);
  }
}

extension MapBounds on $RemoteExifEntityTable {
  Expression<bool> inBounds(LatLngBounds bounds) {
    final southwest = bounds.southwest;
    final northeast = bounds.northeast;

    final latInBounds = latitude.isBetweenValues(southwest.latitude, northeast.latitude);
    final longInBounds = southwest.longitude <= northeast.longitude
        ? longitude.isBetweenValues(southwest.longitude, northeast.longitude)
        : (longitude.isBiggerOrEqualValue(southwest.longitude) | longitude.isSmallerOrEqualValue(northeast.longitude));
    return latInBounds & longInBounds;
  }
}
