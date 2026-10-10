import 'package:drift/drift.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/asset/edit.dart';
import 'package:immich_mobile/data/db/main/table/remote/asset.dart';
import 'package:immich_mobile/data/db/main/table/remote/asset.drift.dart';
import 'package:immich_mobile/data/db/main/table/remote/exif.dart';
import 'package:immich_mobile/data/db/main/table/remote/exif.drift.dart';
import 'package:immich_mobile/data/db/main/table/remote/stack.drift.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/asset_edit.model.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/domain/models/stack.model.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_asset.repository.drift.dart';
import 'package:immich_mobile/infrastructure/repositories/sync_stream.repository.dart';
import 'package:immich_mobile/utils/option.dart';

@DriftAccessor()
class RemoteAssetRepository extends DatabaseAccessor<Drift> with $RemoteAssetRepositoryMixin {
  RemoteAssetRepository(super.attachedDatabase);

  Drift get _db => attachedDatabase;

  /// One reactive query for the grid, including primaries; no requests per tile.
  Stream<Map<String, int>> watchStackCounts() {
    final count = _db.remoteAssetEntity.id.count();
    final query = _db.selectOnly(_db.remoteAssetEntity)
      ..addColumns([_db.remoteAssetEntity.stackId, count])
      ..where(_db.remoteAssetEntity.stackId.isNotNull() & _db.remoteAssetEntity.deletedAt.isNull())
      ..groupBy([_db.remoteAssetEntity.stackId]);
    return query.watch().map(
      (rows) => {for (final row in rows) row.read(_db.remoteAssetEntity.stackId)!: row.read(count)!},
    );
  }

  SingleOrNullSelectable<RemoteAsset?> _assetSelectable(String id) {
    final query =
        _db.remoteAssetEntity.select().addColumns([_db.localAssetEntity.id]).join([
            leftOuterJoin(
              _db.localAssetEntity,
              _db.remoteAssetEntity.checksum.equalsExp(_db.localAssetEntity.checksum),
              useColumns: false,
            ),
          ])
          ..where(_db.remoteAssetEntity.id.equals(id))
          ..limit(1);

    return query.map((row) {
      final asset = row.readTable(_db.remoteAssetEntity).toDto();
      return asset.copyWith(localId: row.read(_db.localAssetEntity.id));
    });
  }

  Stream<RemoteAsset?> watch(String id) {
    return _assetSelectable(id).watchSingleOrNull();
  }

  Future<RemoteAsset?> get(String id) {
    return _assetSelectable(id).getSingleOrNull();
  }

  Future<List<RemoteAsset>> getAllDebugForChecksum(String checksum) {
    final query = _db.remoteAssetEntity.select()..where((row) => row.checksum.equals(checksum));

    return query.map((row) => row.toDto()).get();
  }

  Future<List<RemoteAsset>> getStackChildren(RemoteAsset asset) {
    final stackId = asset.stackId;
    if (stackId == null) {
      return Future.value(const []);
    }

    final query = _db.remoteAssetEntity.select()
      ..where((row) => row.stackId.equals(stackId) & row.id.equals(asset.id).not() & row.deletedAt.isNull())
      ..orderBy([(row) => OrderingTerm.desc(row.createdAt)]);

    return query.map((row) => row.toDto()).get();
  }

  Future<ExifInfo?> getExif(String id) {
    return _db.managers.remoteExifEntity
        .filter((row) => row.assetId.id.equals(id))
        .map((row) => row.toDto())
        .getSingleOrNull();
  }

  Future<List<(String, String)>> getPlaces(String userId) {
    final asset = Subquery(
      _db.remoteAssetEntity.select()
        ..where((row) => row.ownerId.equals(userId))
        ..orderBy([(row) => OrderingTerm.desc(row.createdAt)]),
      "asset",
    );

    final query =
        asset.selectOnly().join([
            innerJoin(
              _db.remoteExifEntity,
              _db.remoteExifEntity.assetId.equalsExp(asset.ref(_db.remoteAssetEntity.id)),
              useColumns: false,
            ),
          ])
          ..addColumns([_db.remoteExifEntity.city, _db.remoteExifEntity.assetId])
          ..where(
            _db.remoteExifEntity.city.isNotNull() &
                asset.ref(_db.remoteAssetEntity.deletedAt).isNull() &
                asset.ref(_db.remoteAssetEntity.visibility).equals(AssetVisibility.timeline.index),
          )
          ..groupBy([_db.remoteExifEntity.city])
          ..orderBy([OrderingTerm.asc(_db.remoteExifEntity.city)]);

    return query.map((row) {
      final assetId = row.read(_db.remoteExifEntity.assetId);
      final city = row.read(_db.remoteExifEntity.city);
      return (city!, assetId!);
    }).get();
  }

