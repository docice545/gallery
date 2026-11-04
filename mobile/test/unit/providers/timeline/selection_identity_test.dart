import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';
import 'package:mocktail/mocktail.dart';

import '../../factories/local_asset_factory.dart';
import '../../factories/remote_asset_factory.dart';

class _Timeline extends Mock implements TimelineService {}

void main() {
  late ProviderContainer container;
  late MultiSelectNotifier selection;

  setUp(() {
    container = ProviderContainer();
    selection = container.read(multiSelectProvider.notifier);
  });

  tearDown(() => container.dispose());

  List<String> ids() => container.read(multiSelectProvider).selectedAssets.map((asset) => asset.id).toList();

  test('a refreshed remote model still toggles only that selected ID off', () {
    final first = RemoteAssetFactory.create(id: 'first');
    final other = RemoteAssetFactory.create(id: 'other');
    selection.selectAsset(first);
    selection.selectAsset(other);
    selection.toggleAssetSelection(first.copyWith(isFavorite: true, localId: 'new-local-link'));
    expect(ids(), [other.id]);
  });

  test('refreshing a selected local ID does not duplicate it after its remote link arrives', () {
    final local = LocalAssetFactory.create(id: 'local');
    selection.selectAsset(local);
    selection.selectAsset(local.copyWith(remoteId: 'uploaded-copy', name: 'refreshed.jpg'));
    expect(ids(), [local.id]);
  });

  test('deselecting a refreshed model removes its ID without removing identical-looking photos', () {
    final first = RemoteAssetFactory.create(id: 'first');
    final second = first.copyWith(id: 'second');
    selection.selectAsset(first);
    selection.selectAsset(second);
    selection.deselectAsset(first.copyWith(updatedAt: first.updatedAt.add(const Duration(seconds: 1))));
    expect(ids(), [second.id]);
  });

  test('a date bucket toggles refreshed members by ID, not mutable model equality', () {
    final first = RemoteAssetFactory.create(id: 'first');
    final second = RemoteAssetFactory.create(id: 'second');
    selection.toggleBucketSelectionByAssets([first, second]);
    selection.toggleBucketSelectionByAssets([
      first.copyWith(isFavorite: true),
      second.copyWith(localId: 'new-device-link'),
    ]);
    expect(ids(), isEmpty);
  });

  test('device and server IDs have distinct identity domains', () {
    final local = LocalAssetFactory.create(id: 'same-id');
    final remote = RemoteAssetFactory.create(id: local.id);
    selection.selectAsset(local);
    selection.selectAsset(remote);
    expect(container.read(multiSelectProvider).selectedAssets, hasLength(2));
    selection.toggleAssetSelection(remote);
    expect(container.read(multiSelectProvider).selectedAssets.single, isA<LocalAsset>());
  });

  test('rapid one-many-one toggles preserve only the explicitly selected IDs', () {
    final assets = List.generate(8, (index) => RemoteAssetFactory.create(id: 'asset-$index'));
    selection.toggleAssetSelection(assets.first);
    for (final asset in assets.skip(1)) {
      selection.toggleAssetSelection(asset);
    }
    for (final asset in assets.skip(1)) {
      selection.toggleAssetSelection(asset.copyWith(isFavorite: true));
    }
    expect(ids(), [assets.first.id]);
  });

  test('shrinking a drag preserves selections made before the gesture', () {
    final assets = List.generate(4, (index) => RemoteAssetFactory.create(id: 'asset-$index'));
    selection.selectAsset(assets.last);
    final baseline = container.read(multiSelectProvider).selectedIds;
    selection.updateDragSelection(baseline, assets);
    selection.updateDragSelection(baseline, [assets.first]);
    expect(ids(), unorderedEquals([assets.first.id, assets.last.id]));
  });

  for (final invalidate in ['tap', 'reset', 'refresh', 'dispose']) {
    test('an unfinished date-bucket load cannot select photos after $invalidate', () async {
      final timeline = _Timeline();
      final result = Completer<List<BaseAsset>>();
      when(() => timeline.loadAssets(0, 2)).thenAnswer((_) => result.future);
      final scoped = ProviderContainer(overrides: [timelineServiceProvider.overrideWithValue(timeline)]);
      final notifier = scoped.read(multiSelectProvider.notifier);
      final pending = notifier.toggleBucketSelection(0, 2);
      final other = RemoteAssetFactory.create(id: 'intentional-tap');
      switch (invalidate) {
        case 'tap':
          notifier.selectAsset(other);
        case 'reset':
          notifier.reset();
        case 'refresh':
          EventStream.shared.emit(const TimelineReloadEvent());
          await Future<void>.delayed(Duration.zero);
        case 'dispose':
          scoped.dispose();
      }
      result.complete([RemoteAssetFactory.create(id: 'stale-a'), RemoteAssetFactory.create(id: 'stale-b')]);
      await pending;
      if (invalidate != 'dispose') {
        expect(
          scoped.read(multiSelectProvider).selectedIds,
          invalidate == 'tap' ? {assetSelectionKey(other)} : isEmpty,
        );
        scoped.dispose();
      }
    });
  }

  test('a changed album route invalidates the pending bucket from the old album', () async {
    final oldAlbum = _Timeline();
    final nextAlbum = _Timeline();
    final result = Completer<List<BaseAsset>>();
    when(() => oldAlbum.loadAssets(0, 1)).thenAnswer((_) => result.future);
    final scoped = ProviderContainer(overrides: [timelineServiceProvider.overrideWithValue(oldAlbum)]);
    addTearDown(scoped.dispose);
    final pending = scoped.read(multiSelectProvider.notifier).toggleBucketSelection(0, 1);
    scoped.updateOverrides([timelineServiceProvider.overrideWithValue(nextAlbum)]);
    result.complete([RemoteAssetFactory.create(id: 'old-album-photo')]);
    await pending;
    expect(scoped.read(multiSelectProvider).selectedAssets, isEmpty);
  });
}
