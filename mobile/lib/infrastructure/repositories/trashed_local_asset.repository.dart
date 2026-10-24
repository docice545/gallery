import 'dart:convert';
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/app/settings.drift.dart';
import 'package:immich_mobile/data/db/main/table/local/asset.dart';
import 'package:immich_mobile/data/db/main/table/local/asset.drift.dart';
import 'package:immich_mobile/data/db/main/table/local/trashed_asset.dart';
import 'package:immich_mobile/data/db/main/table/local/trashed_asset.drift.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/pending_local_trash.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/infrastructure/repositories/trashed_local_asset.repository.drift.dart';
import 'package:logging/logging.dart';

typedef TrashedAsset = ({String albumId, LocalAsset asset});

@DriftAccessor()
class TrashedLocalAssetRepository extends DatabaseAccessor<Drift> with $TrashedLocalAssetRepositoryMixin {
  static const _hashFailurePrefix = 'hash-failure:';
  static const _permissionHashFailurePrefix = 'hash-permission-failure:';
  static const _manageMediaPermissionKey = 'hash-manage-media-permission';

  TrashedLocalAssetRepository(super.attachedDatabase);

  Drift get _db => attachedDatabase;

  static final _log = Logger('TrashedLocalAssetRepository');

  PendingLocalTrash? _decodePendingTrash(String key, String? value) {
    try {
      if (value == null) {
        throw const FormatException('Pending local trash has no stored value');
      }
      return PendingLocalTrash.fromStored(key, value);
    } catch (error, stack) {
      // Preserve raw data for diagnosis or a newer app. A damaged intent must
      // not prevent unrelated, valid Android work from making progress.
      _log.severe('Invalid or unsupported local trash intent retained at $key', error, stack);
      return null;
    }
  }

  Future<({String prefix, String ownerId})?> _pendingTrashScope() async {
    final owner = await _db.authUserEntity.select().getSingleOrNull();
    if (owner == null) {
      return null;
    }
    final endpoint = await (_db.storeEntity.select()..where((row) => row.id.equals(StoreKey.serverEndpoint.id)))
        .getSingleOrNull();
    final scope = sha256.convert(utf8.encode(jsonEncode([endpoint?.stringValue ?? '', owner.id])));
    return (prefix: 'local-trash.v1.$scope/', ownerId: owner.id);
  }

  bool _sameTrashRevision(LocalAsset a, LocalAsset b) =>
      a.id == b.id &&
      a.checksum == b.checksum &&
      a.name == b.name &&
      a.type == b.type &&
      a.createdAt.isAtSameMomentAs(b.createdAt) &&
      a.updatedAt.isAtSameMomentAs(b.updatedAt) &&
      a.width == b.width &&
      a.height == b.height &&
      a.durationMs == b.durationMs;

