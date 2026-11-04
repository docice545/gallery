import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/album/album.model.dart';
import 'package:immich_mobile/domain/models/album/album_trash_snapshot.model.dart';
import 'package:immich_mobile/extensions/asset_extensions.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/repositories/api.repository.dart';
import 'package:immich_mobile/services/api.service.dart';
// ignore: import_rule_openapi
import 'package:openapi/api.dart' hide AlbumUserRole;

final albumApiRepositoryProvider = Provider((ref) => AlbumApiRepository(ref.watch(apiServiceProvider)));

class AlbumApiRepository extends ApiRepository {
  final ApiService _apiService;

  AlbumApiRepository(this._apiService);

  AlbumsApi get _api => _apiService.albumsApi;

  Future<RemoteAlbum> createDriftAlbum(
    String name,
    UserDto owner, {
    required Iterable<String> assetIds,
    String? description,
  }) async {
    final responseDto = await checkNull(
      _api.createAlbum(
        CreateAlbumDto(
          albumName: name,
          description: description == null
              ? const Optional.absent()
              : Optional.present(description.isEmpty ? null : description),
          assetIds: Optional.present(assetIds.toList()),
        ),
      ),
    );

    return responseDto.toRemoteAlbum(owner);
  }

  Future<({List<String> removed, List<String> failed})> removeAssets(String albumId, Iterable<String> assetIds) async {
    final response = await checkNull(_api.removeAssetFromAlbum(albumId, BulkIdsDto(ids: assetIds.toList())));
    final List<String> removed = [];
    final List<String> failed = [];
    for (final dto in response) {
      if (dto.success) {
        removed.add(dto.id);
      } else {
        failed.add(dto.id);
      }
    }
    return (removed: removed, failed: failed);
  }

  Future<({List<String> added, List<String> failed})> addAssets(
    String albumId,
    Iterable<String> assetIds, {
    Future<void>? abortTrigger,
  }) async {
    final response = await checkNull(
      _api.addAssetsToAlbum(albumId, BulkIdsDto(ids: assetIds.toList()), abortTrigger: abortTrigger),
    );
    final List<String> added = [];
    final List<String> failed = [];
    for (final dto in response) {
      if (dto.success) {
        added.add(dto.id);
      } else if (dto.error.orElse(null) != BulkIdErrorReason.duplicate) {
        failed.add(dto.id);
      }
    }

    return (added: added, failed: failed);
  }

  Future<RemoteAlbum> updateAlbum(
    String albumId,
    UserDto owner, {
    String? name,
    String? description,
    String? thumbnailAssetId,
    bool? isActivityEnabled,
    AlbumAssetOrder? order,
    DateTime? createdAt,
  }) async {
    AssetOrder? apiOrder;
    if (order != null) {
      apiOrder = order == AlbumAssetOrder.asc ? AssetOrder.asc : AssetOrder.desc;
    }

    final responseDto = await checkNull(
      _api.updateAlbumInfo(
        albumId,
        UpdateAlbumDto(
          albumName: name == null ? const Optional.absent() : Optional.present(name),
          description: description == null
              ? const Optional.absent()
              : Optional.present(description.isEmpty ? null : description),
          createdAt: createdAt == null ? const Optional.absent() : Optional.present(createdAt),
          albumThumbnailAssetId: thumbnailAssetId == null
              ? const Optional.absent()
              : Optional.present(thumbnailAssetId),
          isActivityEnabled: isActivityEnabled == null ? const Optional.absent() : Optional.present(isActivityEnabled),
          order: apiOrder == null ? const Optional.absent() : Optional.present(apiOrder),
        ),
      ),
    );

    return responseDto.toRemoteAlbum(owner);
  }

