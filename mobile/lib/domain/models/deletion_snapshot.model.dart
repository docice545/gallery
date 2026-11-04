import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';

/// A deletion names exact files, never mutable model equality or list indexes.
/// Missing rows, duplicate IDs and two representations of one file fail closed.
class DeletionSnapshot {
  final List<BaseAsset> assets;

  DeletionSnapshot(Iterable<BaseAsset> assets) : assets = List.unmodifiable(assets);

  static (bool, String) _key(BaseAsset asset) => (asset is RemoteAsset, asset.id);

  static Object _fingerprint(BaseAsset asset) => (
    _key(asset),
    asset.localId,
    asset.remoteId,
    asset.name,
    asset.checksum,
    asset.type,
    asset.createdAt,
    asset.updatedAt,
    switch (asset) {
      RemoteAsset() => (asset.ownerId, asset.stackId, asset.deletedAt, asset.isIndexTombstone, asset.visibility),
      LocalAsset() => null,
    },
  );

  bool get isUnambiguous {
    if (assets.isEmpty) return false;
    final keys = <(bool, String)>{};
    final localIds = <String>{};
    final remoteIds = <String>{};
    for (final asset in assets) {
      if (asset.id.isEmpty || !keys.add(_key(asset))) return false;
      if (asset.localId case final String id) {
        if (!localIds.add(id)) return false;
      }
      if (asset.remoteId case final String id) {
        if (!remoteIds.add(id)) return false;
      }
    }
    return true;
  }

  bool matches(Iterable<BaseAsset> current) {
    final next = DeletionSnapshot(current);
    if (!isUnambiguous || !next.isUnambiguous || assets.length != next.assets.length) return false;
    final fingerprints = {for (final asset in assets) _key(asset): _fingerprint(asset)};
    return next.assets.every((asset) => fingerprints[_key(asset)] == _fingerprint(asset));
  }

  /// Sequential reads bound work for large selections. Callers recheck the
  /// selection/account/route after this await and immediately before submission.
  Future<bool> matchesStored(Future<BaseAsset?> Function(BaseAsset) read) async {
    if (!isUnambiguous) return false;
    for (final asset in assets) {
      final stored = await read(asset);
      if (stored == null || _fingerprint(stored) != _fingerprint(asset)) return false;
    }
    return true;
  }
}