  /// Commits Android work before its server event can be ACKed. Pending intents
  /// use the existing settings store; actual trashed rows remain confirmed-only.
  Future<void> enqueueTrash(
    Map<String, List<LocalAsset>> assets, {
    bool permanent = false,
    Iterable<String>? remoteIds,
  }) async {
    final requestedRemoteIds = remoteIds?.toSet();
    if (assets.isEmpty && !(permanent && requestedRemoteIds != null && requestedRemoteIds.isNotEmpty)) {
      return;
    }
    await _db.transaction(() async {
      final scope = await _pendingTrashScope();
      if (scope == null) {
        throw StateError('Cannot persist local trash without an authenticated owner');
      }
      if (permanent && requestedRemoteIds != null && requestedRemoteIds.isNotEmpty) {
        // The native operation may already have removed the local row while its
        // completion was interrupted. Preserve a later terminal server event
        // even when there is no longer a local counterpart to look up.
        final queued = await (_db.settingsEntity.select()..where((row) => row.key.like('${scope.prefix}%'))).get();
        for (final row in queued) {
          final item = _decodePendingTrash(row.key, row.value);
          if (item == null) {
            continue;
          }
          final reasons = Map<String, bool>.of(item.remoteReasons);
          var changed = false;
          for (final reason in item.remoteReasons.entries) {
            if (!reason.value && requestedRemoteIds.contains(reason.key)) {
              reasons[reason.key] = true;
              changed = true;
            }
          }
          if (changed) {
            await _replacePendingTrash(item, item.updated(remoteReasons: reasons), DateTime.timestamp());
          }
        }
      }
      final selected =
          await (_db.localAlbumEntity.select()
                ..where((row) => row.backupSelection.equalsValue(BackupSelection.selected)))
              .get();
      final selectedIds = selected.map((album) => album.id).toSet();
      final byId = <String, LocalAsset>{};
      final albumsById = <String, Set<String>>{};
      for (final entry in assets.entries.where((entry) => selectedIds.contains(entry.key))) {
        for (final asset in entry.value) {
          byId[asset.id] = asset;
          (albumsById[asset.id] ??= {}).add(entry.key);
        }
      }
      for (final asset in byId.values) {
        // Only verified, owned backup counterparts authorize an Android action.
        if (asset.checksum == null) {
          continue;
        }
        final local = await (_db.localAssetEntity.select()..where((row) => row.id.equals(asset.id))).getSingleOrNull();
        if (local == null || !_sameTrashRevision(local.toDto(), asset)) {
          continue;
        }
        final matchedRemotes =
            await (_db.remoteAssetEntity.select()..where(
                  (row) =>
                      row.ownerId.equals(scope.ownerId) &
                      row.checksum.equals(asset.checksum!) &
                      (permanent
                          ? const Constant(true)
                          : row.deletedAt.isNotNull() & row.isIndexTombstone.equals(false)),
                ))
                .get();
        final remotes = matchedRemotes.where(
          (remote) => requestedRemoteIds == null || requestedRemoteIds.contains(remote.id),
        );
        if (remotes.isEmpty) {
          continue;
        }
        final key = '${scope.prefix}${sha256.convert(utf8.encode(asset.id))}';
        final stored = await (_db.settingsEntity.select()..where((row) => row.key.equals(key))).getSingleOrNull();
        final old = stored?.value == null ? null : PendingLocalTrash.fromStored(key, stored!.value!);
        final sameRevision = old != null && _sameTrashRevision(old.asset, asset);
        final reasons = <String, bool>{if (sameRevision) ...old.remoteReasons};
        for (final remote in remotes) {
          reasons[remote.id] = (reasons[remote.id] ?? false) || permanent;
        }
        final albumIds = <String>{if (sameRevision) ...old.albumIds, ...albumsById[asset.id]!}.toList()..sort();
        final next = sameRevision
            ? old.updated(albumIds: albumIds, remoteReasons: reasons)
            : PendingLocalTrash(
                key: key,
                rawValue: '',
                asset: asset,
                albumIds: albumIds,
                remoteReasons: reasons,
                attempts: 0,
                nextAttemptAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
              ).updated();
        if (stored?.value != next.rawValue) {
          await _db
              .into(_db.settingsEntity)
              .insertOnConflictUpdate(SettingsEntityCompanion.insert(key: key, value: Value(next.rawValue)));
        }
      }
    });
  }

  Future<bool> _replacePendingTrash(PendingLocalTrash previous, PendingLocalTrash next, DateTime now) async =>
      await (_db.settingsEntity.update()
            ..where((row) => row.key.equals(previous.key) & row.value.equals(previous.rawValue)))
          .write(SettingsEntityCompanion(value: Value(next.rawValue), updatedAt: Value(now))) ==
      1;

  Future<void> _removePendingTrash(PendingLocalTrash item) =>
      (_db.settingsEntity.delete()..where((row) => row.key.equals(item.key) & row.value.equals(item.rawValue))).go();

