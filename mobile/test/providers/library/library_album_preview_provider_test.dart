import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/library/library_album_preview.provider.dart';
import 'package:immich_mobile/providers/library/library_layout.provider.dart';

import '../../medium/repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;
  late ProviderContainer container;
  late StateProvider<LibraryLayoutScope?> selected;
  late StateProvider<Drift> selectedDatabase;
  final extraContexts = <MediumRepositoryContext>[];
  late String a;
  late String b;

  setUp(() async {
    ctx = MediumRepositoryContext();
    a = (await ctx.newUser()).id;
    b = (await ctx.newUser()).id;
    selected = StateProvider((ref) => LibraryLayoutScope(serverId: 'https://example.test', userId: a));
    selectedDatabase = StateProvider((ref) => ctx.db);
    container = ProviderContainer(
      overrides: [
        driftProvider.overrideWith((ref) => ref.watch(selectedDatabase)),
        libraryLayoutScopeProvider.overrideWith((ref) => ref.watch(selected)),
      ],
    );
    container.listen(libraryAlbumPreviewProvider, (_, _) {});
  });
  tearDown(() async {
    container.dispose();
    for (final extra in extraContexts) {
      await extra.dispose();
    }
    extraContexts.clear();
    await ctx.dispose();
  });

  test('starts loading then resolves cached local albums; no page refresh needed', () async {
    final album = await ctx.newRemoteAlbum(ownerId: a);
    container.invalidate(libraryAlbumPreviewProvider);
    expect(container.read(libraryAlbumPreviewProvider).isLoading, isTrue);
    expect((await container.read(libraryAlbumPreviewProvider.future)).single.albumId, album.id);
  });

  test('late sync of first album replaces cached genuine-empty result', () async {
    expect(await container.read(libraryAlbumPreviewProvider.future), isEmpty);
    final arrival = Completer<String>();
    final changed = container.listen(libraryAlbumPreviewProvider, (_, state) {
      if (!arrival.isCompleted && state.valueOrNull?.isNotEmpty == true) {
        arrival.complete(state.requireValue.single.albumId);
      }
    });
    final album = await ctx.newRemoteAlbum(ownerId: a);
    expect(await arrival.future.timeout(const Duration(seconds: 5)), album.id);
    changed.close();
  });

  test('account switch drops A list and watches only B memberships', () async {
    final ownA = await ctx.newRemoteAlbum(ownerId: a);
    final ownB = await ctx.newRemoteAlbum(ownerId: b);
    container.invalidate(libraryAlbumPreviewProvider);
    expect((await container.read(libraryAlbumPreviewProvider.future)).single.albumId, ownA.id);
    container.read(selected.notifier).state = LibraryLayoutScope(serverId: 'https://example.test', userId: b);
    expect(container.read(libraryAlbumPreviewProvider).isLoading, isTrue);
    expect((await container.read(libraryAlbumPreviewProvider.future)).single.albumId, ownB.id);
    await ctx.newRemoteAlbum(ownerId: a);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(libraryAlbumPreviewProvider).requireValue.map((item) => item.albumId), [ownB.id]);
  });

  test('logout shows readiness loading; next login obtains fresh scoped data', () async {
    final ownA = await ctx.newRemoteAlbum(ownerId: a);
    container.invalidate(libraryAlbumPreviewProvider);
    expect((await container.read(libraryAlbumPreviewProvider.future)).single.albumId, ownA.id);
    container.read(selected.notifier).state = null;
    expect(container.read(libraryAlbumPreviewProvider).isLoading, isTrue);
    final ownB = await ctx.newRemoteAlbum(ownerId: b);
    container.read(selected.notifier).state = LibraryLayoutScope(serverId: 'https://example.test', userId: b);
    expect((await container.read(libraryAlbumPreviewProvider.future)).single.albumId, ownB.id);
  });

  test('endpoint/session switch drops old database subscription and ignores late old-server writes', () async {
    final oldAlbum = await ctx.newRemoteAlbum(ownerId: a);
    container.invalidate(libraryAlbumPreviewProvider);
    expect((await container.read(libraryAlbumPreviewProvider.future)).single.albumId, oldAlbum.id);
    final otherServer = MediumRepositoryContext();
    extraContexts.add(otherServer);
    await otherServer.newUser(id: a);
    final newAlbum = await otherServer.newRemoteAlbum(ownerId: a);
    final lateOldWrite = ctx.newRemoteAlbum(ownerId: a);
    container.read(selected.notifier).state = LibraryLayoutScope(serverId: 'https://another.test', userId: a);
    container.read(selectedDatabase.notifier).state = otherServer.db;
    expect(container.read(libraryAlbumPreviewProvider).isLoading, isTrue);
    expect((await container.read(libraryAlbumPreviewProvider.future)).single.albumId, newAlbum.id);
    await lateOldWrite;
    await Future<void>.delayed(Duration.zero);
    expect(container.read(libraryAlbumPreviewProvider).requireValue.map((item) => item.albumId), [newAlbum.id]);
  });
}
