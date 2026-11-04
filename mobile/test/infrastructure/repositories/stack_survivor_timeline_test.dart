import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/models/stack.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/models/timeline_temporal_scope.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline.repository.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../../medium/repository_context.dart';

Future<List<String>> _ids(TimelineQuery query) async => (await query.assetSource(0, 20)).map((a) => a.id).toList();

void main() {
  setUpAll(() => initializeDateFormatting('en'));

  for (final deleted in ['cover', 'child']) {
    test(
      'stack 2→1 deleting $deleted survives cache reload, restart, sync and restore without losing membership',
      () async {
        final directory = await Directory.systemTemp.createTemp('foto-stack-survivor-');
        final file = File('${directory.path}/fixture.sqlite');
        var ctx = MediumRepositoryContext(database: Drift(NativeDatabase(file)));
        addTearDown(() async {
          await ctx.dispose();
          await directory.delete(recursive: true);
        });
        await ctx.newUser(id: 'owner');
        await ctx.newAuthUser(id: 'owner');
        for (final id in ['cover', 'child']) {
          await ctx.newRemoteAsset(
            id: id,
            ownerId: 'owner',
            checksum: '$id-original-bytes',
            stackId: 'stack',
            livePhotoVideoId: '$id-motion',
            createdAt: DateTime(2026, 10, 26),
            width: 400,
            height: 300,
          );
        }
        await ctx.insertStack(id: 'stack', ownerId: 'owner', primaryAssetId: 'cover');
        var remote = RemoteAssetRepository(ctx.db);
        var repository = TimelineRepository(ctx.db);
        final reload = StreamIterator(EventStream.shared.where<TimelineReloadEvent>());
        final service = TimelineService(repository.main(['owner'], 'owner', GroupAssetsBy.day));
        try {
          expect(await reload.moveNext().timeout(const Duration(seconds: 3)), isTrue);
          expect(service.getAssetSafe(0)?.id, 'cover');
          final original = await remote.get(deleted);
          final survivor = deleted == 'cover' ? 'child' : 'cover';
          final pending = await remote.beginTrashOperation([deleted], restore: false);
          await remote.completeTrashOperation(pending, success: true);
          // No StacksV1 cover update or manual unStack call is supplied here.
          expect(await reload.moveNext().timeout(const Duration(seconds: 3)), isTrue);
          expect(service.totalAssets, 1);
          expect((await service.loadAssets(0, 10)).map((a) => a.id), [survivor]);
          expect(await remote.watchStackCounts().first, {'stack': 1});
          expect(await remote.getStackChildren((await remote.get(survivor))!), isEmpty);
          for (final group in [GroupAssetsBy.day, GroupAssetsBy.month, GroupAssetsBy.year]) {
            for (final scope in [const TimelineTemporalScope.none(), const TimelineTemporalScope.year(2026)]) {
              final query = repository.main(['owner'], 'owner', group, temporalScope: scope);
              expect(await _ids(query), [survivor]);
              expect((await query.bucketSource().first).fold<int>(0, (count, b) => count + b.assetCount), 1);
            }
          }
          expect(await _ids(repository.livePhotos(['owner'], 'owner', GroupAssetsBy.day)), [survivor]);
          final remaining = (await remote.get(survivor))!;
          expect(remaining.checksum, '$survivor-original-bytes');
          expect(remaining.livePhotoVideoId, '$survivor-motion');
          expect(remaining.stackId, 'stack', reason: 'retain only the history needed for restoration');
          expect((await remote.get(deleted))!.stackId, original!.stackId);
          expect(await _ids(repository.trash('owner', GroupAssetsBy.day)), [deleted]);
        } finally {
          await service.dispose();
          await reload.cancel();
        }

        // Reopen the persisted SQLite file with no server/network involved.
        await ctx.dispose();
        ctx = MediumRepositoryContext(database: Drift(NativeDatabase(file)));
        remote = RemoteAssetRepository(ctx.db);
        repository = TimelineRepository(ctx.db);
        final survivor = deleted == 'cover' ? 'child' : 'cover';
        expect(await _ids(repository.main(['owner'], 'owner', GroupAssetsBy.day)), [survivor]);
        expect(await remote.watchStackCounts().first, {'stack': 1});
        // A delayed authoritative cover is safe before and after restoration.
        await remote.stack('owner', StackResponse(id: 'stack', primaryAssetId: survivor, assetIds: [survivor]));
        expect(await _ids(repository.main(['owner'], 'owner', GroupAssetsBy.day)), [survivor]);
        expect((await remote.get(deleted))!.stackId, 'stack');
        await remote.restoreTrash([deleted]);
        expect(await remote.watchStackCounts().first, {'stack': 2});
        expect(await _ids(repository.main(['owner'], 'owner', GroupAssetsBy.day)), [survivor]);
        expect((await remote.getStackChildren((await remote.get(survivor))!)).map((a) => a.id), [deleted]);
        expect((await remote.get(deleted))!.checksum, '$deleted-original-bytes');
        expect((await remote.get(deleted))!.livePhotoVideoId, '$deleted-motion');
      },
    );

    test('stack 2→1 deleting $deleted restores its precise original presentation on definite rejection', () async {
      final ctx = MediumRepositoryContext();
      addTearDown(ctx.dispose);
      await ctx.newUser(id: 'owner');
      for (final id in ['cover', 'child']) {
        await ctx.newRemoteAsset(id: id, ownerId: 'owner', stackId: 'stack');
      }
      await ctx.insertStack(id: 'stack', ownerId: 'owner', primaryAssetId: 'cover');
      final remote = RemoteAssetRepository(ctx.db);
      final query = TimelineRepository(ctx.db).main(['owner'], 'owner', GroupAssetsBy.day);
      final pending = await remote.beginTrashOperation([deleted], restore: false);
      expect(await _ids(query), [deleted == 'cover' ? 'child' : 'cover']);
      await remote.completeTrashOperation(pending, success: false, definiteFailure: true);
      expect(await _ids(query), ['cover']);
      expect(await remote.watchStackCounts().first, {'stack': 2});
      expect((await remote.get(deleted))!.deletedAt, isNull);
    });
  }

  test('a deleted cover cannot promote Hidden or Locked resources into the main timeline', () async {
    final ctx = MediumRepositoryContext();
    addTearDown(ctx.dispose);
    await ctx.newUser(id: 'owner');
    await ctx.newRemoteAsset(id: 'cover', ownerId: 'owner', stackId: 'stack');
    await ctx.newRemoteAsset(id: 'hidden', ownerId: 'owner', stackId: 'stack', visibility: AssetVisibility.hidden);
    await ctx.newRemoteAsset(id: 'locked', ownerId: 'owner', stackId: 'stack', visibility: AssetVisibility.locked);
    await ctx.insertStack(id: 'stack', ownerId: 'owner', primaryAssetId: 'cover');
    await RemoteAssetRepository(ctx.db).trash(['cover']);
    expect(await _ids(TimelineRepository(ctx.db).main(['owner'], 'owner', GroupAssetsBy.day)), isEmpty);
  });
}