  /// Fetch every active member from the server, without stack collapsing or
  /// trusting an incomplete Drift sync. Shared/external/mixed-owner albums are
  /// rejected as a whole; metadata deletion must never masquerade as trash.
  Future<AlbumTrashSnapshot> getTrashSnapshot(String albumId, String userId) async {
    bool privateOwned(AlbumResponseDto album) =>
        album.id == albumId &&
        album.albumUsers.isNotEmpty &&
        album.albumUsers.first.user.id == userId &&
        !album.shared &&
        !album.hasSharedLink &&
        (album.sharedSpaceLinks.orElse(null) ?? []).isEmpty;
    final album = await checkNull(_api.getAlbumInfo(albumId));
    if (!privateOwned(album)) {
      throw const AlbumTrashScopeException();
    }
    final items = <AssetResponseDto>[];
    final seen = <String>{};
    var page = 1;
    while (album.assetCount > 0) {
      final result = await checkNull(
        _apiService.searchApi.searchAssets(
          MetadataSearchDto(
            albumIds: Optional.present([albumId]),
            isTrashed: const Optional.present(false),
            page: Optional.present(page),
            size: const Optional.present(1000),
          ),
        ),
      );
      for (final item in result.assets.items) {
        if (!seen.add(item.id) || item.ownerId != userId || item.libraryId.orElse(null) != null || item.isTrashed) {
          throw const AlbumTrashScopeException();
        }
        items.add(item);
      }
      if (items.length > album.assetCount) {
        throw const AlbumTrashScopeException();
      }
      final next = result.assets.nextPage;
      if (next == null) {
        break;
      }
      if (result.assets.items.isEmpty || int.tryParse(next) != page + 1) {
        throw const AlbumTrashScopeException();
      }
      page++;
    }
    final current = await checkNull(_api.getAlbumInfo(albumId));
    if (!privateOwned(current) ||
        current.updatedAt != album.updatedAt ||
        current.assetCount != album.assetCount ||
        items.length != album.assetCount) {
      throw const AlbumTrashScopeException();
    }
    return AlbumTrashSnapshot(
      id: album.id,
      name: album.albumName,
      ownerId: userId,
      updatedAt: album.updatedAt,
      assets: List.unmodifiable(items.map((item) => item.toDto())),
    );
  }

  Future<void> deleteAlbum(String albumId) {
    return _api.deleteAlbum(albumId);
  }

  Future<void> addUsers(String albumId, Iterable<String> userIds) async {
    final albumUsers = userIds.map((userId) => AlbumUserAddDto(userId: userId)).toList();
    await checkNull(_api.addUsersToAlbum(albumId, AddUsersDto(albumUsers: albumUsers)));
  }

  Future<void> removeUser(String albumId, {required String userId}) async {
    await _api.removeUserFromAlbum(albumId, userId);
  }

  Future<bool> setActivityStatus(String albumId, bool isEnabled) async {
    final response = await checkNull(
      _api.updateAlbumInfo(albumId, UpdateAlbumDto(isActivityEnabled: Optional.present(isEnabled))),
    );
    return response.isActivityEnabled;
  }

  /// The shared spaces [albumId] is linked into (M8: owner recourse to view/revoke).
  ///
  /// `AlbumResponseDto.sharedSpaceLinks` is owner-only and NOT part of the Drift sync
  /// stream (see `RemoteAlbum` — no such field), so it must be fetched live via
  /// `GET /albums/:id`. The server omits the field entirely for non-owner callers and
  /// for an album with no links (album.service.ts, rbac-6), in which case this returns
  /// an empty list rather than null.
  Future<List<AlbumSharedSpaceLinkResponseDto>> getSharedSpaceLinks(String albumId) async {
    final response = await checkNull(_api.getAlbumInfo(albumId));
    return response.sharedSpaceLinks.orElse(null) ?? const [];
  }
}

extension on AlbumResponseDto {
  RemoteAlbum toRemoteAlbum(final UserDto user) {
    return RemoteAlbum(
      id: id,
      name: albumName,
      ownerId: user.id,
      ownerName: user.name,
      description: description,
      createdAt: createdAt,
      updatedAt: updatedAt,
      thumbnailAssetId: albumThumbnailAssetId,
      isActivityEnabled: isActivityEnabled,
      order: order.orElse(null) == AssetOrder.asc ? AlbumAssetOrder.asc : AlbumAssetOrder.desc,
      assetCount: assetCount,
      isShared: albumUsers.length > 2,
    );
  }
}
