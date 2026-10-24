import 'dart:async';
import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/remote_image_http_exception.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/platform/remote_image_api.g.dart';
import 'package:immich_mobile/presentation/widgets/images/image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/remote_image_provider.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';
import 'package:openapi/api.dart';

import '../../../fixtures/asset.stub.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Drift db;
  late StoreService store;
  late Future<Object?> Function(List<Object?>) response;
  final requested = <String>[];
  const channel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.RemoteImageApi.requestImage',
    RemoteImageApi.pigeonChannelCodec,
  );
  const cancelChannel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.RemoteImageApi.cancelRequest',
    RemoteImageApi.pigeonChannelCodec,
  );

  Future<Object?> encodedImage() async {
    final bytes = await File('assets/feature_message/ocr.webp').readAsBytes();
    final pointer = malloc<Uint8>(bytes.length)..asTypedList(bytes.length).setAll(0, bytes);
    return [
      <Object?, Object?>{'pointer': pointer.address, 'length': bytes.length},
    ];
  }

  List<Object?> notFound(String uri) => [
    'HTTP_ERROR',
    'Remote image request failed (HTTP 404)',
    {'statusCode': 404, 'requestPath': Uri.parse(uri).path, 'finalPath': Uri.parse(uri).path},
  ];

  Future<ImageInfo> resolve(ImageProvider provider) {
    final completer = Completer<ImageInfo>();
    final stream = provider.resolve(ImageConfiguration.empty);
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (image, _) => completer.complete(image),
      onError: (Object error, StackTrace? stack) => completer.completeError(error, stack),
    );
    stream.addListener(listener);
    return completer.future.whenComplete(() => stream.removeListener(listener));
  }

  RemoteFullImageProvider full({
    String? endpoint,
    String revision = 'revision',
    AssetType type = AssetType.image,
    Size? thumbnailSize,
  }) => RemoteFullImageProvider(
    assetId: 'asset-id',
    thumbhash: revision,
    assetType: type,
    isAnimated: false,
    thumbnailSize: thumbnailSize,
    serverEndpoint: endpoint,
  );

  setUpAll(() async {
    db = Drift(drift.DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    store = await StoreService.init(storeRepository: StoreRepository(db), listenUpdates: false);
    await SettingsRepository.ensureInitialized(db);
  });

  setUp(() async {
    await store.clear();
    await store.put(StoreKey.serverEndpoint, 'https://a.example.test/photos/api');
    await SettingsRepository.instance.clear([SettingsKey.imageLoadOriginal, SettingsKey.imagePreferRemote]);
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    requested.clear();
    response = (_) async => [null];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockDecodedMessageHandler(channel, (message) async {
      final args = (message! as List).cast<Object?>();
      requested.add(args[0]! as String);
      return await response(args);
    });
    messenger.setMockDecodedMessageHandler(cancelChannel, (_) async => [null]);
  });

  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockDecodedMessageHandler(channel, null);
    messenger.setMockDecodedMessageHandler(cancelChannel, null);
  });

  tearDownAll(() async {
    await SettingsRepository.reset();
    await store.dispose();
    await db.close();
  });

  test('same remote asset on different servers cannot share a full-image cache key', () async {
    final first = full();
    await store.put(StoreKey.serverEndpoint, 'https://b.example.test/api');
    final second = full();
    expect(first, isNot(second));
    expect(first.serverEndpoint, 'https://a.example.test/photos/api');
    expect(Uri.parse(first.previewUrl).host, 'a.example.test');
    expect(Uri.parse(first.originalUrl).host, 'a.example.test');
    expect(Uri.parse(second.previewUrl).host, 'b.example.test');
  });

  test('a provider keeps the captured endpoint through preview and original stages', () async {
    final provider = full();
    final preview = provider.previewUrl;
    final original = provider.originalUrl;
    await store.put(StoreKey.serverEndpoint, 'https://b.example.test/another/api');
    expect(provider.previewUrl, preview);
    expect(provider.originalUrl, original);
    expect(Uri.parse(original).path, '/photos/api/assets/asset-id/original');
    expect(Uri.parse(original).queryParameters['c'], 'revision');
  });

  test('full-image cache keys include media type and thumbnail decode size', () {
    final base = full();
    expect(base, isNot(full(type: AssetType.video)));
    expect(base, isNot(full(thumbnailSize: const Size.square(160))));
    expect(full(thumbnailSize: const Size.square(160)), isNot(full(thumbnailSize: const Size.square(320))));
    expect(base, full());
    expect(base.hashCode, full().hashCode);
  });

  test('a changed remote media revision invalidates native original and preview URLs', () {
    final old = full(revision: 'before');
    final refreshed = full(revision: 'after');
    expect(old, isNot(refreshed));
    expect(old.originalUrl, isNot(refreshed.originalUrl));
    expect(old.previewUrl, isNot(refreshed.previewUrl));
  });

  test('merged local assets request their remote ID rather than the MediaStore ID', () async {
    await SettingsRepository.instance.write(SettingsKey.imagePreferRemote, true);
    final merged = LocalAssetStub.image1.copyWith(id: '12345', remoteId: 'remote-id');
    final provider = getFullImageProvider(merged) as RemoteFullImageProvider;
    final thumb = getThumbnailImageProvider(merged)! as RemoteImageProvider;
    expect(provider.assetId, 'remote-id');
    expect(Uri.parse(provider.previewUrl).path, '/photos/api/assets/remote-id/thumbnail');
    expect(Uri.parse(thumb.url).path, '/photos/api/assets/remote-id/thumbnail');
  });

  test('asset IDs occupy one encoded URL segment and cannot inject a route or query', () {
    const id = 'id/another?key=secret#fragment';
    final url = Uri.parse(getThumbnailUrlForRemoteId(id, thumbhash: 'hash', type: AssetMediaSize.preview));
    expect(url.pathSegments[url.pathSegments.length - 2], id);
    expect(url.queryParameters, {'size': 'preview', 'edited': 'true', 'c': 'hash'});
    expect(url.hasFragment, isFalse);
    expect(() => getOriginalUrlForRemoteId(''), throwsArgumentError);
  });

  test('a 404 is not cached as a successful image and a later restore/resync can retry the same URL', () async {
    final url = getThumbnailUrlForRemoteId('retry-id');
    var first = true;
    response = (args) async {
      if (first) {
        first = false;
        return notFound(args[0]! as String);
      }
      return await encodedImage();
    };
    await expectLater(resolve(RemoteImageProvider(url: url)), throwsA(isA<RemoteImageHttpException>()));
    final image = await resolve(RemoteImageProvider(url: url));
    expect(image.image.width, greaterThan(0));
    expect(requested, [url, url]);
    image.dispose();
  });

  test('missing preview stays diagnostic and does not force original loading when disabled', () async {
    response = (args) async {
      final uri = args[0]! as String;
      return Uri.parse(uri).queryParameters['size'] == 'thumbnail' ? await encodedImage() : notFound(uri);
    };
    final stream = full().resolve(ImageConfiguration.empty);
    final failure = Completer<Object>();
    final images = <ImageInfo>[];
    final listener = ImageStreamListener(
      (image, _) => images.add(image),
      onError: (Object error, StackTrace? _) => failure.complete(error),
    );
    stream.addListener(listener);
    try {
      final error = await failure.future.timeout(const Duration(seconds: 5));
      expect(error, isA<RemoteImageHttpException>().having((e) => e.stage, 'stage', 'preview'));
      expect(requested.map((url) => Uri.parse(url).queryParameters['size']), ['thumbnail', 'preview']);
      expect(requested.any((url) => Uri.parse(url).path.endsWith('/original')), isFalse);
      expect(images, isNotEmpty);
    } finally {
      stream.removeListener(listener);
      for (final image in images) {
        image.dispose();
      }
    }
  });

  test(
    'an initial thumbnail 404 is owned by the image stream without a cleanup failure blocking its preview',
    () async {
      response = (args) async {
        final uri = args[0]! as String;
        return Uri.parse(uri).queryParameters['size'] == 'thumbnail' ? notFound(uri) : await encodedImage();
      };
      final image = await resolve(full()).timeout(const Duration(seconds: 5));
      expect(image.image.width, greaterThan(0));
      expect(requested.map((url) => Uri.parse(url).queryParameters['size']), ['thumbnail', 'preview']);
      image.dispose();
    },
  );
}
