import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
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

    test('clears retained local tombstones only after the server accepts restore', () async {
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
        () => remoteAssetRepository.completeTrashOperation([], success: true),
      ).thenAnswer((_) async => calls.add('clear-retained'));

      await expectLater(sut.restoreAllTrash(ownerId), completion(2));

      expect(calls, ['local-restore', 'server-restore', 'clear-retained']);
    });
  });
}
