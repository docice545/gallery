import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline.repository.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/services/cleanup.service.dart';
import 'package:mocktail/mocktail.dart';

import '../../medium/repository_context.dart';
import '../../repository.mocks.dart';

void main() {
  late MediumRepositoryContext ctx;
  late ProviderContainer container;
  late MockAssetMediaRepository media;
  late CleanupService cleanup;

  setUp(() {
    ctx = MediumRepositoryContext();
    container = ProviderContainer(overrides: [driftProvider.overrideWithValue(ctx.db)]);
    media = MockAssetMediaRepository();
    cleanup = CleanupService(ctx.db.localAssetRepository, media);
  });

  tearDown(() async {
    container.dispose();
    await ctx.dispose();
  });

  Future<void> seedServ() async {
    await ctx.newLocalAlbum(id: 'serv', name: 'Serv');
    for (var index = 1; index <= 3; index++) {
      final asset = await ctx.newLocalAsset(id: '$index', createdAt: DateTime.utc(2026, 11, index));
      await ctx.newLocalAlbumAsset(albumId: 'serv', assetId: asset.id);
    }
  }

  Future<LocalAsset?> primeCover() {
    // Match the album thumbnail widget's watch lifetime instead of relying on
    // an unobserved auto-dispose provider to retain a database subscription.
    final subscription = container.listen(localAlbumThumbnailProvider('serv'), (_, _) {});
    addTearDown(subscription.close);
    return container.read(localAlbumThumbnailProvider('serv').future);
  }

  Future<List<LocalAlbum>> nextAlbums(bool Function(List<LocalAlbum>) matches) {
    final complete = Completer<List<LocalAlbum>>();
    final subscription = container.listen(localAlbumProvider, (_, state) {
      final value = state.valueOrNull;
      if (!complete.isCompleted && value != null && matches(value)) {
        complete.complete(value);
      }
    }, fireImmediately: true);
    return complete.future.timeout(const Duration(seconds: 3)).whenComplete(subscription.close);
  }

  Future<LocalAsset?> nextCover(String? id) {
    final complete = Completer<LocalAsset?>();
    final subscription = container.listen(localAlbumThumbnailProvider('serv'), (_, state) {
      if (!complete.isCompleted && state.hasValue && state.valueOrNull?.id == id) {
        complete.complete(state.valueOrNull);
      }
    }, fireImmediately: true);
    return complete.future.timeout(const Duration(seconds: 3)).whenComplete(subscription.close);
  }

  test('confirmed cleanup updates cached Serv 3 to zero and clears its cover without invalidation', () async {
    await seedServ();
    expect((await container.read(localAlbumProvider.future)).single.assetCount, 3);
    expect((await primeCover())?.id, '3');
    when(() => media.deleteAll(['1', '2', '3'])).thenAnswer((_) async => ['1', '2', '3']);
    final emptyAlbums = nextAlbums((value) => value.isEmpty);
    final emptyCover = nextCover(null);

    final result = await cleanup.deleteLocalAssetsDetailed(['1', '2', '3']);

    expect(result.deletedIds, ['1', '2', '3']);
    expect(await TimelineRepository(ctx.db).localAlbum('serv', GroupAssetsBy.none).bucketSource().first, isEmpty);
    final changed = await Future.wait<Object?>([emptyAlbums, emptyCover]);
    expect(changed[0], isEmpty);
    expect(changed[1], isNull);
    verify(() => media.deleteAll(['1', '2', '3'])).called(1);
  });

  test('partial cleanup updates the count and replacement cover but retains unacknowledged files', () async {
    await seedServ();
    expect((await container.read(localAlbumProvider.future)).single.assetCount, 3);
    expect((await primeCover())?.id, '3');
    when(() => media.deleteAll(['1', '2', '3'])).thenAnswer((_) async => ['3']);
    final remainingAlbums = nextAlbums((value) => value.length == 1 && value.single.assetCount == 2);
    final remainingCover = nextCover('2');

    final result = await cleanup.deleteLocalAssetsDetailed(['1', '2', '3']);

    expect(result.deletedIds, ['3']);
    expect(result.remainingIds, ['1', '2']);
    expect((await remainingAlbums).single.assetCount, 2);
    expect((await remainingCover)?.id, '2');
    expect((await ctx.db.localAlbumRepository.getAssets('serv')).map((asset) => asset.id), ['1', '2']);
  });

  test('cancelled cleanup preserves the primed count and cover', () async {
    await seedServ();
    await container.read(localAlbumProvider.future);
    await primeCover();
    when(() => media.deleteAll(['3'])).thenAnswer((_) async => []);

    final result = await cleanup.deleteLocalAssetsDetailed(['3']);

    expect(result.deletedIds, isEmpty);
    expect(result.remainingIds, ['3']);
    expect(container.read(localAlbumProvider).requireValue.single.assetCount, 3);
    expect(container.read(localAlbumThumbnailProvider('serv')).requireValue?.id, '3');
  });

  test('switching the Drift source replaces subscriptions and ignores later old-source writes', () async {
    await seedServ();
    final alternate = MediumRepositoryContext();
    final database = StateProvider<Drift>((ref) => ctx.db);
    container.dispose();
    container = ProviderContainer(overrides: [driftProvider.overrideWith((ref) => ref.watch(database))]);
    try {
      expect((await container.read(localAlbumProvider.future)).single.assetCount, 3);
      expect((await primeCover())?.id, '3');
      container.read(database.notifier).state = alternate.db;
      expect(await container.read(localAlbumProvider.future), isEmpty);
      expect(await container.read(localAlbumThumbnailProvider('serv').future), isNull);
      await ctx.newLocalAsset(id: 'late-old-source');
      await ctx.newLocalAlbumAsset(albumId: 'serv', assetId: 'late-old-source');
      await Future<void>.delayed(Duration.zero);
      expect(container.read(localAlbumProvider).requireValue, isEmpty);
      expect(container.read(localAlbumThumbnailProvider('serv')).requireValue, isNull);
    } finally {
      container.dispose();
      container = ProviderContainer();
      await alternate.dispose();
    }
  });

  test('thumbnail subscription is disposed offscreen and reopening reads the new cover', () async {
    await seedServ();
    final provider = localAlbumThumbnailProvider('serv');
    final subscription = container.listen(provider, (_, _) {});
    expect((await container.read(provider.future))?.id, '3');

    subscription.close();
    await container.pump();
    expect(container.exists(provider), isFalse);
    await ctx.db.localAssetRepository.deleteAssets(['3']);
    final reopened = container.listen(provider, (_, _) {});
    expect((await container.read(provider.future))?.id, '2');
    reopened.close();
  });
}
