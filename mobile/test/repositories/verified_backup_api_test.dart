import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/repositories/asset_api.repository.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart';

import '../unit/factories/local_asset_factory.dart';

class _Service extends Mock implements ApiService {}

class _Assets extends Mock implements AssetsApi {}

AssetResponseDto remote(String id, {String? pair}) => AssetResponseDto(
  checksum: 'checksum',
  createdAt: DateTime(2020),
  duration: null,
  fileCreatedAt: DateTime(2020),
  fileModifiedAt: DateTime(2020),
  hasMetadata: true,
  height: 64,
  id: id,
  isArchived: false,
  isEdited: false,
  isFavorite: false,
  isOffline: false,
  isTrashed: false,
  localDateTime: DateTime(2020),
  originalFileName: 'synthetic.jpg',
  originalPath: '/synthetic.jpg',
  ownerId: 'owner',
  thumbhash: null,
  type: AssetTypeEnum.IMAGE,
  updatedAt: DateTime(2020),
  visibility: AssetVisibility.timeline,
  width: 64,
  livePhotoVideoId: Optional.present(pair),
  exifInfo: Optional.present(ExifResponseDto(fileSizeInByte: const Optional.present(128))),
);

void main() {
  late _Assets assets;
  late AssetApiRepository repository;
  late AssetResponseDto still;
  late AssetResponseDto video;
  late List<http.Request> heads;
  late int status;
  late String length;
  final local = LocalAssetFactory.create(id: 'local', remoteId: 'remote').copyWith(checksum: 'checksum');

  setUp(() {
    final service = _Service();
    assets = _Assets();
    still = remote('remote');
    video = remote('video')..type = AssetTypeEnum.VIDEO;
    heads = [];
    status = 200;
    length = '128';
    final client = ApiClient(basePath: 'https://fixture.invalid/api');
    client.client = MockClient((request) async {
      heads.add(request);
      return http.Response('', status, headers: {'content-length': length});
    });
    addTearDown(client.client.close);
    when(() => service.assetsApi).thenReturn(assets);
    when(() => service.apiClient).thenReturn(client);
    when(() => assets.getAssetInfo('remote')).thenAnswer((_) async => still);
    when(() => assets.getAssetInfo('video')).thenAnswer((_) async => video);
    repository = AssetApiRepository(service);
  });

  test('fresh owner/hash metadata and uncached original HEAD are both required', () async {
    expect(await repository.hasVerifiedBackup(local, 'owner'), isTrue);
    verify(() => assets.getAssetInfo('remote')).called(1);
    expect(heads.single.method, 'HEAD');
    expect(heads.single.url.path, '/api/assets/remote/original');
    expect(heads.single.url.queryParameters, {'edited': 'false'});
    expect(heads.single.headers['cache-control'], 'no-cache');
  });

  for (final reason in ['owner', 'hash', 'offline', 'trash', 'deleted', 'favorite', 'id']) {
    test('$reason mismatch prevents original access and device removal admission', () async {
      switch (reason) {
        case 'owner':
          still.ownerId = 'other';
        case 'hash':
          still.checksum = 'changed';
        case 'offline':
          still.isOffline = true;
        case 'trash':
          still.isTrashed = true;
        case 'deleted':
          still.deletedAt = Optional.present(DateTime(2026));
        case 'favorite':
          still.isFavorite = true;
        case 'id':
          still.id = 'other';
      }
      expect(await repository.hasVerifiedBackup(local, 'owner'), isFalse);
      expect(heads, isEmpty);
    });
  }
  for (final code in [403, 404, 500]) {
    test('original HTTP $code fails closed', () async {
      status = code;
      expect(await repository.hasVerifiedBackup(local, 'owner'), isFalse);
    });
  }
  for (final bytes in ['', '0', '127']) {
    test('missing, zero or inconsistent original size fails closed ($bytes)', () async {
      length = bytes;
      expect(await repository.hasVerifiedBackup(local, 'owner'), isFalse);
    });
  }
  test('missing remote ID or hash never triggers a request', () async {
    expect(await repository.hasVerifiedBackup(LocalAssetFactory.create(), 'owner'), isFalse);
    expect(await repository.hasVerifiedBackup(LocalAssetFactory.create(remoteId: 'remote'), 'owner'), isFalse);
    verifyNever(() => assets.getAssetInfo(any()));
  });
  test('local Live Photo needs both linked server originals', () async {
    final live = local.copyWith(playbackStyle: .livePhoto);
    expect(await repository.hasVerifiedBackup(live, 'owner'), isFalse);
    still.livePhotoVideoId = const Optional.present('video');
    heads.clear();
    expect(await repository.hasVerifiedBackup(live, 'owner'), isTrue);
    expect(heads.map((r) => r.url.path), ['/api/assets/remote/original', '/api/assets/video/original']);
  });
  for (final reason in ['owner', 'offline', 'trash', 'type', 'original']) {
    test('unavailable Live Photo companion ($reason) preserves device pair', () async {
      still.livePhotoVideoId = const Optional.present('video');
      switch (reason) {
        case 'owner':
          video.ownerId = 'other';
        case 'offline':
          video.isOffline = true;
        case 'trash':
          video.isTrashed = true;
        case 'type':
          video.type = AssetTypeEnum.IMAGE;
        case 'original':
          video.exifInfo = Optional.present(ExifResponseDto(fileSizeInByte: const Optional.present(256)));
      }
      expect(await repository.hasVerifiedBackup(local.copyWith(playbackStyle: .livePhoto), 'owner'), isFalse);
    });
  }
  test('explicit favorite inclusion permits a verified favorite', () async {
    still.isFavorite = true;
    expect(await repository.hasVerifiedBackup(local, 'owner', keepFavorites: false), isTrue);
  });
}