  /// Claims a bounded due set with a durable lease shared by sync isolates.
  /// An abandoned lease becomes eligible after restart without a running timer.
  Future<List<PendingLocalTrash>> claimPendingTrash({DateTime? now, int limit = 32}) async {
    if (limit <= 0) {
      return [];
    }
    final instant = now ?? DateTime.timestamp();
    return _db.transaction(() async {
      final scope = await _pendingTrashScope();
      if (scope == null) {
        return <PendingLocalTrash>[];
      }
      final nextAttempt = CaseWhenExpression<int>(
        cases: [
          CaseWhen(
            FunctionCallExpression<int>('json_valid', [_db.settingsEntity.value]).equals(1),
            then: FunctionCallExpression<int>('coalesce', [
              FunctionCallExpression<int>('json_extract', [
                _db.settingsEntity.value,
                const Constant(r'$.nextAttemptAt'),
              ]),
              const Constant(0),
            ]),
          ),
        ],
        orElse: const Constant(0),
      );
      final rows =
          await (_db.settingsEntity.select()
                ..where(
                  (row) =>
                      row.key.like('${scope.prefix}%') &
                      nextAttempt.isSmallerOrEqualValue(instant.millisecondsSinceEpoch),
                )
                ..orderBy([(row) => OrderingTerm.asc(row.updatedAt)])
                ..limit(limit * 4))
              .get();
      final selected =
          await (_db.localAlbumEntity.select()
                ..where((row) => row.backupSelection.equalsValue(BackupSelection.selected)))
              .get();
      final selectedIds = selected.map((album) => album.id).toSet();
      final claimed = <PendingLocalTrash>[];
      for (final row in rows) {
        final item = _decodePendingTrash(row.key, row.value);
        if (item == null) {
          // Rotate invalid retained rows behind other due work. Preserve the
          // exact raw intent, including unsupported future-version records.
          await (_db.settingsEntity.update()..where((entry) => entry.key.equals(row.key))).write(
            SettingsEntityCompanion(updatedAt: Value(instant)),
          );
          continue;
        }
        final local = await (_db.localAssetEntity.select()..where((row) => row.id.equals(item.asset.id)))
            .getSingleOrNull();
        if (local != null && !_sameTrashRevision(local.toDto(), item.asset)) {
          _log.warning('Cancelled stale Android trash intent: asset ${item.asset.id} changed');
          await _removePendingTrash(item);
          continue;
        }
        final memberships = local == null
            ? item.albumIds
            : (await (_db.localAlbumAssetEntity.select()..where((row) => row.assetId.equals(item.asset.id))).get()).map(
                (row) => row.albumId,
              );
        final albums = memberships.where(selectedIds.contains).toSet().toList()..sort();
        final reasons = <String, bool>{};
        var unknownRemoteState = false;
        var verifiedRemoteState = false;
        for (final reason in item.remoteReasons.entries) {
          if (reason.value) {
            // A terminal server delete must survive removal of its remote row.
            reasons[reason.key] = true;
            verifiedRemoteState = true;
            continue;
          }
          final remote =
              await (_db.remoteAssetEntity.select()
                    ..where((remote) => remote.id.equals(reason.key) & remote.ownerId.equals(scope.ownerId)))
                  .getSingleOrNull();
          if (remote == null) {
            // Reset/backfill can temporarily remove metadata. Do not lose intent
            // or trash a file on an unverified current server state.
            unknownRemoteState = true;
            reasons[reason.key] = false;
          } else if (remote.checksum == item.asset.checksum && remote.deletedAt != null && !remote.isIndexTombstone) {
            reasons[reason.key] = false;
            verifiedRemoteState = true;
          }
        }
        if (albums.isEmpty || reasons.isEmpty) {
          await _removePendingTrash(item);
          continue;
        }
        if (unknownRemoteState && !verifiedRemoteState) {
          final deferred = item.updated(
            code: 'remoteStateUnknown',
            message: 'Waiting for current owned server trash metadata',
            nextAttemptAt: instant.add(const Duration(minutes: 1)),
          );
          await _replacePendingTrash(item, deferred, instant);
          continue;
        }
        final lease = item.updated(
          albumIds: albums,
          remoteReasons: reasons,
          attempts: item.attempts + 1,
          nextAttemptAt: instant.add(const Duration(minutes: 2)),
          code: 'inFlight',
        );
        if (await _replacePendingTrash(item, lease, instant)) {
          claimed.add(lease);
          if (claimed.length == limit) {
            break;
          }
        }
      }
      return claimed;
    });
  }

