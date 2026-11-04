import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/album/album_trash_snapshot.model.dart';
import 'package:immich_mobile/repositories/album_api_repository.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart' as api;

class _Albums extends Mock implements api.AlbumsApi {}

class _Search extends Mock implements api.SearchApi {}

class _Service extends Mock implements ApiService {}

class _Response extends Mock implements api.SearchResponseDto {}

void main() {
  late _Albums albums;
  late _Search search;
  late AlbumApiRepository repository;
  final date = DateTime.utc(2026);
  api.AlbumResponseDto album({int count = 2, bool shared = false, String owner = 'owner'}) => api.AlbumResponseDto(
    id: 'album',
    albumName: 'Private album',
    albumThumbnailAssetId: null,
    assetCount: count,
    createdAt: date,
    updatedAt: date,
    description: '',
    hasSharedLink: false,
    isActivityEnabled: false,
    shared: shared,
    albumUsers: [
      api.AlbumUserResponseDto(
        role: api.AlbumUserRole.owner,
        user: api.UserResponseDto(
          id: owner,
          email: 'fixture@example.test',
          name: owner,
          avatarColor: api.UserAvatarColor.primary,
          profileChangedAt: date,
          profileImagePath: '',
        ),
      ),
    ],
  );

  api.AssetResponseDto asset(String id, {String owner = 'owner', String? library}) => api.AssetResponseDto(
    id: id,
    ownerId: owner,
    checksum: 'checksum-$id',
    createdAt: date,
    fileCreatedAt: date,
    fileModifiedAt: date,
    localDateTime: date,
    updatedAt: date,
    duration: null,
    hasMetadata: true,
    height: 100,
    width: 100,
    isArchived: false,
    isEdited: false,
    isFavorite: false,
    isOffline: false,
    isTrashed: false,
    originalFileName: '$id.jpg',
    originalPath: '/synthetic/$id.jpg',
    thumbhash: null,
    type: api.AssetTypeEnum.IMAGE,
    visibility: api.AssetVisibility.timeline,
    libraryId: library == null ? const api.Optional.absent() : api.Optional.present(library),
  );

  api.SearchResponseDto page(List<api.AssetResponseDto> assets, {String? next}) {
    final response = _Response();
    when(
      () => response.assets,
    ).thenReturn(api.SearchAssetResponseDto(count: assets.length, total: assets.length, items: assets, nextPage: next));
    return response;
  }

  setUpAll(() => registerFallbackValue(api.MetadataSearchDto()));
  setUp(() {
    albums = _Albums();
    search = _Search();
    final service = _Service();
    when(() => service.albumsApi).thenReturn(albums);
    when(() => service.searchApi).thenReturn(search);
    repository = AlbumApiRepository(service);
    when(() => albums.getAlbumInfo('album')).thenAnswer((_) async => album());
  });
  tearDown(() => verifyNever(() => albums.deleteAlbum(any())));

  test('complete paginated membership uses explicit album scope and never collapses a stack', () async {
    final calls = <api.MetadataSearchDto>[];
    when(() => search.searchAssets(any())).thenAnswer((call) async {
      final request = call.positionalArguments.single as api.MetadataSearchDto;
      calls.add(request);
      return request.page.orElse(null) == 1 ? page([asset('a')], next: '2') : page([asset('b')]);
    });
    final snapshot = await repository.getTrashSnapshot('album', 'owner');
    expect(snapshot.assetIds, ['a', 'b']);
    expect(calls.map((call) => call.page.orElse(null)), [1, 2]);
    for (final call in calls) {
      expect(call.albumIds.orElse(null), ['album']);
      expect(call.withDeleted.orElse(null), false);
      expect(call.withStacked.orElse(null), true);
    }
    verify(() => albums.getAlbumInfo('album')).called(2);
  });

  for (final scenario in ['foreign-owner', 'shared', 'missing-row', 'duplicate', 'foreign-asset', 'external']) {
    test('$scenario cannot produce a partial destructive selection', () async {
      when(() => albums.getAlbumInfo('album')).thenAnswer(
        (_) async =>
            album(shared: scenario == 'shared', owner: scenario == 'foreign-owner' ? 'another-owner' : 'owner'),
      );
      when(() => search.searchAssets(any())).thenAnswer(
        (_) async => page([
          asset('a'),
          if (scenario != 'missing-row')
            asset(
              scenario == 'duplicate' ? 'a' : 'b',
              owner: scenario == 'foreign-asset' ? 'another-owner' : 'owner',
              library: scenario == 'external' ? 'external-library' : null,
            ),
        ]),
      );
      await expectLater(repository.getTrashSnapshot('album', 'owner'), throwsA(isA<AlbumTrashScopeException>()));
    });
  }

  test('membership changing during pagination is rejected', () async {
    var calls = 0;
    when(() => albums.getAlbumInfo('album')).thenAnswer((_) async => album(count: calls++ == 0 ? 2 : 3));
    when(() => search.searchAssets(any())).thenAnswer((_) async => page([asset('a'), asset('b')]));
    await expectLater(repository.getTrashSnapshot('album', 'owner'), throwsA(isA<AlbumTrashScopeException>()));
  });

  test('an empty private album performs no asset search', () async {
    when(() => albums.getAlbumInfo('album')).thenAnswer((_) async => album(count: 0));
    expect((await repository.getTrashSnapshot('album', 'owner')).assetIds, isEmpty);
    verifyNever(() => search.searchAssets(any()));
  });
}
