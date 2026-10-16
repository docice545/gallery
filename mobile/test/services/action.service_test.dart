import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/deletion_result.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/sync_stream.repository.dart';
import 'package:immich_mobile/repositories/shared_space_api.repository.dart';
import 'package:immich_mobile/services/action.service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart' show ApiException;

import '../infrastructure/repository.mock.dart';
import '../repository.mocks.dart';

class MockSharedSpaceApiRepository extends Mock implements SharedSpaceApiRepository {}

void main() {
  late ActionService sut;

  late MockAssetApiRepository assetApiRepository;
  late MockRemoteAssetRepository remoteAssetRepository;
  late MockSharedSpaceApiRepository sharedSpaceApiRepository;
  late MockAlbumApiRepository albumApiRepository;
  late MockRemoteAlbumRepository remoteAlbumRepository;

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
    assetApiRepository = MockAssetApiRepository();
    remoteAssetRepository = MockRemoteAssetRepository();
    sharedSpaceApiRepository = MockSharedSpaceApiRepository();
    albumApiRepository = MockAlbumApiRepository();
    remoteAlbumRepository = MockRemoteAlbumRepository();

    sut = ActionService(
      assetApiRepository,
      remoteAssetRepository,
      sharedSpaceApiRepository,
      albumApiRepository,
      remoteAlbumRepository,
    );
  });

  tearDown(() async {
    await Store.clear();
  });

  group('ActionService.updateRating', () {
    const assetId = 'asset_id_1';

    test('calls both repositories with the given rating', () async {
      when(() => assetApiRepository.updateRating(assetId, 3)).thenAnswer((_) async {});
      when(() => remoteAssetRepository.updateRating(assetId, 3)).thenAnswer((_) async {});

      final result = await sut.updateRating(assetId, 3);

      expect(result, isTrue);
      verify(() => assetApiRepository.updateRating(assetId, 3)).called(1);
      verify(() => remoteAssetRepository.updateRating(assetId, 3)).called(1);
    });

    test('calls both repositories with null to clear rating', () async {
      when(() => assetApiRepository.updateRating(assetId, null)).thenAnswer((_) async {});
      when(() => remoteAssetRepository.updateRating(assetId, null)).thenAnswer((_) async {});

      final result = await sut.updateRating(assetId, null);

      expect(result, isTrue);
      verify(() => assetApiRepository.updateRating(assetId, null)).called(1);
      verify(() => remoteAssetRepository.updateRating(assetId, null)).called(1);
    });
  });

  group('ActionService.restoreAllTrash', () {
    const ownerId = 'owner';

    test('restores local rows before the server and rolls back on failure', () async {
      final calls = <String>[];
      when(() => remoteAssetRepository.beginRestoreAllTrash(ownerId)).thenAnswer((_) async {
        calls.add('local-restore');
        return [];
      });
      when(() => assetApiRepository.restoreAllTrash()).thenAnswer((_) async {
        calls.add('server-restore');
        throw ApiException(403, 'Forbidden');
      });
      when(
        () => remoteAssetRepository.completeTrashOperation([], success: false, definiteFailure: true),
      ).thenAnswer((_) async => calls.add('local-rollback'));

      await expectLater(sut.restoreAllTrash(ownerId), throwsA(isA<ApiException>()));

      expect(calls, ['local-restore', 'server-restore', 'local-rollback']);
      verifyNever(() => remoteAssetRepository.completeTrashOperation([], success: true));
    });

    test('retains pending captured revisions after a count-only bulk Restore acknowledgement', () async {
      final calls = <String>[];
      when(() => remoteAssetRepository.beginRestoreAllTrash(ownerId)).thenAnswer((_) async {
        calls.add('local-restore');
        return [];
      });
      when(() => assetApiRepository.restoreAllTrash()).thenAnswer((_) async {
        calls.add('server-restore');
        return 2;
      });
      when(
        () => remoteAssetRepository.completeTrashOperation([], success: false),
      ).thenAnswer((_) async => calls.add('await-reconciliation'));

      await expectLater(sut.restoreAllTrash(ownerId), completion(2));

      expect(calls, ['local-restore', 'server-restore', 'await-reconciliation']);
    });
  });

  group('ActionService.emptyTrash', () {
    const ownerId = 'owner';

    test('reconciles each captured item and returns completed count', () async {
      final ids = ['done', 'failed'];
      final snapshots = <AssetTrashSnapshot>[];
      when(() => remoteAssetRepository.getTrashIds(ownerId)).thenAnswer((_) async => ids);
      when(() => remoteAssetRepository.beginPermanentDeletion(ids)).thenAnswer((_) async => snapshots);
      when(() => assetApiRepository.permanentlyDelete(ids)).thenAnswer(
        (_) async => [
          const PermanentDeletionResult(id: 'done', state: 'complete'),
          const PermanentDeletionResult(id: 'failed', state: 'failed', code: 'ORIGINAL_DELETE_FAILED'),
        ],
      );
      when(() => remoteAssetRepository.completePermanentDeletion(any(), any(), any())).thenAnswer((_) async {});
      when(() => remoteAssetRepository.completeTrashOperation(any(), success: false)).thenAnswer((_) async {});

      final result = await sut.emptyTrash(ownerId);
      expect(result, (completed: 1, remaining: 1));
      verify(() => remoteAssetRepository.getTrashIds(ownerId)).called(1);
      verify(() => remoteAssetRepository.beginPermanentDeletion(ids)).called(1);
      verify(() => remoteAssetRepository.completePermanentDeletion(any(), any(), any())).called(2);
    });

    test('does not call the count-only endpoint and leaves an empty selection alone', () async {
      when(() => remoteAssetRepository.getTrashIds(ownerId)).thenAnswer((_) async => const []);

      await expectLater(sut.emptyTrash(ownerId), completion((completed: 0, remaining: 0)));

      verifyNever(() => assetApiRepository.emptyTrash());
      verifyNever(() => remoteAssetRepository.emptyTrash(ownerId));
    });

    test('keeps uncertain receipts in ordinary Trash for reconciliation', () async {
      final ids = ['uncertain'];
      when(() => remoteAssetRepository.getTrashIds(ownerId)).thenAnswer((_) async => ids);
      when(() => remoteAssetRepository.beginPermanentDeletion(ids)).thenAnswer((_) async => const []);
      when(
        () => assetApiRepository.permanentlyDelete(ids),
      ).thenAnswer((_) async => [const PermanentDeletionResult(id: 'uncertain', state: 'uncertain')]);
      when(() => remoteAssetRepository.completeTrashOperation(any(), success: false)).thenAnswer((_) async {});

      final result = await sut.emptyTrash(ownerId);
      expect(result, (completed: 0, remaining: 1));
      verify(() => remoteAssetRepository.completeTrashOperation(any(), success: false)).called(1);
      verifyNever(() => remoteAssetRepository.completePermanentDeletion(any(), any(), any()));
    });
  });
}
