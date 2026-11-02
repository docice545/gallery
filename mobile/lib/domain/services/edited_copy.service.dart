import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/app/settings.drift.dart';
import 'package:immich_mobile/data/db/main/table/local/album.drift.dart';
import 'package:immich_mobile/data/db/main/table/local/album_asset.drift.dart';
import 'package:immich_mobile/data/db/main/table/local/asset.drift.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/backup/backup.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/repositories/file_media.repository.dart';
import 'package:logging/logging.dart';
import 'package:photo_manager/photo_manager.dart' hide AssetType;

final editedCopyServiceProvider = Provider<EditedCopyService>((ref) {
  final db = ref.watch(driftProvider);
  final ownerId = ref.watch(authUserProvider).id;
  final endpoint = ref.read(storeServiceProvider).tryGet(StoreKey.serverEndpoint) ?? '';
  final sync = ref.read(backgroundSyncProvider);
  final backup = ref.read(backupProvider.notifier);
  final settings = ref.read(settingsProvider);
  final files = ref.read(fileMediaRepositoryProvider);
  return EditedCopyService(
    db,
    ref.watch(nativeSyncApiProvider),
    ownerId: ownerId,
    endpoint: endpoint,
    importPlatformCopy: Platform.isAndroid ? null : (_) => sync.syncLocal(full: true),
    completeMetadata: (asset) => files.completeImageImport(asset, mimeType: 'image/png'),
    onImported: () async {
      if (!settings.appConfig.backup.enabled ||
          (await db.storeRepository.tryGet(StoreKey.currentUser))?.id != ownerId ||
          await db.storeRepository.tryGet(StoreKey.serverEndpoint) != endpoint) {
        return;
      }
      await sync.hashAssets(enqueue: true);
      if (backup.mounted &&
          settings.appConfig.backup.enabled &&
          (await db.storeRepository.tryGet(StoreKey.currentUser))?.id == ownerId &&
          await db.storeRepository.tryGet(StoreKey.serverEndpoint) == endpoint) {
        await backup.startForegroundBackup(ownerId);
      }
    },
  );
});

/// Imports the one file which the editor has already created. A retry never
/// creates another file, starts a full device scan, or changes unrelated albums.
class EditedCopyService {
  EditedCopyService(
    this._db,
    this._native, {
    required this.ownerId,
    required this.endpoint,
    Future<AssetEntity?> Function(AssetEntity)? readFresh,
    Future<void> Function(Duration)? delay,
    Future<void> Function(AssetEntity)? completeMetadata,
    this.importPlatformCopy,
    this.maxAttempts = 3,
    this.canContinue,
    this.remainingBudget,
    this.nativeTimeout = const Duration(seconds: 5),
    this.onImported,
  }) : _readFresh = readFresh ?? _readNative,
       _delay = delay ?? Future<void>.delayed,
       _completeMetadata = completeMetadata ?? _completeNativeMetadata;

  static const outputRelativePath = 'DCIM/Noodle Gallery';
  static const _pendingPrefix = 'editor.copy.pending.';
  final Drift _db;
  final NativeSyncApi _native;
  final String ownerId;
  final String endpoint;
  final Future<AssetEntity?> Function(AssetEntity) _readFresh;
  final Future<void> Function(Duration) _delay;
  final Future<void> Function(AssetEntity) _completeMetadata;
  final Duration nativeTimeout;
  final int maxAttempts;
  final bool Function()? canContinue;
  final Duration Function()? remainingBudget;
  final Future<void> Function(AssetEntity)? importPlatformCopy;
  final Future<void> Function()? onImported;
  final _log = Logger('EditedCopyService');
  final Map<String, Future<void>> _imports = {};

  static Future<AssetEntity?> _readNative(AssetEntity asset) => asset.obtainForNewProperties();
  static Future<void> _completeNativeMetadata(AssetEntity asset) =>
      const FileMediaRepository().completeImageImport(asset, mimeType: 'image/png');

