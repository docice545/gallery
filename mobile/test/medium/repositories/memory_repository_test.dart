import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/repositories/memory.repository.dart';

import '../repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;
  late MemoryRepository sut;

  setUp(() {
    ctx = MediumRepositoryContext();
    sut = MemoryRepository(ctx.db);
  });

  tearDown(() async {
    await ctx.dispose();
  });

  test('removing a two-years-ago memory persists without deleting its photo/video or links', () async {
    final user = await ctx.newUser();
    final video = await ctx.newRemoteAsset(ownerId: user.id, type: .video);
    final asset = await ctx.newRemoteAsset(ownerId: user.id, livePhotoVideoId: video.id);
    final memory = await ctx.newMemory(ownerId: user.id, memoryAt: DateTime.utc(2024));
    await ctx.newMemoryAsset(memoryId: memory.id, assetId: asset.id);
    await ctx.newMemoryAsset(memoryId: memory.id, assetId: video.id);
    await sut.markRemoved(memory.id, DateTime.utc(2026, 10, 5));
    expect(await sut.get(memory.id), isNull);
    expect(await sut.getAll(user.id), isEmpty);
    expect(await sut.getAll(user.id, onlyToday: false), isEmpty);
    // Reconstructing the repository represents a fresh reader after restart.
    expect(await MemoryRepository(ctx.db).getAll(user.id, onlyToday: false), isEmpty);
    final originals = await ctx.db.select(ctx.db.remoteAssetEntity).get();
    expect(originals.map((row) => row.id), unorderedEquals([asset.id, video.id]));
    expect(originals.singleWhere((row) => row.id == asset.id).livePhotoVideoId, video.id);
    expect(
      (await ctx.db.select(ctx.db.memoryAssetEntity).get()).map((row) => row.assetId),
      unorderedEquals([asset.id, video.id]),
    );
  });

  test('memory sync updates notify reactive lists without changing assets', () async {
    final user = await ctx.newUser();
    final asset = await ctx.newRemoteAsset(ownerId: user.id);
    final memory = await ctx.newMemory(ownerId: user.id);
    await ctx.newMemoryAsset(memoryId: memory.id, assetId: asset.id);
    final revisions = <int>[];
    final subscription = sut.watchChanges(user.id).listen(revisions.add);
    try {
      await Future<void>.delayed(Duration.zero);
      await sut.markRemoved(memory.id, DateTime.utc(2026));
      await Future<void>.delayed(Duration.zero);
      expect(revisions.length, greaterThanOrEqualTo(2));
      expect((await ctx.db.select(ctx.db.remoteAssetEntity).get()).single.id, asset.id);
    } finally {
      await subscription.cancel();
    }
  });

  group('getAll', () {
    // #24745: memories created via the API have no showAt/hideAt. before the fix
    // the window filter (show_at <= now AND hide_at >= now) drops them because a
    // NULL comparison is never true.
    test('includes a memory with null showAt/hideAt', () async {
      final user = await ctx.newUser();
      final asset = await ctx.newRemoteAsset(ownerId: user.id);
      final memory = await ctx.newMemory(ownerId: user.id);
      await ctx.newMemoryAsset(memoryId: memory.id, assetId: asset.id);

      final result = await sut.getAll(user.id);

      expect(result, hasLength(1));
      expect(result.first.id, memory.id);
      expect(result.first.assets.single.id, asset.id);
    });

    test('includes a memory whose window covers today', () async {
      final user = await ctx.newUser();
      final asset = await ctx.newRemoteAsset(ownerId: user.id);
      final now = DateTime.now().toUtc();
      final memory = await ctx.newMemory(
        ownerId: user.id,
        showAt: now.subtract(const Duration(days: 10)),
        hideAt: now.add(const Duration(days: 10)),
      );
      await ctx.newMemoryAsset(memoryId: memory.id, assetId: asset.id);

      final result = await sut.getAll(user.id);

      expect(result.map((m) => m.id), [memory.id]);
    });

    test('excludes a memory whose hideAt is in the past', () async {
      final user = await ctx.newUser();
      final asset = await ctx.newRemoteAsset(ownerId: user.id);
      final now = DateTime.now().toUtc();
      final memory = await ctx.newMemory(
        ownerId: user.id,
        showAt: now.subtract(const Duration(days: 20)),
        hideAt: now.subtract(const Duration(days: 10)),
      );
      await ctx.newMemoryAsset(memoryId: memory.id, assetId: asset.id);

      final result = await sut.getAll(user.id);

      expect(result, isEmpty);
    });

    test('excludes a memory whose showAt is in the future', () async {
      final user = await ctx.newUser();
      final asset = await ctx.newRemoteAsset(ownerId: user.id);
      final now = DateTime.now().toUtc();
      final memory = await ctx.newMemory(
        ownerId: user.id,
        showAt: now.add(const Duration(days: 10)),
        hideAt: now.add(const Duration(days: 20)),
      );
      await ctx.newMemoryAsset(memoryId: memory.id, assetId: asset.id);

      final result = await sut.getAll(user.id);

      expect(result, isEmpty);
    });

    test('includes a memory with showAt in the past and null hideAt', () async {
      final user = await ctx.newUser();
      final asset = await ctx.newRemoteAsset(ownerId: user.id);
      final now = DateTime.now().toUtc();
      final memory = await ctx.newMemory(ownerId: user.id, showAt: now.subtract(const Duration(days: 10)));
      await ctx.newMemoryAsset(memoryId: memory.id, assetId: asset.id);

      final result = await sut.getAll(user.id);

      expect(result.map((m) => m.id), [memory.id]);
    });

    test('excludes a memory with null showAt and hideAt in the past', () async {
      final user = await ctx.newUser();
      final asset = await ctx.newRemoteAsset(ownerId: user.id);
      final now = DateTime.now().toUtc();
      final memory = await ctx.newMemory(ownerId: user.id, hideAt: now.subtract(const Duration(days: 10)));
      await ctx.newMemoryAsset(memoryId: memory.id, assetId: asset.id);

      final result = await sut.getAll(user.id);

      expect(result, isEmpty);
    });
  });
}
