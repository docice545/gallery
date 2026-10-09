import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline.repository.dart';
import 'package:immich_mobile/models/folder/recursive_folder.model.dart';
import 'package:immich_mobile/models/folder/root_folder.model.dart';
import 'package:immich_mobile/providers/folder.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/sync_status.provider.dart';
import 'package:immich_mobile/services/folder.service.dart';
import 'package:mocktail/mocktail.dart';

import '../medium/repository_context.dart';

class _MockFolderService extends Mock implements FolderService {}

class _FakeRootFolder extends Fake implements RootFolder {}

Future<void> _waitFor(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for folder Trash projection');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

RemoteAssetExif _asset(String id, {AssetType type = AssetType.image}) => RemoteAssetExif(
  id: id,
  name: '$id.${type == AssetType.video ? 'mp4' : 'jpg'}',
  checksum: 'checksum-$id',
  ownerId: 'owner',
  type: type,
  createdAt: DateTime.utc(2024, 10, 5),
  updatedAt: DateTime.utc(2024, 10, 5),
);

void main() {
  late MediumRepositoryContext ctx;
  const folder = RecursiveFolder(name: 'Camera', path: '', subfolders: []);

  setUp(() async {
    ctx = MediumRepositoryContext();
    await ctx.newUser(id: 'owner');
    await ctx.newAuthUser(id: 'owner');
    await StoreRepository(ctx.db).upsert(StoreKey.serverEndpoint, 'https://gallery.invalid/api');
  });
  tearDown(() => ctx.dispose());

  setUpAll(() {
    registerFallbackValue(_FakeRootFolder());
    registerFallbackValue(SortOrder.asc);
  });

  group('folder providers', () {
    test('remote content changes refetch the active folder structure query', () async {
      final service = _MockFolderService();
      when(
        () => service.getFolderStructure(any()),
      ).thenAnswer((_) async => const RootFolder(subfolders: [], path: '/'));

      final container = ProviderContainer(
        overrides: [folderServiceProvider.overrideWithValue(service), driftProvider.overrideWithValue(ctx.db)],
      );
      addTearDown(container.dispose);

      await container.read(folderStructureProvider.notifier).fetchFolders(SortOrder.asc);
      verify(() => service.getFolderStructure(SortOrder.asc)).called(1);

      container.read(syncStatusProvider.notifier).markRemoteContentChanged();
      await Future<void>.delayed(const Duration(milliseconds: 5));

      verify(() => service.getFolderStructure(SortOrder.asc)).called(1);
    });

    test('remote content changes refetch active folder assets', () async {
      final service = _MockFolderService();
      const folder = RecursiveFolder(name: 'Camera', path: '', subfolders: []);
      when(() => service.getFolderAssets(any(), any())).thenAnswer((_) async => const []);

      final container = ProviderContainer(
        overrides: [folderServiceProvider.overrideWithValue(service), driftProvider.overrideWithValue(ctx.db)],
      );
      addTearDown(container.dispose);

      await container.read(folderRenderListProvider(folder).notifier).fetchAssets(SortOrder.desc);
      verify(() => service.getFolderAssets(folder, SortOrder.desc)).called(1);

      container.read(syncStatusProvider.notifier).markRemoteContentChanged();
      await Future<void>.delayed(const Duration(milliseconds: 5));

      verify(() => service.getFolderAssets(folder, SortOrder.desc)).called(1);
    });

    test('cached folder and Viewer react to bulk Trash, Restore and re-Trash without HTTP refetch', () async {
      final service = _MockFolderService();
      final assets = [_asset('photo'), _asset('video', type: AssetType.video), _asset('live')];
      for (final asset in assets) {
        await ctx.newRemoteAsset(id: asset.id, ownerId: 'owner', type: asset.type);
      }
      when(() => service.getFolderAssets(any(), any())).thenAnswer((_) async => assets);
      final notifier = FolderRenderListNotifier(
        service,
        folder,
        trashedIds: ctx.db.syncStreamRepository.watchTrashedAssetIds(),
      );
      addTearDown(notifier.dispose);
      await notifier.fetchAssets(SortOrder.asc);
      await _waitFor(() => notifier.getAssets().length == 3);

      final query = TimelineRepository(
        ctx.db,
      ).fromAssetStream(notifier.getAssets, notifier.count, TimelineOrigin.folder);
      final emissions = <List<Bucket>>[];
      final buckets = query.bucketSource().listen(emissions.add);
      addTearDown(buckets.cancel);
      int? currentCount() =>
          emissions.isEmpty ? null : emissions.last.fold<int>(0, (sum, bucket) => sum + bucket.assetCount);
      await _waitFor(() => currentCount() == 3);
      final remote = RemoteAssetRepository(ctx.db);
      await remote.beginTrashOperation(['photo', 'video', 'live'], restore: false);
      await _waitFor(() => notifier.getAssets().isEmpty);
      await _waitFor(() => currentCount() == 0);
      expect(emissions.last, isEmpty);
      expect(await query.assetSource(0, 10), isEmpty);

      final restore = await remote.beginTrashOperation(['photo', 'video', 'live'], restore: true);
      await _waitFor(() => notifier.getAssets().length == 3);
      await _waitFor(() => currentCount() == 3);
      expect((await query.assetSource(1, 2)).map((asset) => asset.id), ['video', 'live']);
      await remote.beginTrashOperation(['photo'], restore: false);
      await _waitFor(() => notifier.getAssets().length == 2);
      await remote.completeTrashOperation(restore, success: true);
      await Future<void>.delayed(Duration.zero);
      expect(notifier.getAssets().map((asset) => asset.id), ['video', 'live']);
      verify(() => service.getFolderAssets(folder, SortOrder.asc)).called(1);
    });

    test('late HTTP snapshot cannot resurrect optimistic Trash', () async {
      await ctx.newRemoteAsset(id: 'photo', ownerId: 'owner');
      final service = _MockFolderService();
      final response = Completer<List<RemoteAssetExif>>();
      when(() => service.getFolderAssets(any(), any())).thenAnswer((_) => response.future);
      final notifier = FolderRenderListNotifier(
        service,
        folder,
        trashedIds: ctx.db.syncStreamRepository.watchTrashedAssetIds(),
      );
      addTearDown(notifier.dispose);
      final loading = notifier.fetchAssets(SortOrder.asc);
      await RemoteAssetRepository(ctx.db).beginTrashOperation(['photo'], restore: false);
      response.complete([_asset('photo')]);
      await loading;
      // The first snapshot is hidden even if the durable marker stream has not
      // emitted yet; after it emits, the pending marker still wins.
      expect(notifier.getAssets(), isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(notifier.state.requireValue, isEmpty);
    });

    test('new notifier does not flash a cached tile when durable Trash survives restart', () async {
      await ctx.newRemoteAsset(id: 'photo', ownerId: 'owner');
      await RemoteAssetRepository(ctx.db).beginTrashOperation(['photo'], restore: false);
      final service = _MockFolderService();
      when(() => service.getFolderAssets(any(), any())).thenAnswer((_) async => [_asset('photo')]);
      final notifier = FolderRenderListNotifier(
        service,
        folder,
        trashedIds: ctx.db.syncStreamRepository.watchTrashedAssetIds(),
      );
      final displayed = <String>[];
      final stop = notifier.addListener((state) => displayed.addAll(state.valueOrNull?.map((asset) => asset.id) ?? []));
      addTearDown(notifier.dispose);
      addTearDown(stop);
      await notifier.fetchAssets(SortOrder.asc);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(displayed, isEmpty);
      expect(notifier.getAssets(), isEmpty);
    });

    test('cleared permanent-delete marker and unrelated sync cannot reveal cached folder item', () async {
      await ctx.newRemoteAsset(id: 'photo', ownerId: 'owner');
      final service = _MockFolderService();
      when(() => service.getFolderAssets(any(), any())).thenAnswer((_) async => [_asset('photo')]);
      final notifier = FolderRenderListNotifier(
        service,
        folder,
        trashedIds: ctx.db.syncStreamRepository.watchTrashedAssetIds(),
      );
      addTearDown(notifier.dispose);
      await notifier.fetchAssets(SortOrder.asc);
      await _waitFor(() => notifier.getAssets().isNotEmpty);
      final remote = RemoteAssetRepository(ctx.db);
      await remote.trash(['photo']);
      await _waitFor(() => notifier.getAssets().isEmpty);
      await remote.deleteAssets(['photo']);
      await ctx.newRemoteAsset(id: 'other', ownerId: 'owner');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(notifier.getAssets(), isEmpty);
    });

    test('a superseded folder response does not undo a newer fetch or sort', () async {
      final service = _MockFolderService();
      final oldResponse = Completer<List<RemoteAssetExif>>();
      when(() => service.getFolderAssets(any(), SortOrder.asc)).thenAnswer((_) => oldResponse.future);
      when(() => service.getFolderAssets(any(), SortOrder.desc)).thenAnswer((_) async => [_asset('new')]);
      final notifier = FolderRenderListNotifier(service, folder);
      addTearDown(notifier.dispose);
      final oldFetch = notifier.fetchAssets(SortOrder.asc);
      await notifier.fetchAssets(SortOrder.desc);
      oldResponse.complete([_asset('old')]);
      await oldFetch;
      expect(notifier.getAssets().map((asset) => asset.id), ['new']);
    });

    test('disposing during an HTTP request cancels observation and ignores its late response', () async {
      final service = _MockFolderService();
      final response = Completer<List<RemoteAssetExif>>();
      final markers = StreamController<Set<String>>(sync: true);
      when(() => service.getFolderAssets(any(), any())).thenAnswer((_) => response.future);
      final notifier = FolderRenderListNotifier(service, folder, trashedIds: markers.stream);
      final loading = notifier.fetchAssets(SortOrder.asc);
      notifier.dispose();
      markers.add({'photo'});
      response.complete([_asset('photo')]);
      await expectLater(loading, completes);
      await markers.close();
      expect(markers.hasListener, isFalse);
    });
  });
}