  Future<bool> _isCurrentPendingTrash(PendingLocalTrash item) async {
    final scope = await _pendingTrashScope();
    if (scope == null || !item.key.startsWith(scope.prefix)) {
      return false;
    }
    return await (_db.settingsEntity.select()
              ..where((row) => row.key.equals(item.key) & row.value.equals(item.rawValue)))
            .getSingleOrNull() !=
        null;
  }

  /// Called only for a native-verified trashed/already-trashed result.
  Future<void> completePendingTrash(PendingLocalTrash item) => _db.transaction(() async {
    if (!await _isCurrentPendingTrash(item)) {
      return;
    }
    final local = await (_db.localAssetEntity.select()..where((row) => row.id.equals(item.asset.id))).getSingleOrNull();
    if (local != null && !_sameTrashRevision(local.toDto(), item.asset)) {
      _log.warning('Android trash result cannot replace changed local revision ${item.asset.id}');
      await _removePendingTrash(item);
      return;
    }
    await trashLocalAsset({
      for (final album in item.albumIds) album: [item.asset],
    });
    await _removePendingTrash(item);
  });

  Future<void> failPendingTrash(PendingLocalTrash item, String code, String? message, {DateTime? now}) async {
    final instant = now ?? DateTime.timestamp();
    await _db.transaction(() async {
      if (!await _isCurrentPendingTrash(item)) {
        return;
      }
      final minutes = math.min(360, 1 << math.min(math.max(0, item.attempts - 1), 9));
      final failed = item.updated(
        code: code,
        message: message?.substring(0, math.min(message.length, 2048)),
        clearMessage: message == null,
        nextAttemptAt: instant.add(Duration(minutes: minutes)),
      );
      await _replacePendingTrash(item, failed, instant);
    });
  }

  Future<void> retryPermissionBlockedTrash({DateTime? now}) async {
    final instant = now ?? DateTime.timestamp();
    await _db.transaction(() async {
      final scope = await _pendingTrashScope();
      if (scope == null) {
        return;
      }
      final rows = await (_db.settingsEntity.select()..where((row) => row.key.like('${scope.prefix}%'))).get();
      for (final row in rows) {
        final item = _decodePendingTrash(row.key, row.value);
        if (item == null) {
          continue;
        }
        if (item.code == 'permissionDenied' || item.code == 'PERMISSION_DENIED' || item.code == 'permissionRevoked') {
          await _replacePendingTrash(item, item.updated(nextAttemptAt: instant), instant);
        }
      }
    });
  }

  /// Server Restore cancels pending trash only. It never recreates device media.
  Future<void> cancelPendingTrash(Iterable<String> remoteIds) async {
    final ids = remoteIds.toSet();
    if (ids.isEmpty) {
      return;
    }
    await _db.transaction(() async {
      final scope = await _pendingTrashScope();
      if (scope == null) {
        return;
      }
      final confirmedRestores =
          await (_db.remoteAssetEntity.select()..where(
                (row) =>
                    row.id.isIn(ids) &
                    row.ownerId.equals(scope.ownerId) &
                    row.deletedAt.isNull() &
                    row.isIndexTombstone.equals(false),
              ))
              .get();
      final restoredIds = confirmedRestores.map((row) => row.id).toSet();
      if (restoredIds.isEmpty) {
        return;
      }
      final rows = await (_db.settingsEntity.select()..where((row) => row.key.like('${scope.prefix}%'))).get();
      for (final row in rows) {
        final item = _decodePendingTrash(row.key, row.value);
        if (item == null) {
          continue;
        }
        final reasons = Map<String, bool>.of(item.remoteReasons)
          ..removeWhere((id, permanent) => restoredIds.contains(id) && !permanent);
        if (reasons.length == item.remoteReasons.length) {
          continue;
        }
        if (reasons.isEmpty) {
          await _removePendingTrash(item);
        } else {
          await _replacePendingTrash(item, item.updated(remoteReasons: reasons), DateTime.timestamp());
        }
      }
    });
  }

  /// Matches remote_asset_entity rows owned by the current user. The asset is unique over (owner, checksum),
  /// so partners can have a duplicate checksum
  Expression<bool> get _ownedByCurrentUser =>
      _db.remoteAssetEntity.ownerId.isInQuery(_db.selectOnly(_db.authUserEntity)..addColumns([_db.authUserEntity.id]));

