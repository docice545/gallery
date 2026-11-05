import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/services/cleanup.service.dart';
import 'package:mocktail/mocktail.dart';

import '../infrastructure/repository.mock.dart';
import '../repository.mocks.dart';
import '../unit/factories/local_asset_factory.dart';

void main() {
  final cutoff = DateTime(2026);
  final photo = LocalAssetFactory.create(id: 'photo', remoteId: 'server').copyWith(checksum: 'hash');
  late MockLocalAssetRepository local;
  late MockAssetMediaRepository media;
  late MockAssetApiRepository api;
  late CleanupService sut;
  late List<LocalAsset> candidates;
  var sessionCurrent = true;

  setUpAll(() {
    registerFallbackValue(photo);
    registerFallbackValue(DateTime(2026));
    registerFallbackValue(AssetKeepType.none);
  });
  setUp(() {
    local = MockLocalAssetRepository();
    media = MockAssetMediaRepository();
    api = MockAssetApiRepository();
    candidates = [photo];
    sessionCurrent = true;
    when(
      () => local.getRemovalCandidates(
        'owner',
        cutoff,
        keepMediaType: any(named: 'keepMediaType'),
        keepFavorites: any(named: 'keepFavorites'),
        keepAlbumIds: any(named: 'keepAlbumIds'),
      ),
    ).thenAnswer((_) async => RemovalCandidatesResult(assets: candidates, totalBytes: 128));
    when(
      () => api.hasVerifiedBackup(any(), 'owner', keepFavorites: any(named: 'keepFavorites')),
    ).thenAnswer((_) async => true);
    when(() => media.deleteAll(any())).thenAnswer((call) async => call.positionalArguments.first as List<String>);
    when(() => local.deleteAssets(any())).thenAnswer((_) async {});
    when(() => local.getAlbumIdsForAssets(any())).thenAnswer((_) async => {});
    sut = CleanupService(local, media, backupApi: api);
  });

  test('rechecks exclusions and deletes only the reviewed snapshot, once', () async {
    candidates = [photo, photo.copyWith(id: 'new')];
    final result = await sut.deleteVerifiedBackups(
      [photo, photo],
      'owner',
      cutoff,
      canContinue: () => true,
      keepMediaType: AssetKeepType.photosOnly,
      keepFavorites: false,
      keepAlbumIds: {'protected'},
    );
    expect(result.deletedIds, [photo.id]);
    expect(result.remainingIds, isEmpty);
    verify(
      () => local.getRemovalCandidates(
        'owner',
        cutoff,
        keepMediaType: AssetKeepType.photosOnly,
        keepFavorites: false,
        keepAlbumIds: {'protected'},
      ),
    ).called(2);
    verify(() => media.deleteAll([photo.id])).called(1);
  });
  for (final change in ['excluded', 'hash', 'revision', 'pair', 'adjustment', 'favorite']) {
    test('local $change change while checking backup prevents deletion', () async {
      when(() => api.hasVerifiedBackup(any(), 'owner', keepFavorites: true)).thenAnswer((_) async {
        candidates = switch (change) {
          'excluded' => [],
          'hash' => [photo.copyWith(checksum: 'new')],
          'revision' => [photo.copyWith(updatedAt: DateTime(2099))],
          'pair' => [photo.copyWith(playbackStyle: .livePhoto)],
          'adjustment' => [photo.copyWith(adjustmentTime: DateTime(2099))],
          _ => [photo.copyWith(isFavorite: true)],
        };
        return true;
      });
      final result = await sut.deleteVerifiedBackups([photo], 'owner', cutoff, canContinue: () => true);
      expect(result.remainingIds, [photo.id]);
      verifyNever(() => media.deleteAll(any()));
    });
  }
  for (final mode in ['offline', 'unverified', 'session']) {
    test('$mode never authorizes native deletion', () async {
      when(() => api.hasVerifiedBackup(any(), 'owner', keepFavorites: true)).thenAnswer((_) async {
        if (mode == 'offline') {
          throw TimeoutException('synthetic offline');
        }
        if (mode == 'session') {
          sessionCurrent = false;
        }
        return mode != 'unverified';
      });
      final result = await sut.deleteVerifiedBackups([photo], 'owner', cutoff, canContinue: () => sessionCurrent);
      expect(result.remainingIds, [photo.id]);
      verifyNever(() => media.deleteAll(any()));
    });
  }
  test('changed snapshot cannot expand to a replacement local asset', () async {
    candidates = [photo.copyWith(remoteId: 'another-server-id')];
    final result = await sut.deleteVerifiedBackups([photo], 'owner', cutoff, canContinue: () => true);
    expect(result.deletedIds, isEmpty);
    verifyNever(() => api.hasVerifiedBackup(any(), any(), keepFavorites: any(named: 'keepFavorites')));
  });
  test('partial OS acknowledgement stops before another batch or automatic retry', () async {
    candidates = List.generate(81, (i) => photo.copyWith(id: 'local-$i'));
    when(() => media.deleteAll(any())).thenAnswer((_) async => ['local-0', 'unrelated', 'local-0']);
    final result = await sut.deleteVerifiedBackups(candidates, 'owner', cutoff, canContinue: () => true);
    expect(result.deletedIds, ['local-0']);
    expect(result.remainingIds.length, 80);
    verify(() => media.deleteAll(any())).called(1);
    verify(() => local.deleteAssets(['local-0'])).called(1);
    verify(() => api.hasVerifiedBackup(any(), 'owner', keepFavorites: true)).called(40);
  });
  test('complete receipts permit the next bounded batch without expanding IDs', () async {
    candidates = List.generate(41, (i) => photo.copyWith(id: 'local-$i'));
    final result = await sut.deleteVerifiedBackups(candidates, 'owner', cutoff, canContinue: () => true);
    expect(result.deletedIds.length, 41);
    expect(result.remainingIds, isEmpty);
    verify(() => media.deleteAll(any())).called(2);
  });
}
