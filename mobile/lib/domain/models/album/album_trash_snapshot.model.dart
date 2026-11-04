import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/deletion_snapshot.model.dart';

class AlbumTrashScopeException implements Exception {
  const AlbumTrashScopeException();
}

/// Complete, server-read private-album membership. This is not a local count or
/// permission inferred from the album's owner alone.
class AlbumTrashSnapshot {
  const AlbumTrashSnapshot({
    required this.id,
    required this.name,
    required this.ownerId,
    required this.updatedAt,
    required this.assets,
  });

  final String id;
  final String name;
  final String ownerId;
  final DateTime updatedAt;
  final List<RemoteAsset> assets;

  List<String> get assetIds => assets.map((asset) => asset.id).toList(growable: false);

  bool matches(AlbumTrashSnapshot other) =>
      id == other.id &&
      name == other.name &&
      ownerId == other.ownerId &&
      updatedAt == other.updatedAt &&
      (assets.isEmpty ? other.assets.isEmpty : DeletionSnapshot(assets).matches(other.assets));
}