  Future<void> updateHashes(Map<String, String> hashes) {
    if (hashes.isEmpty) {
      return Future.value();
    }
    return _db.batch((batch) async {
      for (final entry in hashes.entries) {
        batch.update(
          _db.trashedLocalAssetEntity,
          TrashedLocalAssetEntityCompanion(checksum: Value(entry.value)),
          where: (e) => e.id.equals(entry.key),
        );
      }
    });
  }

  Future<List<LocalAsset>> getAssetsToHash(Iterable<String> albumIds) async {
    final query = _db.trashedLocalAssetEntity.select()..where((r) => r.albumId.isIn(albumIds) & r.checksum.isNull());
    final candidates = await query.map((row) => row.toLocalAsset()).get();
    final failures = await _hashFailureRows();
    final permissionFailures = await _hashFailureRows(prefix: _permissionHashFailurePrefix);
    return candidates
        .where(
          (asset) =>
              (failures[asset.id] == null || !failures[asset.id]!.isAtSameMomentAs(asset.updatedAt)) &&
              (permissionFailures[asset.id] == null ||
                  !permissionFailures[asset.id]!.isAtSameMomentAs(asset.updatedAt)),
        )
        .toList();
  }

  Future<Map<String, DateTime>> _hashFailureRows({String prefix = _hashFailurePrefix}) async {
    final rows = await (_db.settingsEntity.select()..where((row) => row.key.like('$prefix%'))).get();
    return {
      for (final row in rows)
        if (row.value != null)
          row.key.substring(prefix.length): DateTime.tryParse(row.value!) ?? DateTime.fromMillisecondsSinceEpoch(0),
    };
  }

  Future<void> recordHashFailures(Map<String, DateTime> failures) async {
    if (failures.isEmpty) {
      return;
    }
    await _db.batch((batch) {
      for (final entry in failures.entries) {
        batch.insert(
          _db.settingsEntity,
          SettingsEntityCompanion.insert(
            key: '$_hashFailurePrefix${entry.key}',
            value: Value(entry.value.toIso8601String()),
          ),
          onConflict: DoUpdate((_) => SettingsEntityCompanion(value: Value(entry.value.toIso8601String()))),
        );
      }
    });
  }

  Future<void> recordPermissionHashFailures(Map<String, DateTime> failures) async {
    if (failures.isEmpty) {
      return;
    }
    await _db.batch((batch) {
      for (final entry in failures.entries) {
        batch.insert(
          _db.settingsEntity,
          SettingsEntityCompanion.insert(
            key: '$_permissionHashFailurePrefix${entry.key}',
            value: Value(entry.value.toIso8601String()),
          ),
          onConflict: DoUpdate((_) => SettingsEntityCompanion(value: Value(entry.value.toIso8601String()))),
        );
      }
    });
  }

  Future<void> clearHashFailures(Iterable<String> assetIds) async {
    final ids = assetIds.toList();
    final keys = [...ids.map((id) => '$_hashFailurePrefix$id'), ...ids.map((id) => '$_permissionHashFailurePrefix$id')];
    if (keys.isNotEmpty) {
      await (_db.delete(_db.settingsEntity)..where((row) => row.key.isIn(keys))).go();
    }
  }

  Future<bool> updateManageMediaPermission(bool granted) async {
    final existing = await (_db.settingsEntity.select()..where((row) => row.key.equals(_manageMediaPermissionKey)))
        .getSingleOrNull();
    await _db
        .into(_db.settingsEntity)
        .insertOnConflictUpdate(
          SettingsEntityCompanion.insert(key: _manageMediaPermissionKey, value: Value(granted.toString())),
        );
    return existing?.value == 'false' && granted;
  }