  Future<void> trash(List<String> ids) async {
    await _changeTrash(ids, restore: false);
  }

  Future<void> restoreTrash(List<String> ids) async {
    await _changeTrash(ids, restore: true);
  }

  Future<List<AssetTrashSnapshot>> beginTrashOperation(List<String> ids, {required bool restore}) =>
      _changeTrash(ids, restore: restore, pending: true);

  Future<List<AssetTrashSnapshot>> beginPermanentDeletion(List<String> ids) => _db.syncStreamRepository
      .updateRetainedTrash(ids, DateTime.now(), preserveExistingDates: true, operation: 'permanent');

  Future<List<AssetTrashSnapshot>> _changeTrash(List<String> ids, {required bool restore, bool pending = false}) {
    return _db.transaction(() async {
      final deletedAt = DateTime.now();
      final snapshots = await _db.syncStreamRepository.updateRetainedTrash(
        ids,
        deletedAt,
        preserveExistingDates: restore,
        operation: pending ? (restore ? 'restore' : 'trash') : null,
      );
      await _db.batch((batch) {
        for (final id in ids) {
          batch.update(
            _db.remoteAssetEntity,
            RemoteAssetEntityCompanion(deletedAt: Value(restore ? null : deletedAt)),
            where: (e) => e.id.equals(id),
          );
        }
      });
      return snapshots;
    });
  }

  Future<void> completeTrashOperation(
    List<AssetTrashSnapshot> snapshots, {
    required bool success,
    bool definiteFailure = false,
  }) => _db.syncStreamRepository.completeTrashOperation(snapshots, success: success, definiteFailure: definiteFailure);

  Future<List<String>> getTrashIds(String ownerId) async {
    final query = _db.remoteAssetEntity.selectOnly()
      ..addColumns([_db.remoteAssetEntity.id])
      ..where(_db.remoteAssetEntity.deletedAt.isNotNull() & _db.remoteAssetEntity.ownerId.equals(ownerId));
    return query.map((row) => row.read(_db.remoteAssetEntity.id)!).get();
  }

  Future<void> emptyTrash(String ownerId) async {
    await _db.transaction(() async {
      await _db.syncStreamRepository.clearRetainedTrash(ownerId: ownerId);
      await _db.remoteAssetEntity.deleteWhere((t) => t.deletedAt.isNotNull() & t.ownerId.equals(ownerId));
    });
  }

  Future<void> restoreAllTrash(String ownerId) async {
    await _restoreAllTrash(ownerId);
  }

  Future<List<AssetTrashSnapshot>> beginRestoreAllTrash(String ownerId) => _restoreAllTrash(ownerId, pending: true);

  Future<List<AssetTrashSnapshot>> _restoreAllTrash(String ownerId, {bool pending = false}) {
    return _db.transaction(() async {
      final retainedIds = await _db.syncStreamRepository.getRetainedTrashIds(ownerId);
      final query = _db.remoteAssetEntity.selectOnly()
        ..addColumns([_db.remoteAssetEntity.id])
        ..where(_db.remoteAssetEntity.deletedAt.isNotNull() & _db.remoteAssetEntity.ownerId.equals(ownerId));
      final rowIds = await query.map((row) => row.read(_db.remoteAssetEntity.id)!).get();
      return _changeTrash({...retainedIds, ...rowIds}.toList(), restore: true, pending: pending);
    });
  }

  Future<void> completePermanentDeletion(
    List<AssetTrashSnapshot> snapshots,
    List<String> suppressedIds,
    List<String> completedIds,
  ) => _db.transaction(() async {
    for (final snapshot in snapshots) {
      await _db.syncStreamRepository.resolvePermanentDeletion(
        snapshot,
        accepted: suppressedIds.contains(snapshot.id),
        complete: completedIds.contains(snapshot.id),
      );
    }
    await deleteAssets(completedIds);
  });

