import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/hash.service.dart';
import 'package:immich_mobile/domain/services/local_sync.service.dart';
import 'package:immich_mobile/domain/services/local_trash_sync.service.dart';
import 'package:immich_mobile/domain/services/sync_stream.service.dart';
import 'package:immich_mobile/infrastructure/repositories/sync_api.repository.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/providers/infrastructure/cancel.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_mobile/repositories/permission.repository.dart';

final syncStreamServiceProvider = Provider((ref) {
  final db = ref.watch(driftProvider);
  return SyncStreamService(
    syncApiRepository: ref.watch(syncApiRepositoryProvider),
    syncStreamRepository: db.syncStreamRepository,
    localAssetRepository: db.localAssetRepository,
    trashedLocalAssetRepository: db.trashedLocalAssetRepository,
    assetMediaRepository: ref.watch(assetMediaRepositoryProvider),
    permissionRepository: ref.watch(permissionRepositoryProvider),
    syncMigrationRepository: db.syncMigrationRepository,
    api: ref.watch(apiServiceProvider),
    cancellation: ref.watch(cancellationProvider),
  );
});

final syncApiRepositoryProvider = Provider((ref) => SyncApiRepository(ref.watch(apiServiceProvider)));

final localTrashSyncServiceProvider = Provider((ref) {
  return LocalTrashSyncService(
    repository: ref.watch(driftProvider).trashedLocalAssetRepository,
    mediaRepository: ref.watch(assetMediaRepositoryProvider),
    permissionRepository: ref.watch(permissionRepositoryProvider),
    cancellation: ref.watch(cancellationProvider),
  );
});

final localSyncServiceProvider = Provider((ref) {
  final db = ref.watch(driftProvider);
  return LocalSyncService(
    localAlbumRepository: db.localAlbumRepository,
    trashedLocalAssetRepository: db.trashedLocalAssetRepository,
    assetMediaRepository: ref.watch(assetMediaRepositoryProvider),
    permissionRepository: ref.watch(permissionRepositoryProvider),
    nativeSyncApi: ref.watch(nativeSyncApiProvider),
    cancellation: ref.watch(cancellationProvider),
  );
});

final hashServiceProvider = Provider((ref) {
  final db = ref.watch(driftProvider);
  return HashService(
    localAlbumRepository: db.localAlbumRepository,
    localAssetRepository: db.localAssetRepository,
    nativeSyncApi: ref.watch(nativeSyncApiProvider),
    trashedLocalAssetRepository: db.trashedLocalAssetRepository,
    cancellation: ref.watch(cancellationProvider),
  );
});
