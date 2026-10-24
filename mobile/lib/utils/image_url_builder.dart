import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:openapi/api.dart';

String getOriginalUrlForRemoteId(final String id, {bool edited = true, String? serverEndpoint, String? cacheKey}) {
  return _assetMediaUrl(id, 'original', {
    'edited': '$edited',
    if (cacheKey != null && cacheKey.isNotEmpty) 'c': cacheKey,
  }, serverEndpoint: serverEndpoint);
}

String getThumbnailUrlForRemoteId(
  final String id, {
  AssetMediaSize type = AssetMediaSize.thumbnail,
  bool edited = true,
  String? thumbhash,
  String? serverEndpoint,
}) {
  return _assetMediaUrl(id, 'thumbnail', {
    'size': '$type',
    'edited': '$edited',
    if (thumbhash != null && thumbhash.isNotEmpty) 'c': thumbhash,
  }, serverEndpoint: serverEndpoint);
}

String _assetMediaUrl(String id, String resource, Map<String, String> query, {String? serverEndpoint}) {
  if (id.isEmpty) {
    throw ArgumentError.value(id, 'id', 'A remote asset ID is required');
  }
  final endpoint = Uri.parse(serverEndpoint ?? Store.get(StoreKey.serverEndpoint));
  return endpoint
      .removeFragment()
      .replace(
        pathSegments: [...endpoint.pathSegments.where((segment) => segment.isNotEmpty), 'assets', id, resource],
        queryParameters: query,
      )
      .toString();
}

String getPlaybackUrlForRemoteId(final String id) {
  return '${Store.get(StoreKey.serverEndpoint)}/assets/$id/video/playback?';
}

String getFaceThumbnailUrl(final String personId, {DateTime? updatedAt}) {
  final url = '${Store.get(StoreKey.serverEndpoint)}/people/$personId/thumbnail';
  return updatedAt != null ? '$url?c=${updatedAt.millisecondsSinceEpoch}' : url;
}

/// Thumbnail for a Space-scoped person. Its [personId] is a `shared_space_person` id with no
/// row in the owner-only `person` table, so `getFaceThumbnailUrl` (GET /people/{id}/thumbnail)
/// 404s for it. This routes to the membership-gated space endpoint instead, mirroring the web
/// People page (`getGlobalPersonThumbnailUrl`).
String getSpacePersonThumbnailUrl(final String spaceId, final String personId, {DateTime? updatedAt}) {
  final url = '${Store.get(StoreKey.serverEndpoint)}/shared-spaces/$spaceId/people/$personId/thumbnail';
  return updatedAt != null ? '$url?c=${updatedAt.millisecondsSinceEpoch}' : url;
}

/// Selects the correct thumbnail URL for a person by profile scope: a Space-scoped person
/// (non-null [spaceId]) routes to the space endpoint, a personal/owned person to the owner
/// endpoint. Mirrors the web `getGlobalPersonThumbnailUrl`.
String getPersonThumbnailUrl(final String personId, {final String? spaceId, final DateTime? updatedAt}) {
  return spaceId == null
      ? getFaceThumbnailUrl(personId, updatedAt: updatedAt)
      : getSpacePersonThumbnailUrl(spaceId, personId, updatedAt: updatedAt);
}

/// Thumbnail URL for a photos-filter [FilterPerson] whose id is the tokenized filter id
/// (`person:<uuid>` / `space-person:<uuid>`) the picker/recent/chip surfaces store, with the
/// Space scope carried separately in [spaceId]. De-tokenizes to the raw profile id, then routes a
/// Space person (non-null [spaceId]) to the membership-gated space endpoint and everyone else to
/// the owner endpoint — the tokenized id 404s the owner endpoint for Space people. Mirrors web
/// getPhotosPersonFilterThumbnailUrl.
String getFilterPersonThumbnailUrl(final String filterPersonId, {final String? spaceId}) {
  const spacePrefix = 'space-person:';
  const personPrefix = 'person:';
  final rawId = filterPersonId.startsWith(spacePrefix)
      ? filterPersonId.substring(spacePrefix.length)
      : filterPersonId.startsWith(personPrefix)
      ? filterPersonId.substring(personPrefix.length)
      : filterPersonId;
  return getPersonThumbnailUrl(rawId, spaceId: spaceId);
}

/// Thumbnail URL for a photos-filter suggestion person. When the filter requests shared spaces
/// (`withSharedSpaces: true`) the server returns a tokenized [FilterSuggestionsPersonDto.id]
/// (`person:<uuid>` / `space-person:<uuid>`) whose raw form 404s through [getFaceThumbnailUrl];
/// route via [FilterSuggestionsPersonDto.primaryProfile] instead — a space person to the
/// membership-gated space endpoint, otherwise the owner endpoint keyed on the raw profile id.
/// Mirrors the web `getPhotosPersonFilterThumbnailUrl`.
String photosFilterPersonThumbnailUrl(final FilterSuggestionsPersonDto person) {
  final profile = person.primaryProfile.orElse(null);
  if (profile != null) {
    final spaceId = profile.spaceId.orElse(null);
    if (profile.type == ScopedPrimaryProfileTypeEnum.spacePerson && spaceId != null) {
      return getSpacePersonThumbnailUrl(spaceId, profile.id);
    }
    return getFaceThumbnailUrl(profile.id);
  }
  const personPrefix = 'person:';
  final id = person.id.startsWith(personPrefix) ? person.id.substring(personPrefix.length) : person.id;
  return getFaceThumbnailUrl(id);
}
