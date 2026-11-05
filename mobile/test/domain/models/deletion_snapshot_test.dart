import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/deletion_snapshot.model.dart';

import '../../unit/factories/local_asset_factory.dart';
import '../../unit/factories/remote_asset_factory.dart';

void main() {
  test('server metadata updates preserve identity, local file replacement does not', () {
    final remote = RemoteAssetFactory.create();
    final local = LocalAssetFactory.create();
    expect(
      DeletionSnapshot([remote]).matches([
        remote.copyWith(updatedAt: remote.updatedAt.add(const Duration(seconds: 1)), isFavorite: !remote.isFavorite),
      ]),
      isTrue,
    );
    expect(
      DeletionSnapshot([local]).matches([local.copyWith(updatedAt: local.updatedAt.add(const Duration(seconds: 1)))]),
      isFalse,
    );
  });

  test('order and refreshed objects do not change exact identity', () {
    final a = LocalAssetFactory.create();
    final b = RemoteAssetFactory.create();
    expect(DeletionSnapshot([a, b]).matches([b.copyWith(), a.copyWith()]), isTrue);
    expect(DeletionSnapshot([a, b]).matches([a]), isFalse);
    expect(DeletionSnapshot([a]).matches([a, b]), isFalse);
  });

  test('duplicates and linked local/remote representations are ambiguous', () {
    final remote = RemoteAssetFactory.create(localId: 'phone');
    final local = LocalAssetFactory.create(id: 'phone', remoteId: remote.id);
    expect(DeletionSnapshot([remote, remote]).isUnambiguous, isFalse);
    expect(DeletionSnapshot([local, remote]).isUnambiguous, isFalse);
    expect(DeletionSnapshot([]).isUnambiguous, isFalse);
  });

  test('checksum, ownership, trash, stack and identity changes expire consent', () {
    final asset = RemoteAssetFactory.create(localId: 'phone');
    final snapshot = DeletionSnapshot([asset]);
    for (final changed in [
      asset.copyWith(checksum: 'replacement'),
      asset.copyWith(ownerId: 'another-owner'),
      asset.copyWith(stackId: 'new-stack'),
      asset.copyWith(deletedAt: DateTime(2026)),
      asset.copyWith(id: 'replacement-id'),
      asset.copyWith(localId: 'another-phone-file'),
      asset.copyWith(livePhotoVideoId: 'replacement-motion-pair'),
    ]) {
      expect(snapshot.matches([changed]), isFalse);
    }
  });

  test('missing or replaced persisted rows cannot authorize deletion', () async {
    final a = LocalAssetFactory.create();
    final b = RemoteAssetFactory.create();
    final snapshot = DeletionSnapshot([a, b]);
    expect(await snapshot.matchesStored((asset) async => asset), isTrue);
    expect(await snapshot.matchesStored((asset) async => asset is RemoteAsset ? null : asset), isFalse);
    expect(await snapshot.matchesStored((asset) async => asset == a ? a.copyWith(checksum: 'new') : asset), isFalse);
  });
}
