import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/services/cleanup.service.dart';
import 'package:mocktail/mocktail.dart';

import '../infrastructure/repository.mock.dart';
import '../repository.mocks.dart';

void main() {
  late CleanupService sut;

  late MockLocalAssetRepository localAssetRepository;
  late MockAssetMediaRepository assetMediaRepository;

  setUp(() {
    localAssetRepository = MockLocalAssetRepository();
    assetMediaRepository = MockAssetMediaRepository();
    sut = CleanupService(localAssetRepository, assetMediaRepository);
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
    });
  });
}
