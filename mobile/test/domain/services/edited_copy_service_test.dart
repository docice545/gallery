import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/app/settings.drift.dart';
import 'package:immich_mobile/data/db/main/table/local/asset.drift.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/domain/services/edited_copy.service.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline.repository.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:photo_manager/photo_manager.dart' hide AssetType;

class _Native extends NativeSyncApi {
  List<PlatformAlbum> albums = [
    PlatformAlbum(id: 'editor', name: 'Noodle Gallery', isCloud: false, assetCount: 1),
    PlatformAlbum(id: 'collision', name: 'Noodle Gallery', isCloud: false, assetCount: 1),
    PlatformAlbum(id: 'camera', name: 'Camera', isCloud: false, assetCount: 1),
  ];
  Map<String, List<String>> members = {
    'editor': ['copy'],
    'collision': ['other'],
    'camera': ['original'],
  };
  final List<String> requestedAlbums = [];

  @override
  Future<List<PlatformAlbum>> getAlbums() async => albums;

  @override
  Future<List<String>> getAssetIdsForAlbum(String albumId) async {
    requestedAlbums.add(albumId);
    return members[albumId] ?? [];
  }
}

void main() {
  const endpoint = 'https://example.invalid/api';
  late Drift db;
  late _Native native;
  late EditedCopyService service;
  final createdAt = DateTime.utc(2026, 11, 2, 13);
  AssetEntity copy({String id = 'copy', String path = 'DCIM/Noodle Gallery/', String? name, int width = 1200}) =>
      AssetEntity(
        id: id,
        typeInt: 1,
        width: width,
        height: 1600,
        title: name ?? 'gallery-edit-1793624400000.png',
        relativePath: path,
        createDateSecond: createdAt.millisecondsSinceEpoch ~/ 1000,
        modifiedDateSecond: createdAt.millisecondsSinceEpoch ~/ 1000,
      );

  Future<void> setAccount(String owner, {String server = endpoint}) async {
    await db.storeRepository.upsert(
      StoreKey.currentUser,
      UserDto(id: owner, name: owner, email: '$owner@test.invalid', profileChangedAt: createdAt),
    );
    await db.storeRepository.upsert(StoreKey.serverEndpoint, server);
  }

  Future<void> addAlbum(String id, String name, BackupSelection selection) =>
      db.localAlbumRepository.upsert(LocalAlbum(id: id, name: name, updatedAt: createdAt, backupSelection: selection));

  Future<List<String>> timelineIds() async => (await TimelineRepository(
    db,
  ).main(['owner'], 'owner', GroupAssetsBy.day).assetSource(0, 100)).map((a) => a.id).toList();

  Future<List<String>> candidates() async =>
      (await db.backupRepository.getCandidates('owner', onlyHashed: false)).map((a) => a.id).toList();

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await initializeDateFormatting('en_US');
  });
  setUp(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    native = _Native();
    await setAccount('owner');
    service = EditedCopyService(
      db,
      native,
      ownerId: 'owner',
      endpoint: endpoint,
      readFresh: (_) async => copy(),
      completeMetadata: (_) async {},
      delay: (_) async {},
    );
  });
  tearDown(() async => db.close());

  test('targeted import selects only proven output album and updates the real reactive Photos timeline', () async {
    native.albums.first.updatedAt = createdAt.millisecondsSinceEpoch ~/ 1000;
    await addAlbum('camera', 'Camera', BackupSelection.excluded);
    await addAlbum('screenshots', 'Screenshots', BackupSelection.none);
    await addAlbum('collision', 'Noodle Gallery', BackupSelection.none);
    final initial = Completer<List<Bucket>>();
    final populated = Completer<List<Bucket>>();
    final subscription = TimelineRepository(db).main(['owner'], 'owner', GroupAssetsBy.day).bucketSource().listen((
      buckets,
    ) {
      if (!initial.isCompleted) {
        initial.complete(buckets);
      }
      if (buckets.isNotEmpty && !populated.isCompleted) {
        populated.complete(buckets);
      }
    });
    addTearDown(subscription.cancel);
    expect(await initial.future.timeout(const Duration(seconds: 2)), isEmpty);
    await service.importSavedCopy(copy()).timeout(const Duration(seconds: 2));
    expect((await populated.future.timeout(const Duration(seconds: 2))).single.assetCount, 1);
    await subscription.cancel();
    expect(await timelineIds(), ['copy']);
    expect(await candidates(), ['copy']);
    final albums = {for (final album in await db.localAlbumRepository.getAll()) album.id: album.backupSelection};
    expect(albums, {
      'camera': BackupSelection.excluded,
      'screenshots': BackupSelection.none,
      'collision': BackupSelection.none,
      'editor': BackupSelection.selected,
    });
    final outputAlbum = (await db.localAlbumRepository.getAll()).singleWhere((album) => album.id == 'editor');
    expect(outputAlbum.updatedAt, createdAt, reason: 'Native album timestamps use epoch seconds');
    expect(await db.localAlbumRepository.getAssetIds('editor'), ['copy']);
    expect(native.requestedAlbums, isNot(contains('camera')));
    expect(await db.select(db.settingsEntity).get(), isEmpty);
  });

  test('an explicitly excluded output album alone becomes selected, as requested by editor-copy policy', () async {
    await addAlbum('editor', 'Noodle Gallery', BackupSelection.excluded);
    await addAlbum('camera', 'Camera', BackupSelection.selected);
    await service.importSavedCopy(copy());
    expect(await timelineIds(), ['copy']);
    expect((await db.localAlbumRepository.getBackupAlbums()).map((a) => a.id), containsAll(['editor', 'camera']));
  });

  test('repeating import and later ordinary MediaStore sync keep one file identity and one timeline tile', () async {
    await service.importSavedCopy(copy());
    await service.importSavedCopy(copy());
    final local = (await db.localAlbumRepository.getAssets('editor')).single;
    await db.localAlbumRepository.processDelta(
      updates: [local],
      deletes: [],
      assetAlbums: {
        'copy': ['editor'],
      },
    );
    expect(await db.select(db.localAssetEntity).get(), hasLength(1));
    expect(await timelineIds(), ['copy']);
    expect(await candidates(), ['copy']);
  });

  test('same-second indexing correction updates dimensions without losing verified checksum', () async {
    await service.importSavedCopy(copy());
    await (db.update(db.localAssetEntity)..where((a) => a.id.equals('copy'))).write(
      const LocalAssetEntityCompanion(width: Value(0), checksum: Value('known-content')),
    );
    await service.importSavedCopy(copy());
    final row = (await db.select(db.localAssetEntity).get()).single;
    expect(row.width, 1200);
    expect(row.checksum, 'known-content');
  });

  test('changed cached identity does not carry a stale checksum to the saved copy', () async {
    await service.importSavedCopy(copy());
    await (db.update(db.localAssetEntity)..where((a) => a.id.equals('copy'))).write(
      const LocalAssetEntityCompanion(name: Value('old-file.png'), checksum: Value('old-content')),
    );
    await service.importSavedCopy(copy());
    expect((await db.select(db.localAssetEntity).get()).single.checksum, isNull);
  });

  test('late indexing is retried a bounded number of times without full scan', () async {
    var reads = 0;
    final delayed = EditedCopyService(
      db,
      native,
      ownerId: 'owner',
      endpoint: endpoint,
      readFresh: (_) async => ++reads < 3 ? null : copy(),
      completeMetadata: (_) async {},
      delay: (_) async {},
    );
    await delayed.importSavedCopy(copy());
    expect(reads, 3);
    expect(await timelineIds(), ['copy']);
  });

  test('a newly created row with unset date and path imports after fresh indexing', () async {
    final pending = copy().copyWith(createDateSecond: 0, relativePath: '');
    await service.importSavedCopy(pending);
    expect(await timelineIds(), ['copy']);
    expect((await db.select(db.localAssetEntity).get()).single.createdAt, createdAt);
    expect(await db.select(db.settingsEntity).get(), isEmpty);
  });

  test('failed native read retains durable ID without enabling an unverified album', () async {
    var reads = 0;
    final failed = EditedCopyService(
      db,
      native,
      ownerId: 'owner',
      endpoint: endpoint,
      readFresh: (_) async {
        reads++;
        throw PlatformException(code: 'READ_FAILED');
      },
      completeMetadata: (_) async {},
      delay: (_) async {},
    );
    await expectLater(failed.importSavedCopy(copy()), throwsA(isA<PlatformException>()));
    expect(reads, 3);
    expect(await db.select(db.localAssetEntity).get(), isEmpty);
    expect(await db.localAlbumRepository.getBackupAlbums(), isEmpty);
    final pending = (await db.select(db.settingsEntity).get()).single;
    expect((jsonDecode(pending.value!) as Map)['id'], 'copy');
    await EditedCopyService.recoverPendingCopies(
      db,
      native,
      readFresh: (_) async => copy(),
      completeMetadata: (_) async {},
      delay: (_) async {},
    );
    expect(await timelineIds(), ['copy']);
    expect(await db.select(db.settingsEntity).get(), isEmpty);
  });

  test('pending MIME completion survives importer recreation without creating or deleting media', () async {
    var repairs = 0;
    final failed = EditedCopyService(
      db,
      native,
      ownerId: 'owner',
      endpoint: endpoint,
      readFresh: (_) async => copy(),
      completeMetadata: (_) async {
        repairs++;
        throw StateError('native MIME pending');
      },
      delay: (_) async {},
    );
    await expectLater(failed.importSavedCopy(copy()), throwsStateError);
    expect(repairs, 3);
    expect(await db.select(db.localAssetEntity).get(), isEmpty);
    expect(await db.select(db.settingsEntity).get(), hasLength(1));
    await EditedCopyService.recoverPendingCopies(
      db,
      native,
      readFresh: (_) async => copy(),
      completeMetadata: (_) async {
        repairs++;
      },
      delay: (_) async {},
    );
    expect(repairs, 4);
    expect(await timelineIds(), ['copy']);
  });

  test('a folder sharing the output name cannot be enabled when relative path differs', () async {
    final wrong = copy(path: 'Pictures/Noodle Gallery');
    final importer = EditedCopyService(
      db,
      native,
      ownerId: 'owner',
      endpoint: endpoint,
      readFresh: (_) async => wrong,
      completeMetadata: (_) async {},
      delay: (_) async {},
    );
    await expectLater(importer.importSavedCopy(wrong), throwsStateError);
    expect(await db.localAlbumRepository.getBackupAlbums(), isEmpty);
    expect(await timelineIds(), isEmpty);
  });

  test('ambiguous album membership never enables a namesake bucket', () async {
    native.members['collision'] = ['copy'];
    await expectLater(service.importSavedCopy(copy()), throwsStateError);
    expect(await db.localAlbumRepository.getBackupAlbums(), isEmpty);
    expect(await db.select(db.localAssetEntity).get(), isEmpty);
  });

  test('ID reuse in a namesake folder fails before MIME mutation or automatic album selection', () async {
    native.members['editor'] = [];
    native.members['collision'] = ['copy'];
    var metadataWrites = 0;
    final importer = EditedCopyService(
      db,
      native,
      ownerId: 'owner',
      endpoint: endpoint,
      readFresh: (_) async => copy(name: 'unrelated.png'),
      completeMetadata: (_) async {
        metadataWrites++;
      },
      delay: (_) async {},
    );
    await expectLater(importer.importSavedCopy(copy()), throwsStateError);
    expect(metadataWrites, 0);
    expect(await db.localAlbumRepository.getBackupAlbums(), isEmpty);
    expect(await db.select(db.localAssetEntity).get(), isEmpty);
  });

  test('missing editor filename cannot mutate MediaStore or create a pending identity', () async {
    var reads = 0;
    var metadataWrites = 0;
    final importer = EditedCopyService(
      db,
      native,
      ownerId: 'owner',
      endpoint: endpoint,
      readFresh: (_) async {
        reads++;
        return copy();
      },
      completeMetadata: (_) async {
        metadataWrites++;
      },
      delay: (_) async {},
    );
    final unidentified = AssetEntity(
      id: 'copy',
      typeInt: 1,
      width: 1200,
      height: 1600,
      relativePath: 'DCIM/Noodle Gallery',
    );
    await expectLater(importer.importSavedCopy(unidentified), throwsStateError);
    expect(reads, 0);
    expect(metadataWrites, 0);
    expect(await db.select(db.settingsEntity).get(), isEmpty);
    expect(await db.select(db.localAssetEntity).get(), isEmpty);
  });

  test('hanging native reads stop after bounded attempts and retain the saved ID', () async {
    var reads = 0;
    final nativeRead = Completer<AssetEntity?>();
    final importer = EditedCopyService(
      db,
      native,
      ownerId: 'owner',
      endpoint: endpoint,
      nativeTimeout: const Duration(milliseconds: 10),
      readFresh: (_) {
        reads++;
        return nativeRead.future;
      },
      completeMetadata: (_) async {},
      delay: (_) async {},
    );
    await expectLater(
      importer.importSavedCopy(copy()).timeout(const Duration(seconds: 2)),
      throwsA(isA<TimeoutException>()),
    );
    expect(reads, 3);
    final pending = (await db.select(db.settingsEntity).get()).single;
    expect((jsonDecode(pending.value!) as Map)['id'], 'copy');
    expect(await db.select(db.localAssetEntity).get(), isEmpty);
  });

  test('recovery rotates persistent failures so the eleventh pending copy can finish on the next sync', () async {
    final saved = [
      for (var i = 0; i < 11; i++)
        copy(id: 'copy-${i.toString().padLeft(2, '0')}', name: 'gallery-edit-${1793624400000 + i}.png'),
    ];
    native.members['editor'] = saved.map((asset) => asset.id).toList();
    for (final asset in saved) {
      await service.recordSavedCopy(asset);
    }
    // Fixed historical attempt times keep scheduling assertions independent of
    // the host clock's millisecond resolution and SQLite execution speed.
    final pending = await db.select(db.settingsEntity).get();
    for (var i = 0; i < pending.length; i++) {
      final row = pending[i];
      final data = jsonDecode(row.value!) as Map<String, dynamic>;
      data['lastAttemptAt'] = saved.indexWhere((asset) => asset.id == data['id']);
      await (db.update(
        db.settingsEntity,
      )..where((entry) => entry.key.equals(row.key))).write(SettingsEntityCompanion(value: Value(jsonEncode(data))));
    }
    final reads = <String>[];
    Future<AssetEntity?> readFresh(AssetEntity asset) async {
      reads.add(asset.id);
      if (asset.id != saved.last.id) {
        throw StateError('synthetic persistent native failure');
      }
      return saved.last;
    }

    await EditedCopyService.recoverPendingCopies(
      db,
      native,
      readFresh: readFresh,
      completeMetadata: (_) async {},
      delay: (_) async {},
    );
    expect(reads, isNot(contains(saved.last.id)));
    expect(await db.select(db.settingsEntity).get(), hasLength(11));
    reads.clear();
    await EditedCopyService.recoverPendingCopies(
      db,
      native,
      readFresh: readFresh,
      completeMetadata: (_) async {},
      delay: (_) async {},
    );
    expect(reads, contains(saved.last.id));
    expect(await timelineIds(), [saved.last.id]);
    expect(await db.select(db.settingsEntity).get(), hasLength(10));
  });

  test('pending copies remain isolated from another account and another server', () async {
    await service.recordSavedCopy(copy());
    var reads = 0;
    await setAccount('different');
    await EditedCopyService.recoverPendingCopies(
      db,
      native,
      readFresh: (_) async {
        reads++;
        return copy();
      },
      completeMetadata: (_) async {},
      delay: (_) async {},
    );
    expect(reads, 0);
    await setAccount('owner', server: 'https://different.invalid/api');
    await EditedCopyService.recoverPendingCopies(
      db,
      native,
      readFresh: (_) async {
        reads++;
        return copy();
      },
      completeMetadata: (_) async {},
      delay: (_) async {},
    );
    expect(reads, 0);
    expect(await db.select(db.settingsEntity).get(), hasLength(1));
    await expectLater(service.importSavedCopy(copy()), throwsStateError);
    expect(await db.localAlbumRepository.getAll(), isEmpty);
  });

  test('late native save is journaled under its captured account and recovered only after returning to it', () async {
    var reads = 0;
    var metadataWrites = 0;
    final captured = EditedCopyService(
      db,
      native,
      ownerId: 'owner',
      endpoint: endpoint,
      readFresh: (_) async {
        reads++;
        return copy();
      },
      completeMetadata: (_) async {
        metadataWrites++;
      },
      delay: (_) async {},
    );
    await setAccount('different');
    await expectLater(captured.importSavedCopy(copy()), throwsStateError);
    final row = (await db.select(db.settingsEntity).get()).single;
    expect(jsonDecode(row.value!), containsPair('ownerId', 'owner'));
    expect(reads, 0);
    expect(metadataWrites, 0);
    await EditedCopyService.recoverPendingCopies(
      db,
      native,
      readFresh: (_) async {
        reads++;
        return copy();
      },
      completeMetadata: (_) async {
        metadataWrites++;
      },
    );
    expect(reads, 0);
    expect(await db.select(db.localAssetEntity).get(), isEmpty);
    await setAccount('owner');
    await EditedCopyService.recoverPendingCopies(
      db,
      native,
      readFresh: (_) async {
        reads++;
        return copy();
      },
      completeMetadata: (_) async {
        metadataWrites++;
      },
    );
    expect(reads, 1);
    expect(metadataWrites, 1);
    expect(await timelineIds(), ['copy']);
    expect(await db.select(db.settingsEntity).get(), isEmpty);
  });

  test('Darwin fallback imports the returned copy without Android path or MediaStore requirements', () async {
    final imported = <AssetEntity>[];
    var reads = 0;
    var metadataWrites = 0;
    final importer = EditedCopyService(
      db,
      native,
      ownerId: 'owner',
      endpoint: endpoint,
      importPlatformCopy: (asset) async => imported.add(asset),
      readFresh: (_) async {
        reads++;
        return copy();
      },
      completeMetadata: (_) async {
        metadataWrites++;
      },
    );
    final darwinCopy = AssetEntity(id: 'photos-library-copy', typeInt: 1, width: 1200, height: 1600);
    await importer.importSavedCopy(darwinCopy);
    expect(imported, [darwinCopy]);
    expect(reads, 0);
    expect(metadataWrites, 0);
    expect(native.requestedAlbums, isEmpty);
    expect(await db.select(db.settingsEntity).get(), isEmpty);
    expect(await db.localAlbumRepository.getAll(), isEmpty);
  });

  test('recovery respects a total budget and late native results cannot mutate metadata or Drift', () async {
    final first = copy();
    final second = copy(id: 'copy-next', name: 'gallery-edit-1793624400001.png');
    native.members['editor'] = [first.id, second.id];
    await service.recordSavedCopy(first);
    await service.recordSavedCopy(second);
    final blocked = Completer<AssetEntity?>();
    var reads = 0;
    var metadataWrites = 0;
    final clock = Stopwatch()..start();
    await EditedCopyService.recoverPendingCopies(
      db,
      native,
      budget: const Duration(milliseconds: 30),
      nativeTimeout: const Duration(seconds: 5),
      readFresh: (_) {
        reads++;
        return blocked.future;
      },
      completeMetadata: (_) async {
        metadataWrites++;
      },
    ).timeout(const Duration(seconds: 1));
    clock.stop();
    expect(clock.elapsed, lessThan(const Duration(milliseconds: 500)));
    expect(reads, 1);
    expect(metadataWrites, 0);
    expect(await db.select(db.settingsEntity).get(), hasLength(2));
    blocked.complete(first);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(metadataWrites, 0);
    expect(await db.select(db.localAssetEntity).get(), isEmpty);
  });

  test('cancelling recovery during a native read prevents metadata and database import afterwards', () async {
    await service.recordSavedCopy(copy());
    final started = Completer<void>();
    final blocked = Completer<AssetEntity?>();
    var cancelled = false;
    var metadataWrites = 0;
    final recovery = EditedCopyService.recoverPendingCopies(
      db,
      native,
      isCancelled: () => cancelled,
      readFresh: (_) {
        started.complete();
        return blocked.future;
      },
      completeMetadata: (_) async {
        metadataWrites++;
      },
    );
    await started.future.timeout(const Duration(seconds: 1));
    cancelled = true;
    blocked.complete(copy());
    await recovery.timeout(const Duration(seconds: 1));
    expect(metadataWrites, 0);
    expect(await db.select(db.localAssetEntity).get(), isEmpty);
    expect(await db.select(db.settingsEntity).get(), hasLength(1));
  });

  test('permanent deletion suppression still wins over the selected output album', () async {
    await db
        .into(db.settingsEntity)
        .insert(
          SettingsEntityCompanion.insert(
            key: 'sync.trash-reset.synthetic',
            value: Value(
              jsonEncode({
                'ownerId': 'owner',
                'endpoint': endpoint,
                'checksum': 'removed-content',
                'localIds': ['copy'],
              }),
            ),
          ),
        );
    await service.importSavedCopy(copy());
    expect(await timelineIds(), isEmpty);
    expect(await candidates(), isEmpty);
  });

  test('backup wake is asynchronous and its network failure cannot turn local import into save failure', () async {
    final backup = Completer<void>();
    var wakes = 0;
    final importer = EditedCopyService(
      db,
      native,
      ownerId: 'owner',
      endpoint: endpoint,
      readFresh: (_) async => copy(),
      completeMetadata: (_) async {},
      delay: (_) async {},
      onImported: () {
        wakes++;
        return backup.future;
      },
    );
    await importer.importSavedCopy(copy()).timeout(const Duration(seconds: 2));
    expect(await timelineIds(), ['copy']);
    expect(wakes, 1);
    backup.completeError(StateError('server offline'));
    await Future<void>.delayed(Duration.zero);
    expect(await timelineIds(), ['copy']);
  });

  test('concurrent retry for one saved ID joins the same import', () async {
    final metadata = Completer<AssetEntity?>();
    var reads = 0;
    final importer = EditedCopyService(
      db,
      native,
      ownerId: 'owner',
      endpoint: endpoint,
      readFresh: (_) {
        reads++;
        return metadata.future;
      },
      completeMetadata: (_) async {},
      delay: (_) async {},
    );
    final first = importer.importSavedCopy(copy());
    final retry = importer.importSavedCopy(copy());
    metadata.complete(copy());
    await Future.wait([first, retry]);
    expect(reads, 1);
    expect(await db.select(db.localAssetEntity).get(), hasLength(1));
  });
}