  Future<void> clearPermissionHashFailures() async {
    final permissionFailureKeys =
        (await (_db.settingsEntity.select()..where((row) => row.key.like('$_permissionHashFailurePrefix%'))).get())
            .map((row) => row.key)
            .toList();
    if (permissionFailureKeys.isEmpty) {
      return;
    }
    final ids = permissionFailureKeys.map((key) => key.substring(_permissionHashFailurePrefix.length));
    final keys = [...permissionFailureKeys, ...ids.map((id) => '$_hashFailurePrefix$id')];
    await (_db.delete(_db.settingsEntity)..where((row) => row.key.isIn(keys))).go();
  }

  Future<Iterable<LocalAsset>> getToRestore() async {
    final selectedAlbumIds = (_db.selectOnly(_db.localAlbumEntity)
      ..addColumns([_db.localAlbumEntity.id])
      ..where(_db.localAlbumEntity.backupSelection.equalsValue(BackupSelection.selected)));

    final rows =
        await (_db.select(_db.trashedLocalAssetEntity).join([
              innerJoin(
                _db.remoteAssetEntity,
                _db.remoteAssetEntity.checksum.equalsExp(_db.trashedLocalAssetEntity.checksum) & _ownedByCurrentUser,
              ),
            ])..where(
              _db.trashedLocalAssetEntity.source.equalsValue(TrashOrigin.remoteSync) &
                  _db.trashedLocalAssetEntity.albumId.isInQuery(selectedAlbumIds) &
                  _db.remoteAssetEntity.deletedAt.isNull(),
            ))
            .get();

    return rows.map((result) => result.readTable(_db.trashedLocalAssetEntity).toLocalAsset());
  }

  /// Applies resulted snapshot of trashed assets:
  /// - upserts incoming rows
  /// - deletes rows that are not present in the snapshot
  Future<void> processTrashSnapshot(Iterable<TrashedAsset> trashedAssets) async {
    if (trashedAssets.isEmpty) {
      await _db.delete(_db.trashedLocalAssetEntity).go();
      await (_db.delete(_db.settingsEntity)..where((row) => row.key.like('$_hashFailurePrefix%'))).go();
      await (_db.delete(_db.settingsEntity)..where((row) => row.key.like('$_permissionHashFailurePrefix%'))).go();
      return;
    }
    final assetIds = trashedAssets.map((e) => e.asset.id).toSet();
    final failureRows = await (_db.settingsEntity.select()..where((row) => row.key.like('$_hashFailurePrefix%'))).get();
    final permissionFailureRows =
        await (_db.settingsEntity.select()..where((row) => row.key.like('$_permissionHashFailurePrefix%'))).get();
    final staleFailureKeys = [...failureRows, ...permissionFailureRows].map((row) => row.key).where((key) {
      final prefix = key.startsWith(_permissionHashFailurePrefix) ? _permissionHashFailurePrefix : _hashFailurePrefix;
      return !assetIds.contains(key.substring(prefix.length));
    }).toList();
    if (staleFailureKeys.isNotEmpty) {
      await (_db.delete(_db.settingsEntity)..where((row) => row.key.isIn(staleFailureKeys))).go();
    }
    final Map<String, String> localChecksumById = await _getCachedChecksums(assetIds);

    return _db.transaction(() async {
      await _db.batch((batch) {
        for (final item in trashedAssets) {
          final effectiveChecksum = localChecksumById[item.asset.id] ?? item.asset.checksum;
          final companion = TrashedLocalAssetEntityCompanion.insert(
            id: item.asset.id,
            albumId: item.albumId,
            checksum: Value(effectiveChecksum),
            name: item.asset.name,
            type: item.asset.type,
            createdAt: Value(item.asset.createdAt),
            updatedAt: Value(item.asset.updatedAt),
            width: Value(item.asset.width),
            height: Value(item.asset.height),
            durationMs: Value(item.asset.durationMs),
            isFavorite: Value(item.asset.isFavorite),
            orientation: Value(item.asset.orientation),
            playbackStyle: Value(item.asset.playbackStyle),
            source: TrashOrigin.localSync,
          );

          batch.insert<$TrashedLocalAssetEntityTable, TrashedLocalAssetEntityData>(
            _db.trashedLocalAssetEntity,
            companion,
            onConflict: DoUpdate((_) => companion, where: (old) => old.updatedAt.isNotValue(item.asset.updatedAt)),
          );
        }
      });

      if (assetIds.length <= kDriftMaxChunk) {
        await (_db.delete(_db.trashedLocalAssetEntity)..where((row) => row.id.isNotIn(assetIds))).go();
      } else {
        final existingIds = await (_db.selectOnly(
          _db.trashedLocalAssetEntity,
        )..addColumns([_db.trashedLocalAssetEntity.id])).map((r) => r.read(_db.trashedLocalAssetEntity.id)!).get();
        final idToDelete = existingIds.where((id) => !assetIds.contains(id));
        for (final slice in idToDelete.slices(kDriftMaxChunk)) {
          await (_db.delete(_db.trashedLocalAssetEntity)..where((t) => t.id.isIn(slice))).go();
        }
      }
    });
  }

