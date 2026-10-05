import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/presentation/widgets/images/image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/local_image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/remote_image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/timeline_thumbnail_request.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart';

import '../../../unit/factories/local_asset_factory.dart';
import '../../../unit/factories/remote_asset_factory.dart';

class _MockStoreRepository extends Mock implements StoreRepository {}

void _expectBounded(Size size, {Size? nativeSize}) {
  expect(size.width.isFinite, isTrue);
  expect(size.height.isFinite, isTrue);
  expect(size.width, greaterThan(0));
  expect(size.height, greaterThan(0));
  expect(math.max(size.width, size.height), lessThanOrEqualTo(1440));
  expect(size.width * size.height, lessThanOrEqualTo(1440 * 1440));
  if (nativeSize != null) {
    expect(size.width, lessThanOrEqualTo(nativeSize.width));
    expect(size.height, lessThanOrEqualTo(nativeSize.height));
  }
}

void main() {
  group('timeline request sizing', () {
    test('DPR selects the full source needed for a cover crop', () {
      const imageSize = Size(900, 1600);
      final lowDpr = buildTimelineThumbnailRequest(
        viewportSize: const Size.square(160),
        devicePixelRatio: 1,
        imageSize: imageSize,
      );
      final highDpr = buildTimelineThumbnailRequest(
        viewportSize: const Size.square(160),
        devicePixelRatio: 3,
        imageSize: imageSize,
      );

      expect(lowDpr.decodeSize, const Size(216, 384));
      expect(lowDpr.remoteMediaSize, AssetMediaSize.thumbnail);
      expect(highDpr.decodeSize, const Size(504, 896));
      expect(highDpr.remoteMediaSize, AssetMediaSize.preview);
      expect(highDpr.decodeSize.aspectRatio, imageSize.aspectRatio);
    });

    test('cache rounding does not inflate the physical requirement for motion quality', () {
      final request = buildTimelineThumbnailRequest(
        viewportSize: const Size(360, 202.5),
        devicePixelRatio: 3,
        imageSize: const Size(3840, 2160),
      );
      const motionSize = Size(1080, 608);

      expect(request.requiredSize, const Size(1080, 607.5));
      expect(request.decodeSize, const Size(1152, 648));
      expect(motionSize.width, greaterThanOrEqualTo(request.requiredSize.width));
      expect(motionSize.height, greaterThanOrEqualTo(request.requiredSize.height));
      expect(motionSize.width, lessThan(request.decodeSize.width));
      expect(motionSize.height, lessThan(request.decodeSize.height));
    });

    test('portrait and landscape targets retain their upright full source aspect', () {
      for (final imageSize in [const Size(900, 1600), const Size(1600, 900)]) {
        final request = buildTimelineThumbnailRequest(
          viewportSize: const Size.square(160),
          devicePixelRatio: 3,
          imageSize: imageSize,
        );

        expect(request.decodeSize.shortestSide, 504);
        expect(request.decodeSize.longestSide, 896);
        expect(request.decodeSize.aspectRatio, imageSize.aspectRatio);
        _expectBounded(request.decodeSize, nativeSize: imageSize);
      }
    });

    test('contain uses the smaller full source requirement', () {
      final request = buildTimelineThumbnailRequest(
        viewportSize: const Size.square(160),
        devicePixelRatio: 2,
        imageSize: const Size(900, 1600),
        fit: BoxFit.contain,
      );

      expect(request.decodeSize, const Size(216, 384));
      expect(request.requiredSize, const Size(180, 320));
      expect(request.remoteMediaSize, AssetMediaSize.thumbnail);
    });

    test('a face union outside the cover crop uses the contain plan', () {
      const imageSize = Size(900, 1600);
      const viewportSize = Size.square(160);
      final request = buildTimelineThumbnailRequest(
        viewportSize: viewportSize,
        devicePixelRatio: 2,
        imageSize: imageSize,
        faces: const [Rect.fromLTRB(0.2, 0.02, 0.4, 0.2), Rect.fromLTRB(0.6, 0.8, 0.8, 0.98)],
      );
      final contain = buildTimelineThumbnailRequest(
        viewportSize: viewportSize,
        devicePixelRatio: 2,
        imageSize: imageSize,
        fit: BoxFit.contain,
      );
      final cover = buildTimelineThumbnailRequest(
        viewportSize: viewportSize,
        devicePixelRatio: 2,
        imageSize: imageSize,
      );

      expect(request.decodeSize, contain.decodeSize);
      expect(request.requiredSize, contain.requiredSize);
      expect(request.requiredSize, const Size(180, 320));
      expect(request.remoteMediaSize, contain.remoteMediaSize);
      expect(request.decodeSize.longestSide, lessThan(cover.decodeSize.longestSide));
      expect(request.requiredSize.longestSide, lessThan(cover.requiredSize.longestSide));
      expect(cover.remoteMediaSize, AssetMediaSize.preview);
    });

    test('faces that fit the crop and invalid faces keep the cover request', () {
      final ordinary = buildTimelineThumbnailRequest(
        viewportSize: const Size.square(160),
        devicePixelRatio: 3,
        imageSize: const Size(900, 1600),
      );
      for (final faces in [
        const [Rect.fromLTRB(0.2, 0.02, 0.8, 0.2)],
        const [Rect.fromLTRB(double.nan, 0.1, 0.8, 0.9), Rect.fromLTRB(0.8, 0.9, 0.2, 0.1)],
      ]) {
        final request = buildTimelineThumbnailRequest(
          viewportSize: const Size.square(160),
          devicePixelRatio: 3,
          imageSize: const Size(900, 1600),
          faces: faces,
        );

        expect(request.decodeSize, ordinary.decodeSize);
        expect(request.remoteMediaSize, ordinary.remoteMediaSize);
      }
    });

    test('an adequate thumbnail caps the bucket instead of promoting its source', () {
      final square = buildTimelineThumbnailRequest(
        viewportSize: const Size.square(160),
        devicePixelRatio: 1,
        imageSize: const Size.square(4000),
      );
      final landscape = buildTimelineThumbnailRequest(
        viewportSize: const Size.square(120),
        devicePixelRatio: 2,
        imageSize: const Size(4000, 3000),
      );

      expect(square.remoteMediaSize, AssetMediaSize.thumbnail);
      expect(square.requiredSize, const Size.square(160));
      expect(square.decodeSize, const Size.square(250));
      expect(landscape.remoteMediaSize, AssetMediaSize.thumbnail);
      expect(landscape.requiredSize, const Size(320, 240));
      expect(landscape.decodeSize.width, closeTo(250 * 4 / 3, 1e-9));
      expect(landscape.decodeSize.height, closeTo(250, 1e-9));
    });

    test('the unrounded short side selects thumbnail at 250 and preview above it', () {
      for (final edge in [250.0, 250.001]) {
        final request = buildTimelineThumbnailRequest(
          viewportSize: Size.square(edge),
          devicePixelRatio: 1,
          imageSize: const Size.square(4000),
        );

        expect(request.remoteMediaSize, edge == 250 ? AssetMediaSize.thumbnail : AssetMediaSize.preview);
        expect(request.decodeSize, Size.square(edge == 250 ? 250 : 256));
      }
    });

    test('small targets keep thumbnail and share a decode bucket across nearby sizes', () {
      for (final edge in [90.0, 100.0, 127.0, 128.0]) {
        final request = buildTimelineThumbnailRequest(
          viewportSize: Size.square(edge),
          devicePixelRatio: 1,
          imageSize: const Size.square(4000),
        );

        expect(request.decodeSize, const Size.square(128));
        expect(request.remoteMediaSize, AssetMediaSize.thumbnail);
      }
    });

    test('preview buckets round up and remain stable until the next boundary', () {
      for (final edge in [270.0, 280.0, 384.0, 384.001]) {
        final request = buildTimelineThumbnailRequest(
          viewportSize: Size.square(edge),
          devicePixelRatio: 1,
          imageSize: const Size.square(4000),
        );

        expect(request.decodeSize, Size.square(edge <= 384 ? 384 : 512));
        expect(request.remoteMediaSize, AssetMediaSize.preview);
      }
    });

    test('native image dimensions cap upward buckets without upscaling', () {
      for (final imageSize in [const Size(100, 80), const Size(2, 100), const Size(251, 251)]) {
        final request = buildTimelineThumbnailRequest(
          viewportSize: const Size.square(160),
          devicePixelRatio: 3,
          imageSize: imageSize,
        );

        expect(request.decodeSize, imageSize);
        expect(request.requiredSize, imageSize);
        _expectBounded(request.decodeSize, nativeSize: imageSize);
        _expectBounded(request.requiredSize, nativeSize: imageSize);
      }
    });

    test('large and extreme aspect sources stay within edge and pixel budgets', () {
      for (final imageSize in [const Size.square(6000), const Size(12000, 300), const Size(300, 12000)]) {
        final request = buildTimelineThumbnailRequest(
          viewportSize: const Size.square(1000),
          devicePixelRatio: 4,
          imageSize: imageSize,
        );

        expect(request.decodeSize.longestSide, 1440);
        expect(request.decodeSize.aspectRatio, closeTo(imageSize.aspectRatio, 1e-12));
        expect(request.remoteMediaSize, AssetMediaSize.preview);
        _expectBounded(request.decodeSize, nativeSize: imageSize);
        _expectBounded(request.requiredSize, nativeSize: imageSize);
      }
    });

    test('unknown dimensions use a bounded physical viewport', () {
      final small = buildTimelineThumbnailRequest(viewportSize: const Size(80, 40), devicePixelRatio: 3);
      final highDpr = buildTimelineThumbnailRequest(viewportSize: const Size.square(160), devicePixelRatio: 3);
      final wide = buildTimelineThumbnailRequest(viewportSize: const Size(300, 100), devicePixelRatio: 1);

      expect(small.decodeSize, const Size(250, 125));
      expect(small.requiredSize, const Size(240, 120));
      expect(small.remoteMediaSize, AssetMediaSize.thumbnail);
      expect(highDpr.decodeSize, const Size.square(512));
      expect(highDpr.requiredSize, const Size.square(480));
      expect(highDpr.remoteMediaSize, AssetMediaSize.preview);
      expect(wide.decodeSize, const Size(384, 128));
      expect(wide.requiredSize, const Size(300, 100));
      expect(wide.remoteMediaSize, AssetMediaSize.preview);
    });

    test('unknown physical requirements retain their aspect while respecting the budget', () {
      final request = buildTimelineThumbnailRequest(viewportSize: const Size(1000, 500), devicePixelRatio: 4);

      expect(request.requiredSize, const Size(1440, 720));
      expect(request.decodeSize, const Size(1440, 720));
      _expectBounded(request.requiredSize);
    });

    test('invalid source dimensions use the same fallback as unknown metadata', () {
      final unknown = buildTimelineThumbnailRequest(viewportSize: const Size(180, 120), devicePixelRatio: 3);
      for (final imageSize in [
        Size.zero,
        const Size(-1, 100),
        const Size(100, -1),
        const Size(double.nan, 100),
        const Size(100, double.infinity),
      ]) {
        final request = buildTimelineThumbnailRequest(
          viewportSize: const Size(180, 120),
          devicePixelRatio: 3,
          imageSize: imageSize,
        );

        expect(request.decodeSize, unknown.decodeSize);
        expect(request.requiredSize, unknown.requiredSize);
        expect(request.remoteMediaSize, unknown.remoteMediaSize);
        _expectBounded(request.decodeSize);
      }
    });

    test('invalid DPR uses one physical pixel per logical pixel', () {
      for (final dpr in [0.0, -1.0, double.nan, double.infinity]) {
        final request = buildTimelineThumbnailRequest(
          viewportSize: const Size.square(160),
          devicePixelRatio: dpr,
          imageSize: const Size.square(4000),
        );

        expect(request.decodeSize, const Size.square(250));
        expect(request.remoteMediaSize, AssetMediaSize.thumbnail);
      }
    });

    test('invalid viewport dimensions use a finite bounded fallback', () {
      for (final viewportSize in [
        Size.zero,
        const Size(-1, 100),
        const Size(100, -1),
        const Size(double.nan, 100),
        const Size(100, double.infinity),
      ]) {
        final request = buildTimelineThumbnailRequest(viewportSize: viewportSize, devicePixelRatio: 1);

        expect(request.decodeSize, const Size.square(384));
        expect(request.remoteMediaSize, AssetMediaSize.preview);
        _expectBounded(request.decodeSize);
      }
    });

    test('overflowing physical sizes and underflowing aspects remain positive and bounded', () {
      for (final sizes in [
        (const Size.square(1e300), const Size.square(1e300)),
        (const Size(1e300, 1e-300), null),
        (const Size.square(160), const Size(1e-300, 1e300)),
      ]) {
        final request = buildTimelineThumbnailRequest(
          viewportSize: sizes.$1,
          devicePixelRatio: 1e300,
          imageSize: sizes.$2,
        );

        _expectBounded(request.decodeSize, nativeSize: sizes.$2);
        _expectBounded(request.requiredSize, nativeSize: sizes.$2);
      }
    });

    test('fitWidth and fitHeight use the requested fitting axis', () {
      final width = buildTimelineThumbnailRequest(
        viewportSize: const Size(200, 100),
        devicePixelRatio: 2,
        imageSize: const Size(1000, 2000),
        fit: BoxFit.fitWidth,
      );
      final height = buildTimelineThumbnailRequest(
        viewportSize: const Size(200, 100),
        devicePixelRatio: 2,
        imageSize: const Size(1000, 2000),
        fit: BoxFit.fitHeight,
      );

      expect(width.decodeSize, const Size(448, 896));
      expect(width.remoteMediaSize, AssetMediaSize.preview);
      expect(height.decodeSize, const Size(128, 256));
      expect(height.remoteMediaSize, AssetMediaSize.thumbnail);
    });
  });

  group('thumbnail provider source and cache keys', () {
    const endpoint = 'https://example.test/api';

    setUpAll(() async {
      final repository = _MockStoreRepository();
      when(repository.getAll).thenAnswer((_) async => [const StoreDto(StoreKey.serverEndpoint, endpoint)]);
      await StoreService.init(storeRepository: repository, listenUpdates: false);
    });

    tearDownAll(() async => StoreService.I.dispose());

    test('the default source remains thumbnail', () {
      final provider = RemoteImageProvider.thumbnail(assetId: 'asset', thumbhash: 'hash');

      expect(provider.url, '$endpoint/assets/asset/thumbnail?size=thumbnail&edited=true&c=hash');
      expect(provider.decodeSize, isNull);
    });

    test('preview selection retains the thumbnail endpoint and its URL options', () {
      final provider = RemoteImageProvider.thumbnail(
        assetId: 'asset',
        thumbhash: 'hash+/=',
        edited: false,
        remoteMediaSize: AssetMediaSize.preview,
        decodeSize: const Size(384, 576),
      );
      final uri = Uri.parse(provider.url);

      expect(uri.path, '/api/assets/asset/thumbnail');
      expect(uri.queryParameters, {'size': 'preview', 'edited': 'false', 'c': 'hash+/='});
      expect(provider.decodeSize, const Size(384, 576));
    });

    test('the asset provider forwards both source selection and decode size', () {
      final provider =
          getThumbnailImageProvider(
                RemoteAssetFactory.create(),
                remoteSize: const Size(384, 576),
                remoteMediaSize: AssetMediaSize.preview,
              )!
              as RemoteImageProvider;

      expect(Uri.parse(provider.url).queryParameters['size'], 'preview');
      expect(provider.decodeSize, const Size(384, 576));
    });

    test('the default asset provider continues to request thumbnail', () {
      final provider = getThumbnailImageProvider(RemoteAssetFactory.create())! as RemoteImageProvider;

      expect(Uri.parse(provider.url).queryParameters['size'], 'thumbnail');
      expect(provider.decodeSize, isNull);
    });

    test('local assets receive the planned size without a remote provider', () {
      final request = buildTimelineThumbnailRequest(
        viewportSize: const Size.square(160),
        devicePixelRatio: 3,
        imageSize: const Size(900, 1600),
      );
      final provider =
          getThumbnailImageProvider(
                LocalAssetFactory.create(),
                size: request.decodeSize,
                remoteMediaSize: request.remoteMediaSize,
              )!
              as LocalThumbProvider;

      expect(provider.size, const Size(504, 896));
    });

    test('source selection and decode size each separate cache entries', () {
      final thumbnail = RemoteImageProvider.thumbnail(
        assetId: 'asset',
        thumbhash: 'hash',
        decodeSize: const Size.square(250),
      );
      final preview = RemoteImageProvider.thumbnail(
        assetId: 'asset',
        thumbhash: 'hash',
        decodeSize: const Size.square(250),
        remoteMediaSize: AssetMediaSize.preview,
      );
      final largerPreview = RemoteImageProvider.thumbnail(
        assetId: 'asset',
        thumbhash: 'hash',
        decodeSize: const Size.square(384),
        remoteMediaSize: AssetMediaSize.preview,
      );

      expect(thumbnail, isNot(preview));
      expect(preview, isNot(largerPreview));
      expect({thumbnail, preview, largerPreview}, hasLength(3));
    });

    test('identical source and decode plans share a cache key', () {
      final first = RemoteImageProvider.thumbnail(
        assetId: 'asset',
        thumbhash: 'hash',
        decodeSize: const Size(384, 576),
        remoteMediaSize: AssetMediaSize.preview,
      );
      final second = RemoteImageProvider.thumbnail(
        assetId: 'asset',
        thumbhash: 'hash',
        decodeSize: const Size(384, 576),
        remoteMediaSize: AssetMediaSize.preview,
      );

      expect(first, second);
      expect(first.hashCode, second.hashCode);
    });

    test('every timeline plan selects only thumbnail or preview URLs', () {
      for (final fit in BoxFit.values) {
        for (final imageSize in [null, const Size.square(6000), const Size(12000, 300)]) {
          final request = buildTimelineThumbnailRequest(
            viewportSize: const Size.square(1000),
            devicePixelRatio: 4,
            imageSize: imageSize,
            fit: fit,
          );
          final provider = RemoteImageProvider.thumbnail(
            assetId: 'asset',
            thumbhash: 'hash',
            decodeSize: request.decodeSize,
            remoteMediaSize: request.remoteMediaSize,
          );
          final uri = Uri.parse(provider.url);

          expect(request.remoteMediaSize, isIn([AssetMediaSize.thumbnail, AssetMediaSize.preview]));
          expect(uri.path, '/api/assets/asset/thumbnail');
          expect(uri.queryParameters['size'], isIn(['thumbnail', 'preview']));
          _expectBounded(request.decodeSize, nativeSize: imageSize);
        }
      }
    });
  });
}
