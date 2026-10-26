import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/deletion_result.model.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/models/stack.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/asset.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_exif.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/trashed_local_asset.repository.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart' as api;

import '../../medium/repository_context.dart';
import '../../repository.mocks.dart';

api.SyncAssetV1 _syncAsset(RemoteAsset asset, {DateTime? deletedAt, bool detached = false}) => api.SyncAssetV1(
  id: asset.id,
  ownerId: asset.ownerId,
  checksum: asset.checksum!,
  originalFileName: asset.name,
  type: api.AssetTypeEnum.IMAGE,
  fileCreatedAt: asset.createdAt,
  fileModifiedAt: asset.updatedAt,
  createdAt: asset.createdAt,
  localDateTime: asset.createdAt,
  isFavorite: false,
  isEdited: false,
  visibility: api.AssetVisibility.timeline,
  deletedAt: deletedAt,
  width: asset.width,
  height: asset.height,
  duration: null,
  libraryId: null,
  livePhotoVideoId: null,
  stackId: detached ? null : asset.stackId,
  thumbhash: asset.thumbHash,
);

void main() {
  const owner = 'stack-owner';
  final selectedDate = DateTime(2026, 10, 26, 12);
  late MediumRepositoryContext context;
  late StoreService store;
  late AssetService assets;
  late RemoteAssetRepository remote;
  late TimelineRepository timelines;
  late MockAssetApiRepository assetApi;
  late MockAssetMediaRepository media;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await initializeDateFormatting('en');
  });

  setUp(() async {
    context = MediumRepositoryContext();
    await context.newUser(id: owner);
    await context.newAuthUser(id: owner);
    store = await StoreService.init(storeRepository: StoreRepository(context.db), listenUpdates: false);
    await store.put(StoreKey.serverEndpoint, 'https://stack-tests.example/api');
    remote = RemoteAssetRepository(context.db);
    timelines = TimelineRepository(context.db);
    assetApi = MockAssetApiRepository();
    media = MockAssetMediaRepository();
    assets = AssetService(
      remoteRepository: remote,
      exifRepository: RemoteExifRepository(context.db),
      localRepository: LocalAssetRepository(context.db),
      apiRepository: assetApi,
      mediaRepository: media,
      trashedLocalRepository: TrashedLocalAssetRepository(context.db),
    );
  });

  tearDown(() async {
    await store.dispose();
    await context.dispose();
  });

  Future<List<RemoteAsset>> seedStack(int count, {String stackId = 'stack', bool cacheChildren = true}) async {
    final ids = List.generate(count, (index) => '$stackId-$index');
    await context.newLocalAlbum(id: '$stackId-camera', backupSelection: BackupSelection.selected);
    for (final (index, id) in ids.indexed) {
      final captured = index == 0 ? selectedDate : selectedDate.subtract(Duration(days: 10 + index));
      if (index == 0 || cacheChildren) {
        await context.newRemoteAsset(
          id: id,
          ownerId: owner,
          checksum: 'checksum-$id',
          stackId: stackId,
          createdAt: captured,
          updatedAt: captured,
        );
      }
      await context.newLocalAsset(id: 'local-$id', checksum: 'checksum-$id', createdAt: captured);
      await context.newLocalAlbumAsset(albumId: '$stackId-camera', assetId: 'local-$id');
    }
    await context.insertStack(id: stackId, ownerId: owner, primaryAssetId: ids.first);
    when(
      () => assetApi.getStack(stackId),
    ).thenAnswer((_) async => StackResponse(id: stackId, primaryAssetId: ids.first, assetIds: ids));
    return [
      for (final (index, id) in ids.indexed)
        RemoteAsset(
          id: id,
          ownerId: owner,
          checksum: 'checksum-$id',
          name: 'synthetic-$id.jpg',
          type: AssetType.image,
          createdAt: index == 0 ? selectedDate : selectedDate.subtract(Duration(days: 10 + index)),
          updatedAt: selectedDate,
          stackId: stackId,
          isEdited: false,
        ),
    ];
  }

  Future<void> expectNoDeviceMutation(int originals) async {
    expect(await context.db.select(context.db.localAssetEntity).get(), hasLength(originals));
    expect(await context.db.select(context.db.trashedLocalAssetEntity).get(), isEmpty);
    verifyZeroInteractions(media);
  }

  for (final count in [2, 3, 5]) {
    test('$count-member collapsed cover resolves all server IDs independently of date', () async {
      final members = await seedStack(count);
      final ids = members.map((asset) => asset.id).toList();
      expect(await assets.resolveStackTrashIds([ids.first], [members.first]), unorderedEquals(ids));
      verify(() => assetApi.getStack('stack')).called(1);
      verifyNever(() => assetApi.delete(any(), any()));
      verifyNever(() => assetApi.permanentlyDelete(any()));
      expect(await assets.getTrashIds(owner), isEmpty);
      await expectNoDeviceMutation(count);
    });

    test('$count-member date selection trashes, purges and syncs every frame without an active orphan', () async {
      final members = await seedStack(count);
      final memberIds = members.map((asset) => asset.id).toList();
      await context.newRemoteAsset(
        id: 'selected-standalone',
        ownerId: owner,
        checksum: 'selected-checksum',
        createdAt: selectedDate.subtract(const Duration(hours: 1)),
      );
      await context.newRemoteAsset(
        id: 'unselected',
        ownerId: owner,
        checksum: 'unselected-checksum',
        createdAt: selectedDate.subtract(const Duration(days: 1)),
      );
      final query = timelines.main([owner], owner, GroupAssetsBy.day);
      final buckets = (await query.bucketSource().first).cast<TimeBucket>();
      expect(buckets.first, TimeBucket(date: DateTime(2026, 10, 26), assetCount: 2));
      expect(buckets.fold<int>(0, (total, bucket) => total + bucket.assetCount), 3);

      late final TimelineService timeline;
      final loaded = EventStream.shared.where<TimelineReloadEvent>().firstWhere((_) => timeline.totalAssets == 3);
      timeline = TimelineService(query);
      final container = ProviderContainer(overrides: [timelineServiceProvider.overrideWithValue(timeline)]);
      late final List<BaseAsset> selected;
      try {
        await loaded.timeout(const Duration(seconds: 5));
        await container.read(multiSelectProvider.notifier).toggleBucketSelection(0, buckets.first.assetCount);
        selected = container.read(multiSelectProvider).selectedAssets.toList();
        expect(selected.map((asset) => asset.remoteId), unorderedEquals([memberIds.first, 'selected-standalone']));
        expect(selected, hasLength(2), reason: 'selection continues to represent two visible tiles');
      } finally {
        container.dispose();
        await timeline.dispose();
      }

      final selectedIds = selected.map((asset) => asset.remoteId!).toList();
      final expanded = await assets.resolveStackTrashIds(
        selectedIds,
        selected.whereType<RemoteAsset>().where((asset) => asset.stackId != null).toList(),
      );
      final expectedIds = [...memberIds, 'selected-standalone'];
      expect(expanded, unorderedEquals(expectedIds));
      expect(expanded, isNot(contains('unselected')));
      final acceptedTrash = <String>[];
      when(() => assetApi.delete(any(), false)).thenAnswer((call) async {
        acceptedTrash.addAll(call.positionalArguments.first as List<String>);
      });
      await assets.trash(expanded);
      expect(acceptedTrash, unorderedEquals(expectedIds));
      expect(await assets.getTrashIds(owner), unorderedEquals(expectedIds));
      expect((await remote.get('unselected'))!.isTrashed, isFalse);
      await expectNoDeviceMutation(count);

      // Apply server Trash payloads using the normal Drift sync path. Child
      // capture dates lie outside the selected date but all are now in Trash.
      await context.db.syncStreamRepository.updateAssetsV1([
        for (final member in members) _syncAsset(member, deletedAt: selectedDate.add(const Duration(hours: 1))),
      ]);
      expect(await assets.getTrashIds(owner), unorderedEquals(expectedIds));
      final purgeIds = await assets.getTrashIds(owner);
      final acceptedPurge = <String>[];
      when(() => assetApi.permanentlyDelete(any())).thenAnswer((call) async {
        final ids = call.positionalArguments.first as List<String>;
        acceptedPurge.addAll(ids);
        return [for (final id in ids) PermanentDeletionResult(id: id, state: 'complete')];
      });
      final results = await assets.deleteWithResults(purgeIds);
      expect(results.every((result) => result.complete), isTrue);
      expect(acceptedPurge, unorderedEquals(expectedIds));
      for (final id in expectedIds) {
        expect(await remote.get(id), isNull, reason: 'every selected frame has a completed server receipt');
      }

      // Repeated deletion events, stack cascade and a stale pre-deletion
      // payload cannot produce a surviving child tile or duplicate upload.
      final deletes = [for (final id in expectedIds) api.SyncAssetDeleteV1(assetId: id)];
      await context.db.syncStreamRepository.deleteAssetsV1(deletes);
      await context.db.syncStreamRepository.deleteStacksV1([api.SyncStackDeleteV1(stackId: 'stack')]);
      await context.db.syncStreamRepository.deleteAssetsV1(deletes);
      await context.db.syncStreamRepository.updateAssetsV1([for (final member in members) _syncAsset(member)]);
      expect(await assets.getTrashIds(owner), isEmpty);
      expect((await query.assetSource(0, 100)).map((asset) => asset.remoteId), ['unselected']);
      expect(await context.db.select(context.db.remoteAssetEntity).get(), hasLength(1));
      expect(await context.db.select(context.db.stackEntity).get(), isEmpty);
      await expectNoDeviceMutation(count);
    });
  }

  test('server membership includes children absent from the local cache', () async {
    final members = await seedStack(5, cacheChildren: false);
    expect(await context.db.select(context.db.remoteAssetEntity).get(), hasLength(1));
    expect(
      await assets.resolveStackTrashIds([members.first.id], [members.first]),
      unorderedEquals(members.map((asset) => asset.id)),
    );
    expect(await context.db.select(context.db.remoteAssetEntity).get(), hasLength(1));
    verifyNever(() => assetApi.delete(any(), any()));
    await expectNoDeviceMutation(5);
  });

  test('overlapping selection and duplicate covers request one membership snapshot and one UUID each', () async {
    final members = await seedStack(3);
    final response = StackResponse(
      id: 'stack',
      primaryAssetId: members.first.id,
      assetIds: [members.first.id, members[1].id, members[1].id, members.last.id],
    );
    when(() => assetApi.getStack('stack')).thenAnswer((_) async => response);
    final result = await assets.resolveStackTrashIds(
      [members.first.id, members.first.id, members[1].id, 'standalone'],
      [members.first, members.first],
    );
    expect(result, unorderedEquals([...members.map((asset) => asset.id), 'standalone']));
    expect(result.length, 4);
    verify(() => assetApi.getStack('stack')).called(1);
    await expectNoDeviceMutation(3);
  });

  for (final malformed in ['wrong-stack', 'new-primary', 'missing-cover']) {
    test('$malformed membership is rejected before any trash mutation', () async {
      final members = await seedStack(3);
      when(() => assetApi.getStack('stack')).thenAnswer(
        (_) async => StackResponse(
          id: malformed == 'wrong-stack' ? 'other-stack' : 'stack',
          primaryAssetId: malformed == 'new-primary' ? members[1].id : members.first.id,
          assetIds: malformed == 'missing-cover'
              ? members.skip(1).map((asset) => asset.id).toList()
              : members.map((asset) => asset.id).toList(),
        ),
      );
      Future<void> selectedTrash() async {
        final ids = await assets.resolveStackTrashIds([members.first.id], [members.first]);
        await assets.trash(ids);
      }

      await expectLater(selectedTrash(), throwsStateError);
      verifyNever(() => assetApi.delete(any(), any()));
      expect(await assets.getTrashIds(owner), isEmpty);
      await expectNoDeviceMutation(3);
    });
  }

  for (final status in [404, 503]) {
    test('failed stack lookup HTTP $status prevents every selected mutation', () async {
      final first = await seedStack(2, stackId: 'first');
      final second = await seedStack(3, stackId: 'second');
      final failure = api.ApiException(status, status == 404 ? 'Stack was dissolved' : 'Stack metadata unavailable');
      when(() => assetApi.getStack('second')).thenThrow(failure);
      Future<void> selectedTrash() async {
        final covers = [first.first, second.first];
        final ids = await assets.resolveStackTrashIds(covers.map((asset) => asset.id).toList(), covers);
        await assets.trash(ids);
      }

      await expectLater(selectedTrash(), throwsA(same(failure)));
      verifyInOrder([() => assetApi.getStack('first'), () => assetApi.getStack('second')]);
      verifyNever(() => assetApi.delete(any(), any()));
      expect(await assets.getTrashIds(owner), isEmpty);
      expect(await context.db.select(context.db.remoteAssetEntity).get(), hasLength(5));
      await expectNoDeviceMutation(5);
    });
  }

  test('unselected or unstacked candidates cannot expand the selected UUID list', () async {
    final members = await seedStack(2);
    expect(await assets.resolveStackTrashIds(['standalone', 'standalone'], [members.first]), ['standalone']);
    expect(await assets.resolveStackTrashIds([], [members.first]), isEmpty);
    await context.newRemoteAsset(id: 'flat', ownerId: owner);
    final flat = (await remote.get('flat'))!;
    expect(await assets.resolveStackTrashIds([flat.id], [flat]), [flat.id]);
    verifyNever(() => assetApi.getStack(any()));
    verifyNever(() => assetApi.delete(any(), any()));
    await expectNoDeviceMutation(2);
  });

  test('resolved membership does not turn an unselected stale candidate into another selected stack', () async {
    final members = await seedStack(2);
    final staleCandidate = members.last.copyWith(stackId: 'not-selected');

    final result = await assets.resolveStackTrashIds([members.first.id], [members.first, staleCandidate]);

    expect(result, unorderedEquals(members.map((asset) => asset.id)));
    verify(() => assetApi.getStack('stack')).called(1);
    verifyNever(() => assetApi.getStack('not-selected'));
    verifyNever(() => assetApi.delete(any(), any()));
    await expectNoDeviceMutation(2);
  });
}