  String _key(String id) =>
      '$_pendingPrefix${Uri.encodeComponent(endpoint)}/${Uri.encodeComponent(ownerId)}/${Uri.encodeComponent(id)}';

  /// Records the known ID before retryable native metadata/indexing work. This
  /// also handles a successful file creation followed by failed MIME completion.
  Future<void> recordSavedCopy(AssetEntity saved) async {
    // A native save can finish after account navigation. Journal only under
    // the captured origin scope, then check the active scope before importing.
    if (ownerId.isEmpty || endpoint.isEmpty) {
      throw StateError('The editor copy has no originating account');
    }
    if (saved.id.isEmpty) {
      throw StateError('The saved copy has no MediaStore identifier');
    }
    if (saved.title == null || !RegExp(r'^gallery-edit-\d+\.png$').hasMatch(saved.title!)) {
      throw StateError('The saved copy has no reliable editor filename');
    }
    if (saved.relativePath != null && _normalizePath(saved.relativePath) != outputRelativePath) {
      throw StateError('The saved copy is outside the editor output album');
    }
    await _db
        .into(_db.settingsEntity)
        .insertOnConflictUpdate(
          SettingsEntityCompanion.insert(
            key: _key(saved.id),
            value: Value(
              jsonEncode({
                'ownerId': ownerId,
                'endpoint': endpoint,
                'id': saved.id,
                'name': saved.title,
                'createdAtSeconds': saved.createDateSecond,
                'relativePath': saved.relativePath,
                'lastAttemptAt': DateTime.now().toUtc().millisecondsSinceEpoch,
              }),
            ),
          ),
        );
  }

  /// Reuses the normal local-sync lifecycle, including no-delta runs, to recover
  /// only editor-created IDs. An offline server is never needed for this import.
  static Future<void> recoverPendingCopies(
    Drift db,
    NativeSyncApi native, {
    Future<AssetEntity?> Function(AssetEntity)? readFresh,
    Future<void> Function(AssetEntity)? completeMetadata,
    Future<void> Function(Duration)? delay,
    Duration nativeTimeout = const Duration(seconds: 5),
    Duration budget = const Duration(seconds: 2),
    bool Function()? isCancelled,
  }) async {
    final clock = Stopwatch()..start();
    final owner = await db.storeRepository.tryGet(StoreKey.currentUser);
    final endpoint = await db.storeRepository.tryGet(StoreKey.serverEndpoint);
    if (owner == null || endpoint == null) {
      return;
    }
    final service = EditedCopyService(
      db,
      native,
      ownerId: owner.id,
      endpoint: endpoint,
      readFresh: readFresh,
      completeMetadata: completeMetadata,
      delay: delay,
      nativeTimeout: nativeTimeout,
      maxAttempts: 1,
      canContinue: () => !(isCancelled?.call() ?? false) && clock.elapsed < budget,
      remainingBudget: () => budget - clock.elapsed,
    );
    final prefix = service._key('');
    final pending = await (db.select(
      db.settingsEntity,
    )..where((row) => row.key.isBiggerOrEqualValue(prefix) & row.key.isSmallerThanValue('$prefix\uFFFF'))).get();
    final candidates = <Map<String, dynamic>>[];
    for (final row in pending) {
      try {
        final data = jsonDecode(row.value ?? '') as Map<String, dynamic>;
        if (data['ownerId'] != owner.id || data['endpoint'] != endpoint || data['id'] is! String) {
          continue;
        }
        if (data['name'] is! String || !RegExp(r'^gallery-edit-\d+\.png$').hasMatch(data['name'] as String)) {
          service._log.warning('A pending editor import has no reliable file identity');
          continue;
        }
        candidates.add(data);
      } catch (error, stack) {
        service._log.warning('Invalid pending editor import metadata', error, stack);
      }
    }
    // Retry a bounded batch fairly: a permanently unavailable ID must not
    // starve later copies on every app restart/local sync.
    candidates.sort((a, b) => ((a['lastAttemptAt'] as num?) ?? 0).compareTo((b['lastAttemptAt'] as num?) ?? 0));
    for (final data in candidates.take(10)) {
      if (isCancelled?.call() == true || clock.elapsed >= budget) {
        return;
      }
      try {
        await service.importSavedCopy(
          AssetEntity(
            id: data['id'] as String,
            typeInt: 1,
            width: 0,
            height: 0,
            title: data['name'] as String?,
            createDateSecond: data['createdAtSeconds'] as int?,
            relativePath: data['relativePath'] as String?,
          ),
        );
      } catch (error, stack) {
        service._log.warning('Saved editor copy is still pending local import', error, stack);
      }
    }
  }

