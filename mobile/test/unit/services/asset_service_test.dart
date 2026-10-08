import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/stack.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/asset.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:mocktail/mocktail.dart';

import '../../infrastructure/repository.mock.dart';
import '../../repository.mocks.dart';
import '../factories/remote_asset_factory.dart';
import '../mocks.dart';

void main() {
  late AssetService sut;
  late RepositoryMocks mocks;
  late MockAssetApiRepository apiRepository;
  late MockRemoteAssetRepository remoteRepository;
  late MockRemoteExifRepository exifRepository;
  late Drift db;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    db = Drift(drift.DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await StoreService.init(storeRepository: StoreRepository(db));
  });

  tearDownAll(() async {
    debugDefaultTargetPlatformOverride = null;
    await Store.clear();
    await db.close();
  });

  setUp(() {
    mocks = RepositoryMocks();
    apiRepository = mocks.assetApi.api;
    remoteRepository = mocks.remoteAsset.repo;
    exifRepository = mocks.remoteExif.repo;

    sut = AssetService(
      remoteRepository: remoteRepository,
      exifRepository: exifRepository,
      localRepository: mocks.localAsset.repo,
      apiRepository: apiRepository,
      mediaRepository: mocks.assetMedia.api,
      trashedLocalRepository: mocks.trashedAsset,
    );
  });

  tearDown(() async {
    await Store.delete(StoreKey.manageLocalMediaAndroid);
  });

  group('manual stacks', () {
    test('dissolves a two-member stack without deleting either photo', () async {
      final asset = RemoteAssetFactory.create(stackId: 'stack');
      final stack = StackResponse(id: 'stack', primaryAssetId: asset.id, assetIds: [asset.id, 'other']);
      when(() => apiRepository.getStack('stack')).thenAnswer((_) async => stack);
      when(() => apiRepository.unStack(['stack'])).thenAnswer((_) async {});
      when(() => remoteRepository.unStack(['stack'])).thenAnswer((_) async {});
      await sut.removeFromStack(asset.ownerId, asset);
      verifyInOrder([
        () => apiRepository.unStack(['stack']),
        () => remoteRepository.unStack(['stack']),
      ]);
    });

    test('changes primary on the server before removing the old cover', () async {
      final asset = RemoteAssetFactory.create(stackId: 'stack');
      final stack = StackResponse(id: 'stack', primaryAssetId: asset.id, assetIds: [asset.id, 'other', 'third']);
      final updated = stack.copyWith(primaryAssetId: 'other');
      when(() => apiRepository.getStack('stack')).thenAnswer((_) async => stack);
      when(() => apiRepository.setStackPrimary('stack', 'other')).thenAnswer((_) async => updated);
      when(() => remoteRepository.stack(asset.ownerId, updated)).thenAnswer((_) async {});
      when(() => apiRepository.removeFromStack('stack', asset.id)).thenAnswer((_) async {});
      when(() => remoteRepository.detachFromStack(asset.id)).thenAnswer((_) async {});
      await sut.removeFromStack(asset.ownerId, asset);
      verifyInOrder([
        () => apiRepository.setStackPrimary('stack', 'other'),
        () => apiRepository.removeFromStack('stack', asset.id),
        () => remoteRepository.detachFromStack(asset.id),
      ]);
    });

    test('a failed server dissolve leaves the local stack intact', () async {
      when(() => apiRepository.unStack(['stack'])).thenThrow(Exception('offline'));
      await expectLater(sut.unstack(['stack']), throwsException);
      verifyNever(() => remoteRepository.unStack(['stack']));
    });
  });

  group('AssetService.updateDateTime', () {
    const ids = ['asset_id_1'];

    test('sends the picked value to the api with its offset intact', () async {
      const picked = '2026-06-10T19:15:00.000+06:00';
      await sut.update(ids, dateTime: const .some(picked));

      verify(() => apiRepository.update(ids, dateTimeOriginal: const .some(picked))).called(1);
      verify(() => remoteRepository.updateAssets(ids, createdAt: .some(DateTime.parse(picked)))).called(1);
      verify(
        () => exifRepository.updateExif(
          ids,
          dateTimeOriginal: .some(DateTime.parse(picked)),
          timeZone: const .some('UTC+06:00'),
        ),
      ).called(1);
    });

    test('handles negative offsets', () async {
      const picked = '2026-01-05T08:00:00.000-05:30';
      await sut.update(ids, dateTime: const .some(picked));

      verify(() => remoteRepository.updateAssets(ids, createdAt: .some(DateTime.parse(picked)))).called(1);
      verify(
        () => exifRepository.updateExif(
          ids,
          dateTimeOriginal: .some(DateTime.parse(picked)),
          timeZone: const .some('UTC-05:30'),
        ),
      ).called(1);
    });

    test('writes no timezone when the value has no offset', () async {
      const picked = '2026-06-10T13:15:00.000Z';
      await sut.update(ids, dateTime: const .some(picked));

      verify(() => remoteRepository.updateAssets(ids, createdAt: .some(DateTime.parse(picked)))).called(1);
      verify(
        () => exifRepository.updateExif(ids, dateTimeOriginal: .some(DateTime.parse(picked)), timeZone: const .none()),
      ).called(1);
    });

    test('is a no-op when there are no asset ids', () async {
      await sut.update(const [], dateTime: const .some('2026-06-10T19:15:00.000+06:00'));

      verifyZeroInteractions(apiRepository);
      verifyZeroInteractions(remoteRepository);
    });
  });

  group('AssetService.deleteLocal', () {
    const ids = ['l1', 'l2'];

    test('permanently deletes local copies without trashing, even when Android trash handling is on', () async {
      await Store.put(StoreKey.manageLocalMediaAndroid, true);

      final result = await sut.deleteLocal(ids, trash: false);

      expect(result, ids.length);
      verify(() => mocks.assetMedia.api.deleteAll(ids, trash: false)).called(1);
      verify(() => mocks.localAsset.repo.deleteAssets(ids)).called(1);
      verifyNever(() => mocks.trashedAsset.applyTrashedAssets(any()));
    });
  });

  group('AssetService.trash', () {
    const ids = ['asset_id_1', 'asset_id_2'];

    test('writes the local tombstone before the server request', () async {
      final calls = <String>[];
      when(() => remoteRepository.trash(ids)).thenAnswer((_) async => calls.add('local'));
      when(() => apiRepository.delete(ids, false)).thenAnswer((_) async => calls.add('server'));

      await sut.trash(ids);

      expect(calls, ['local', 'server']);
    });

    test('keeps the local tombstone when the server request is ambiguous', () async {
      when(() => remoteRepository.trash(ids)).thenAnswer((_) async {});
      when(() => apiRepository.delete(ids, false)).thenThrow(Exception('offline'));

      await expectLater(sut.trash(ids), throwsException);

      verifyInOrder([
        () => remoteRepository.trash(ids),
        () => apiRepository.delete(ids, false),
      ]);
      verifyNever(() => remoteRepository.restoreTrash(ids));
    });
  });

  group('AssetService.restoreTrash', () {
    const ids = ['asset_id_1', 'asset_id_2'];

    test('clears the local tombstone before the server request', () async {
      final calls = <String>[];
      when(() => remoteRepository.restoreTrash(ids)).thenAnswer((_) async => calls.add('local'));
      when(() => apiRepository.restoreTrash(ids)).thenAnswer((_) async => calls.add('server'));
      when(() => remoteRepository.confirmRestoreTrash(ids)).thenAnswer((_) async => calls.add('confirm'));

      await sut.restoreTrash(ids);

      expect(calls, ['local', 'server', 'confirm']);
    });

    test('rolls back the optimistic restore while preserving the original Trash date', () async {
      when(() => remoteRepository.restoreTrash(ids)).thenAnswer((_) async {});
      when(() => apiRepository.restoreTrash(ids)).thenThrow(Exception('offline'));
      when(() => remoteRepository.rollbackRestoreTrash(ids)).thenAnswer((_) async {});

      await expectLater(sut.restoreTrash(ids), throwsException);

      verifyInOrder([
        () => remoteRepository.restoreTrash(ids),
        () => apiRepository.restoreTrash(ids),
        () => remoteRepository.rollbackRestoreTrash(ids),
      ]);
      verifyNever(() => remoteRepository.confirmRestoreTrash(ids));
    });
  });

  group('AssetService.delete', () {
    const ids = ['asset_id_1', 'asset_id_2'];

    test('waits for the server before irreversible local removal', () async {
      final calls = <String>[];
      when(() => apiRepository.delete(ids, true)).thenAnswer((_) async => calls.add('server'));
      when(() => remoteRepository.deleteAssets(ids)).thenAnswer((_) async => calls.add('local'));

      await sut.delete(ids);

      expect(calls, ['server', 'local']);
    });

    test('keeps the local row when permanent deletion fails remotely', () async {
      when(() => apiRepository.delete(ids, true)).thenThrow(Exception('offline'));

      await expectLater(sut.delete(ids), throwsException);

      verifyNever(() => remoteRepository.deleteAssets(any()));
    });
  });
}
