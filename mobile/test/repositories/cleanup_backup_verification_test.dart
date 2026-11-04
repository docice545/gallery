import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/repositories/asset_api.repository.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart' as api;

class _Api extends Mock implements api.AssetsApi {}

class _Service extends Mock implements ApiService {}

class _Info extends Mock implements api.AssetResponseDto {}

void main() {
  late _Api assets;
  late AssetApiRepository repository;
  late _Info still;
  late _Info motion;
  var originalStatus = 200;
  final originalRequests = <http.Request>[];
  LocalAsset local({bool live = true}) => LocalAsset(
    id: 'phone',
    remoteId: 'still',
    name: 'synthetic.jpg',
    checksum: 'matching-checksum',
    type: AssetType.image,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
    playbackStyle: live ? AssetPlaybackStyle.livePhoto : AssetPlaybackStyle.image,
    isEdited: false,
  );
  setUp(() {
    assets = _Api();
    final service = _Service();
    when(() => service.assetsApi).thenReturn(assets);
    originalStatus = 200;
    originalRequests.clear();
    final client = api.ApiClient(basePath: 'https://synthetic.invalid/api')
      ..client = MockClient((request) async {
        originalRequests.add(request);
        return http.Response('', originalStatus, headers: {'content-length': '4096'});
      });
    when(() => service.apiClient).thenReturn(client);
    repository = AssetApiRepository(service);
    still = _Info();
    motion = _Info();
    for (final info in [still, motion]) {
      when(() => info.ownerId).thenReturn('owner');
      when(() => info.isOffline).thenReturn(false);
      when(() => info.isTrashed).thenReturn(false);
    }
    when(() => still.checksum).thenReturn('matching-checksum');
    when(() => still.livePhotoVideoId).thenReturn(const api.Optional.present('motion'));
    when(() => motion.type).thenReturn(api.AssetTypeEnum.VIDEO);
    when(() => assets.getAssetInfo('still')).thenAnswer((_) async => still);
    when(() => assets.getAssetInfo('motion')).thenAnswer((_) async => motion);
  });
  test('verifies both members of a synthetic Live Photo pair', () async {
    expect(await repository.isCleanupBackupAvailable(local(), 'owner'), isTrue);
    verify(() => assets.getAssetInfo('motion')).called(1);
    expect(originalRequests.map((r) => r.method), ['HEAD', 'HEAD']);
    expect(originalRequests.every((r) => r.url.queryParameters['edited'] == 'false'), isTrue);
  });
  test('missing motion, unavailable motion and wrong-owner motion block cleanup', () async {
    when(() => still.livePhotoVideoId).thenReturn(const api.Optional.absent());
    expect(await repository.isCleanupBackupAvailable(local(), 'owner'), isFalse);
    when(() => still.livePhotoVideoId).thenReturn(const api.Optional.present('motion'));
    when(() => motion.isOffline).thenReturn(true);
    expect(await repository.isCleanupBackupAvailable(local(), 'owner'), isFalse);
    when(() => motion.isOffline).thenReturn(false);
    when(() => motion.ownerId).thenReturn('other-owner');
    expect(await repository.isCleanupBackupAvailable(local(), 'owner'), isFalse);
  });
  test('stale checksum, trash and network failures never authorize removal', () async {
    when(() => still.checksum).thenReturn('different');
    expect(await repository.isCleanupBackupAvailable(local(), 'owner'), isFalse);
    when(() => still.checksum).thenReturn('matching-checksum');
    when(() => still.isTrashed).thenReturn(true);
    expect(await repository.isCleanupBackupAvailable(local(), 'owner'), isFalse);
    when(() => assets.getAssetInfo('still')).thenThrow(StateError('offline'));
    expect(await repository.isCleanupBackupAvailable(local(), 'owner'), isFalse);
  });
  test('metadata without a downloadable original cannot authorize cleanup', () async {
    originalStatus = 404;
    expect(await repository.isCleanupBackupAvailable(local(), 'owner'), isFalse);
  });
  test('ordinary still requires no invented motion companion', () async {
    when(() => still.livePhotoVideoId).thenReturn(const api.Optional.absent());
    expect(await repository.isCleanupBackupAvailable(local(live: false), 'owner'), isTrue);
    verifyNever(() => assets.getAssetInfo('motion'));
  });
}