  Stream<int> watchCount() {
    return (_db.selectOnly(_db.trashedLocalAssetEntity)..addColumns([_db.trashedLocalAssetEntity.id.count()]))
        .watchSingle()
        .map((row) => row.read<int>(_db.trashedLocalAssetEntity.id.count()) ?? 0);
  }

  Stream<int> watchHashedCount() {
    return (_db.selectOnly(_db.trashedLocalAssetEntity)
          ..addColumns([_db.trashedLocalAssetEntity.id.count()])
          ..where(_db.trashedLocalAssetEntity.checksum.isNotNull()))
        .watchSingle()
        .map((row) => row.read<int>(_db.trashedLocalAssetEntity.id.count()) ?? 0);
  }

  Future<void> trashLocalAsset(Map<String, List<LocalAsset>> assetsByAlbums) async {
    if (assetsByAlbums.isEmpty) {
      return Future.value();
    }

    final companions = <TrashedLocalAssetEntityCompanion>[];
    final idToDelete = <String>{};

    for (final entry in assetsByAlbums.entries) {
      for (final asset in entry.value) {
        idToDelete.add(asset.id);
        companions.add(
          TrashedLocalAssetEntityCompanion(
            id: Value(asset.id),
            name: Value(asset.name),
            albumId: Value(entry.key),
            checksum: Value(asset.checksum),
            type: Value(asset.type),
            width: Value(asset.width),
            height: Value(asset.height),
            durationMs: Value(asset.durationMs),
            isFavorite: Value(asset.isFavorite),
            orientation: Value(asset.orientation),
            playbackStyle: Value(asset.playbackStyle),
            createdAt: Value(asset.createdAt),
            updatedAt: Value(asset.updatedAt),
            source: const Value(TrashOrigin.remoteSync),
          ),
        );
      }
    }

    await _db.transaction(() async {
      for (final companion in companions) {
        await _db.into(_db.trashedLocalAssetEntity).insertOnConflictUpdate(companion);
      }

      for (final slice in idToDelete.slices(kDriftMaxChunk)) {
        await (_db.delete(_db.localAssetEntity)..where((t) => t.id.isIn(slice))).go();
      }
    });
  }

  Future<void> applyRestoredAssets(List<String> idList) async {
    if (idList.isEmpty) {
      return Future.value();
    }

    final trashedAssets = <TrashedLocalAssetEntityData>[];

    for (final slice in idList.slices(kDriftMaxChunk)) {
      final q = _db.select(_db.trashedLocalAssetEntity)..where((t) => t.id.isIn(slice));
      trashedAssets.addAll(await q.get());
    }

    if (trashedAssets.isEmpty) {
      return;
    }

    final companions = trashedAssets.map((e) {
      return LocalAssetEntityCompanion.insert(
        id: e.id,
        name: e.name,
        type: e.type,
        createdAt: Value(e.createdAt),
        updatedAt: Value(e.updatedAt),
        width: Value(e.width),
        height: Value(e.height),
        durationMs: Value(e.durationMs),
        checksum: Value(e.checksum),
        isFavorite: Value(e.isFavorite),
        orientation: Value(e.orientation),
        playbackStyle: Value(e.playbackStyle),
      );
    });

    await _db.transaction(() async {
      for (final companion in companions) {
        await _db.into(_db.localAssetEntity).insertOnConflictUpdate(companion);
      }
      for (final slice in idList.slices(kDriftMaxChunk)) {
        await (_db.delete(_db.trashedLocalAssetEntity)..where((t) => t.id.isIn(slice))).go();
      }
    });
  }

