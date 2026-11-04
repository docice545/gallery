import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';

import '../../factories/local_asset_factory.dart';
import '../../factories/remote_asset_factory.dart';

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
}