  Future<void> importSavedCopy(AssetEntity saved) => _imports[saved.id] ??= _import(saved).whenComplete(() {
    // Only forget the slot; returning its Future here would await itself.
    unawaited(_imports.remove(saved.id));
  });

  Future<void> _checkAccount() async {
    _checkActive();
    if ((await _db.storeRepository.tryGet(StoreKey.currentUser))?.id != ownerId ||
        await _db.storeRepository.tryGet(StoreKey.serverEndpoint) != endpoint) {
      throw StateError('The active account changed while importing the edited copy');
    }
    _checkActive();
  }

  void _checkActive() {
    if (canContinue?.call() == false) {
      throw TimeoutException('Editor copy recovery budget ended or sync was cancelled');
    }
  }

  Future<T> _nativeRequest<T>(Future<T> Function() request) async {
    _checkActive();
    final remaining = remainingBudget?.call();
    final timeout = remaining != null && remaining < nativeTimeout ? remaining : nativeTimeout;
    if (timeout <= Duration.zero) {
      throw TimeoutException('Editor copy recovery budget ended');
    }
    return await request().timeout(timeout);
  }

  Future<void> _import(AssetEntity saved) async {
    if (importPlatformCopy case final fallback?) {
      // Preserve the existing non-Android save path: Darwin has no Android
      // RELATIVE_PATH or MediaStore bucket to validate.
      await _checkAccount();
      await fallback(saved);
      return;
    }
    if (saved.id.isEmpty) {
      throw StateError('The saved copy has no MediaStore identifier');
    }
    await recordSavedCopy(saved);
    await _checkAccount();
    Object? lastError;
    StackTrace? lastStack;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (attempt > 0) {
        await _delay(Duration(milliseconds: attempt * 150));
      }
      try {
        await _checkAccount();
        final fresh = await _nativeRequest(() => _readFresh(saved));
        if (fresh == null) {
          throw StateError('MediaStore has not returned the saved copy yet');
        }
        await _importFresh(saved, fresh);
        await (_db.delete(_db.settingsEntity)..where((row) => row.key.equals(_key(saved.id)))).go();
        final wake = onImported;
        if (wake != null) {
          unawaited(
            wake().catchError((Object error, StackTrace stack) {
              _log.warning('Edited copy is indexed; normal backup will retry later', error, stack);
            }),
          );
        }
        return;
      } catch (error, stack) {
        lastError = error;
        lastStack = stack;
        _log.warning('Unable to index saved editor copy ${saved.id} (attempt ${attempt + 1})', error, stack);
      }
    }
    Error.throwWithStackTrace(lastError!, lastStack!);
  }

  Future<void> _importFresh(AssetEntity saved, AssetEntity fresh) async {
    final name = fresh.title;
    final created = fresh.createDateSecond;
    if (fresh.id != saved.id ||
        fresh.typeInt != 1 ||
        name == null ||
        name.isEmpty ||
        created == null ||
        created <= 0 ||
        fresh.width <= 0 ||
        fresh.height <= 0 ||
        (saved.title != null && saved.title != name) ||
        (saved.createDateSecond != null && saved.createDateSecond != created)) {
      throw StateError('MediaStore returned incomplete or changed identity for the saved copy');
    }
    if (_normalizePath(fresh.relativePath) != outputRelativePath) {
      throw StateError('The saved copy is outside the editor output album');
    }
    // Revalidate identity before changing MIME metadata: pending IDs must never
    // modify an unrelated file if Android eventually reuses a MediaStore ID.
    await _checkAccount();
    await _nativeRequest(() => _completeMetadata(fresh));
    final album = await _findEditorAlbum(fresh);
    final createdAt = DateTime.fromMillisecondsSinceEpoch(created * 1000, isUtc: true);
    final updatedAt = DateTime.fromMillisecondsSinceEpoch((fresh.modifiedDateSecond ?? created) * 1000, isUtc: true);
    await _db.transaction(() async {
      await _checkAccount();
      final previous = await (_db.select(_db.localAssetEntity)..where((a) => a.id.equals(fresh.id))).getSingleOrNull();
      final sameRevision =
          previous != null &&
          previous.name == name &&
          previous.type == AssetType.image &&
          previous.createdAt.isAtSameMomentAs(createdAt) &&
          previous.updatedAt.isAtSameMomentAs(updatedAt);
      await _selectOutputAlbum(album);
      await _db
          .into(_db.localAssetEntity)
          .insertOnConflictUpdate(
            LocalAssetEntityCompanion.insert(
              id: fresh.id,
              name: name,
              type: AssetType.image,
              createdAt: Value(createdAt),
              updatedAt: Value(updatedAt),
              width: Value(fresh.width),
              height: Value(fresh.height),
              checksum: Value(sameRevision ? previous.checksum : null),
              orientation: Value(fresh.orientation),
              isFavorite: Value(fresh.isFavorite),
              playbackStyle: const Value(AssetPlaybackStyle.image),
            ),
          );
      await (_db.delete(_db.localAlbumAssetEntity)..where((a) => a.assetId.equals(fresh.id))).go();
      await _db
          .into(_db.localAlbumAssetEntity)
          .insert(LocalAlbumAssetEntityCompanion.insert(albumId: album.id, assetId: fresh.id));
    });
    final row = await (_db.select(_db.localAssetEntity)..where((a) => a.id.equals(fresh.id))).getSingleOrNull();
    if (row == null ||
        row.name != name ||
        !row.createdAt.isAtSameMomentAs(createdAt) ||
        !(await _db.localAlbumRepository.getAssetIds(album.id)).contains(fresh.id)) {
      throw StateError('The saved copy could not be verified in the local library');
    }
  }

  Future<void> _selectOutputAlbum(PlatformAlbum album) async {
    await _db
        .into(_db.localAlbumEntity)
        .insertOnConflictUpdate(
          LocalAlbumEntityCompanion.insert(
            id: album.id,
            name: album.name,
            backupSelection: BackupSelection.selected,
            updatedAt: Value(
              DateTime.fromMillisecondsSinceEpoch(
                album.updatedAt == null ? DateTime.now().millisecondsSinceEpoch : album.updatedAt! * 1000,
                isUtc: true,
              ),
            ),
          ),
        );
  }

  Future<PlatformAlbum> _findEditorAlbum(AssetEntity asset) async {
    final albums = await _nativeRequest(_native.getAlbums);
    final matches = <PlatformAlbum>[];
    for (final album in albums.where((a) => a.name == 'Noodle Gallery' && !a.isCloud)) {
      if ((await _nativeRequest(() => _native.getAssetIdsForAlbum(album.id))).contains(asset.id)) {
        matches.add(album);
      }
    }
    if (matches.length != 1) {
      throw StateError('The saved copy does not have one verified editor output album');
    }
    return matches.single;
  }

  static String? _normalizePath(String? path) => path?.replaceAll(RegExp(r'^/+|/+$'), '');
}
