import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/table/local/asset.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/trashed_local_asset.repository.dart';
import 'package:immich_mobile/services/cleanup.service.dart';
import 'package:mocktail/mocktail.dart';

import '../infrastructure/repository.mock.dart';
import '../medium/repository_context.dart';
import '../repository.mocks.dart';

void main() {
  late CleanupService sut;

  late MockLocalAssetRepository localAssetRepository;
  late MockAssetMediaRepository assetMediaRepository;
  late MockTrashedLocalAssetRepository trashedLocalAssetRepository;

  setUp(() {
    localAssetRepository = MockLocalAssetRepository();
    assetMediaRepository = MockAssetMediaRepository();
    trashedLocalAssetRepository = MockTrashedLocalAssetRepository();
    when(() => trashedLocalAssetRepository.deleteAssets(any())).thenAnswer((_) async {});
    sut = CleanupService(
      localAssetRepository,
      assetMediaRepository,
      trashedLocalRepository: trashedLocalAssetRepository,
    );
  });

  group('CleanupService.deleteLocalAssets', () {
    test('returns 0 and does nothing for empty input', () async {
      final result = await sut.deleteLocalAssets([]);

      expect(result, 0);
      verifyNever(() => assetMediaRepository.deleteAll(any()));
      verifyNever(() => localAssetRepository.deleteAssets(any()));
    });

    test('deletes in a single batch when under limit', () async {
      final ids = List.generate(999, (i) => 'asset-$i');

      when(() => assetMediaRepository.deleteAll(any())).thenAnswer((invocation) async {
        return (invocation.positionalArguments.first as List<String>).toList();
      });
      when(() => localAssetRepository.deleteAssets(any())).thenAnswer((_) async {});

      final result = await sut.deleteLocalAssets(ids);

      expect(result, ids.length);
      verify(() => assetMediaRepository.deleteAll(ids)).called(1);
      verify(() => localAssetRepository.deleteAssets(ids)).called(1);
    });

    test('deletes in platform-specific batches when over limit', () async {
      final batchSize = CurrentPlatform.isAndroid ? 2000 : 10000;
      final ids = List.generate(batchSize * 2 + 501, (i) => 'asset-$i');
      final capturedBatches = <List<String>>[];

      when(() => assetMediaRepository.deleteAll(any())).thenAnswer((invocation) async {
        final batch = (invocation.positionalArguments.first as List<String>).toList();
        capturedBatches.add(batch);
        return batch;
      });
      when(() => localAssetRepository.deleteAssets(any())).thenAnswer((_) async {});

      final result = await sut.deleteLocalAssets(ids);

      expect(result, ids.length);
      expect(capturedBatches.length, 3);
      expect(capturedBatches[0].length, batchSize);
      expect(capturedBatches[1].length, batchSize);
      expect(capturedBatches[2].length, 501);
      expect(capturedBatches[0].first, 'asset-0');
      expect(capturedBatches[0].last, 'asset-${batchSize - 1}');
      expect(capturedBatches[1].first, 'asset-$batchSize');
      expect(capturedBatches[1].last, 'asset-${batchSize * 2 - 1}');
      expect(capturedBatches[2].first, 'asset-${batchSize * 2}');
      expect(capturedBatches[2].last, 'asset-${batchSize * 2 + 500}');
      verify(() => localAssetRepository.deleteAssets(any())).called(3);
    });
    test('OS denial leaves every device copy and local row intact', () async {
      when(() => assetMediaRepository.deleteAll(any())).thenAnswer((_) async => []);
      final result = await sut.deleteLocalAssetsDetailed(['photo', 'video']);
      expect(result.deletedIds, isEmpty);
      expect(result.remainingIds, ['photo', 'video']);
      verifyNever(() => localAssetRepository.deleteAssets(any()));
    });

    test('reports partial OS acknowledgement and ignores unrelated/duplicate IDs', () async {
      when(() => assetMediaRepository.deleteAll(any())).thenAnswer((_) async => ['photo', 'photo', 'unrelated']);
      when(() => localAssetRepository.deleteAssets(any())).thenAnswer((_) async {});
      final result = await sut.deleteLocalAssetsDetailed(['photo', 'video', 'photo']);
      expect(result.deletedIds, ['photo']);
      expect(result.remainingIds, ['video']);
      verify(() => localAssetRepository.deleteAssets(['photo'])).called(1);
    });

    test('one failed OS batch does not hide results from the following batch', () async {
      final size = CurrentPlatform.isAndroid ? 2000 : 10000;
      final ids = List.generate(size + 1, (index) => 'id-$index');
      var batch = 0;
      when(() => assetMediaRepository.deleteAll(any())).thenAnswer((call) async {
        if (batch++ == 0) {
          throw StateError('OS denied this batch');
        }
        return call.positionalArguments.first as List<String>;
      });
      when(() => localAssetRepository.deleteAssets(any())).thenAnswer((_) async {});
      final result = await sut.deleteLocalAssetsDetailed(ids);
      expect(result.deletedIds, [ids.last]);
      expect(result.remainingIds, ids.take(size));
    });
    test('permanent device cleanup uses the authorized OS delete API rather than moving to device Trash', () async {
      when(() => assetMediaRepository.deleteAll(['photo'], trash: false)).thenAnswer((_) async => ['photo']);
      when(() => localAssetRepository.deleteAssets(any())).thenAnswer((_) async {});
      final result = await sut.deleteLocalAssetsDetailed(['photo'], trash: false);
      expect(result.deletedIds, ['photo']);
      verify(() => assetMediaRepository.deleteAll(['photo'], trash: false)).called(1);
      verifyNever(() => assetMediaRepository.deleteAll(['photo'], trash: true));
      verify(() => trashedLocalAssetRepository.deleteAssets(['photo'])).called(1);
    });

    test('denied permanent cleanup preserves both active and device Trash cache rows', () async {
      when(() => assetMediaRepository.deleteAll(any(), trash: false)).thenAnswer((_) async => []);
      final result = await sut.deleteLocalAssetsDetailed(['photo', 'video'], trash: false);
      expect(result.deletedIds, isEmpty);
      expect(result.remainingIds, ['photo', 'video']);
      verifyNever(() => localAssetRepository.deleteAssets(any()));
      verifyNever(() => trashedLocalAssetRepository.deleteAssets(any()));
    });

    test('partial permanent cleanup removes only OS-acknowledged active and device Trash identities', () async {
      when(
        () => assetMediaRepository.deleteAll(any(), trash: false),
      ).thenAnswer((_) async => ['photo', 'photo', 'unrelated']);
      when(() => localAssetRepository.deleteAssets(any())).thenAnswer((_) async {});
      final result = await sut.deleteLocalAssetsDetailed(['photo', 'video'], trash: false);
      expect(result.deletedIds, ['photo']);
      expect(result.remainingIds, ['video']);
      verify(() => localAssetRepository.deleteAssets(['photo'])).called(1);
      verify(() => trashedLocalAssetRepository.deleteAssets(['photo'])).called(1);
    });

    test('a device Trash cache failure is visible rather than reported as completed cleanup', () async {
      when(() => assetMediaRepository.deleteAll(any(), trash: false)).thenAnswer((_) async => ['photo']);
      when(() => localAssetRepository.deleteAssets(any())).thenAnswer((_) async {});
      when(() => trashedLocalAssetRepository.deleteAssets(any())).thenThrow(StateError('fixture cache failure'));
      await expectLater(sut.deleteLocalAssetsDetailed(['photo'], trash: false), throwsStateError);
    });

    test('ordinary device Trash operations do not discard the separate device Trash cache', () async {
      when(() => assetMediaRepository.deleteAll(any())).thenAnswer((_) async => ['photo']);
      when(() => localAssetRepository.deleteAssets(any())).thenAnswer((_) async {});
      expect((await sut.deleteLocalAssetsDetailed(['photo'])).deletedIds, ['photo']);
      verifyNever(() => trashedLocalAssetRepository.deleteAssets(any()));
    });

    test(
      'confirmed retry survives OS denial and stops selecting active and device Trash copies after success',
      () async {
        final ctx = MediumRepositoryContext();
        addTearDown(ctx.dispose);
        await ctx.newUser(id: 'owner');
        await ctx.newAuthUser(id: 'owner');
        final cloud = await ctx.newRemoteAsset(id: 'cloud', ownerId: 'owner');
        final active = await ctx.newLocalAsset(id: 'active-copy', checksum: cloud.checksum);
        final deviceTrash = await ctx.newLocalAsset(id: 'trashed-copy', checksum: cloud.checksum);
        final album = await ctx.newLocalAlbum(id: 'device-album');
        final remote = RemoteAssetRepository(ctx.db);
        final trashed = TrashedLocalAssetRepository(ctx.db);
        await remote.trash(['cloud']);
        await trashed.trashLocalAsset({
          album.id: [deviceTrash.toDto()],
        });
        final snapshots = await remote.beginPermanentDeletion(['cloud']);
        await remote.completePermanentDeletion(snapshots, ['cloud'], ['cloud']);
        final cleanup = CleanupService(
          LocalAssetRepository(ctx.db),
          assetMediaRepository,
          trashedLocalRepository: trashed,
        );
        expect(await remote.get('cloud'), isNull);
        expect(await remote.getPendingDeviceDeletionAssetIds('owner'), ['cloud']);
        final copies = await remote.getDeletionLocalIds(['cloud']);
        expect(copies, unorderedEquals([active.id, deviceTrash.id]));
        when(() => assetMediaRepository.deleteAll(any(), trash: false)).thenAnswer((_) async => []);
        expect((await cleanup.deleteLocalAssetsDetailed(copies, trash: false)).remainingIds, unorderedEquals(copies));
        expect(await remote.getPendingDeviceDeletionAssetIds('owner'), ['cloud']);
        when(
          () => assetMediaRepository.deleteAll(any(), trash: false),
        ).thenAnswer((call) async => call.positionalArguments.first as List<String>);
        expect((await cleanup.deleteLocalAssetsDetailed(copies, trash: false)).deletedIds, unorderedEquals(copies));
        expect(await remote.getPendingDeviceDeletionAssetIds('owner'), isEmpty);
        expect(await remote.getDeletionLocalIds(['cloud']), isEmpty);
        // Completion remains durable; cleanup does not restore the cloud row.
        expect(await remote.get('cloud'), isNull);
      },
    );
  });
}