  Future<void> retainPermanentDeletion(List<String> ids) => _db.syncStreamRepository.retainPermanentDeletion(ids);

  Future<List<String>> getDeletionLocalIds(List<String> ids) => _db.syncStreamRepository.getDeletionLocalIds(ids);

  Future<void> deleteAssets(List<String> ids) {
    return _db.transaction(() async {
      await _db.syncStreamRepository.clearRetainedTrash(ids: ids);
      await _db.batch((batch) {
        for (final id in ids) {
          batch.deleteWhere(_db.remoteAssetEntity, (row) => row.id.equals(id));
        }
      });
    });
  }

  Future<void> stack(String userId, StackResponse stack) {
    return _db.transaction(() async {
      final stackIds = await _db.managers.stackEntity
          .filter((row) => row.primaryAssetId.isIn(stack.assetIds))
          .map((row) => row.id)
          .get();

      await _db.batch((batch) {
        for (final stackId in stackIds) {
          batch.deleteWhere(_db.stackEntity, (row) => row.id.equals(stackId));
        }
      });

      await _db.batch((batch) {
        final companion = StackEntityCompanion(ownerId: Value(userId), primaryAssetId: Value(stack.primaryAssetId));

        batch.insert(_db.stackEntity, companion.copyWith(id: Value(stack.id)), onConflict: DoUpdate((_) => companion));

        for (final assetId in stack.assetIds) {
          batch.update(
            _db.remoteAssetEntity,
            RemoteAssetEntityCompanion(stackId: Value(stack.id)),
            where: (e) => e.id.equals(assetId),
          );
        }
      });
    });
  }

  Future<void> unStack(List<String> stackIds) {
    return _db.transaction(() async {
      await _db.batch((batch) {
        for (final stackId in stackIds) {
          batch.deleteWhere(_db.stackEntity, (row) => row.id.equals(stackId));
        }
      });

      // TODO: delete this after adding foreign key on stackId
      await _db.batch((batch) {
        for (final stackId in stackIds) {
          batch.update(
            _db.remoteAssetEntity,
            const RemoteAssetEntityCompanion(stackId: Value(null)),
            where: (e) => e.stackId.equals(stackId),
          );
        }
      });
    });
  }

  Future<void> detachFromStack(String assetId) async {
    await (_db.remoteAssetEntity.update()..where((row) => row.id.equals(assetId))).write(
      const RemoteAssetEntityCompanion(stackId: Value(null)),
    );
  }

  Future<void> updateDescription(String assetId, String description) async {
    await (_db.remoteExifEntity.update()..where((row) => row.assetId.equals(assetId))).write(
      RemoteExifEntityCompanion(description: Value(description)),
    );
  }

  Future<void> updateRating(String assetId, int? rating) async {
    await (_db.remoteExifEntity.update()..where((row) => row.assetId.equals(assetId))).write(
      RemoteExifEntityCompanion(rating: Value(rating)),
    );
  }

  Future<int> getCount() {
    return _db.managers.remoteAssetEntity.count();
  }

  Future<List<AssetEdit>> getAssetEdits(String assetId) {
    final query = _db.assetEditEntity.select()
      ..where((row) => row.assetId.equals(assetId) & row.action.equals(AssetEditAction.other.index).not())
      ..orderBy([(row) => OrderingTerm.asc(row.sequence)]);
    return query.map((row) => row.toDto()!).get();
  }

  Future<void> updateAssets(
    List<String> remoteIds, {
    Option<bool> isFavorite = const .none(),
    Option<AssetVisibility> visibility = const .none(),
    Option<DateTime> createdAt = const .none(),
  }) async {
    if ([isFavorite, visibility, createdAt].every((option) => option.isNone)) {
      return;
    }

    final companion = RemoteAssetEntityCompanion(
      visibility: visibility.toDriftValue(),
      isFavorite: isFavorite.toDriftValue(),
      createdAt: createdAt.toDriftValue(),
    );
    return _db.batch((batch) {
      for (final remoteId in remoteIds) {
        batch.update(_db.remoteAssetEntity, companion, where: (e) => e.id.equals(remoteId));
      }
    });
  }
}