  Future<void> applyTrashedAssets(List<String> idList) async {
    if (idList.isEmpty) {
      return Future.value();
    }

    final trashedAssets = <({LocalAssetEntityData asset, String albumId})>[];

    for (final slice in idList.slices(kDriftMaxChunk)) {
      final rows = await (_db.select(_db.localAlbumAssetEntity).join([
        innerJoin(_db.localAssetEntity, _db.localAlbumAssetEntity.assetId.equalsExp(_db.localAssetEntity.id)),
      ])..where(_db.localAlbumAssetEntity.assetId.isIn(slice))).get();

      final assetsWithAlbum = rows.map(
        (row) =>
            (albumId: row.readTable(_db.localAlbumAssetEntity).albumId, asset: row.readTable(_db.localAssetEntity)),
      );

      trashedAssets.addAll(assetsWithAlbum);
    }

    if (trashedAssets.isEmpty) {
      return;
    }

    final companions = trashedAssets.map((e) {
      return TrashedLocalAssetEntityCompanion.insert(
        id: e.asset.id,
        name: e.asset.name,
        type: e.asset.type,
        createdAt: Value(e.asset.createdAt),
        updatedAt: Value(e.asset.updatedAt),
        width: Value(e.asset.width),
        height: Value(e.asset.height),
        durationMs: Value(e.asset.durationMs),
        checksum: Value(e.asset.checksum),
        isFavorite: Value(e.asset.isFavorite),
        orientation: Value(e.asset.orientation),
        playbackStyle: Value(e.asset.playbackStyle),
        source: TrashOrigin.localUser,
        albumId: e.albumId,
      );
    });

    await _db.transaction(() async {
      for (final companion in companions) {
        await _db.into(_db.trashedLocalAssetEntity).insertOnConflictUpdate(companion);
      }
      for (final slice in idList.slices(kDriftMaxChunk)) {
        await (_db.delete(_db.localAssetEntity)..where((t) => t.id.isIn(slice))).go();
      }
    });
  }

  Future<Map<String, List<LocalAsset>>> getToTrash() async {
    final result = <String, List<LocalAsset>>{};

    final rows =
        await (_db.select(_db.localAlbumAssetEntity).join([
              innerJoin(_db.localAlbumEntity, _db.localAlbumAssetEntity.albumId.equalsExp(_db.localAlbumEntity.id)),
              innerJoin(_db.localAssetEntity, _db.localAlbumAssetEntity.assetId.equalsExp(_db.localAssetEntity.id)),
              leftOuterJoin(
                _db.remoteAssetEntity,
                _db.remoteAssetEntity.checksum.equalsExp(_db.localAssetEntity.checksum) & _ownedByCurrentUser,
              ),
            ])..where(
              _db.localAlbumEntity.backupSelection.equalsValue(BackupSelection.selected) &
                  _db.remoteAssetEntity.deletedAt.isNotNull(),
            ))
            .get();

    for (final row in rows) {
      final albumId = row.readTable(_db.localAlbumAssetEntity).albumId;
      final asset = row.readTable(_db.localAssetEntity).toDto();
      (result[albumId] ??= <LocalAsset>[]).add(asset);
    }

    return result;
  }

  //attempt to reuse existing checksums
  Future<Map<String, String>> _getCachedChecksums(Set<String> assetIds) async {
    final localChecksumById = <String, String>{};

    for (final slice in assetIds.slices(kDriftMaxChunk)) {
      final rows =
          await (_db.selectOnly(_db.localAssetEntity)
                ..where(_db.localAssetEntity.id.isIn(slice) & _db.localAssetEntity.checksum.isNotNull())
                ..addColumns([_db.localAssetEntity.id, _db.localAssetEntity.checksum]))
              .get();

      for (final r in rows) {
        localChecksumById[r.read(_db.localAssetEntity.id)!] = r.read(_db.localAssetEntity.checksum)!;
      }
    }

    return localChecksumById;
  }
}
