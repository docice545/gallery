import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/remote_image_http_exception.dart';
import 'package:immich_mobile/infrastructure/loaders/image_request.dart';
import 'package:immich_mobile/platform/remote_image_api.g.dart';
import 'package:immich_mobile/presentation/widgets/images/remote_image_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.RemoteImageApi.requestImage',
    RemoteImageApi.pigeonChannelCodec,
  );
  const cancelChannel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.RemoteImageApi.cancelRequest',
    RemoteImageApi.pigeonChannelCodec,
  );
  late List<Object?> args;

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler(
      cancelChannel,
      (_) async => <Object?>[null],
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler(channel, (
      message,
    ) async {
      args = message! as List<Object?>;
      return <Object?>[null];
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler(cancelChannel, null);
  });

  for (final encoded in [false, true]) {
    test('preserves unexpected structured HTTP 404 for ${encoded ? 'animated' : 'decoded'} images', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler(
        channel,
        (_) async => [
          'HTTP_ERROR',
          'Remote image request failed (HTTP 404)',
          {
            'statusCode': 404,
            'requestPath': 'https://user:secret@example.test/api/assets/missing/thumbnail?key=private',
            'finalPath': '/api/assets/missing/original?signature=private',
            'requestId': 999,
            'mediaSize': 'preview',
            'edited': false,
          },
        ],
      );
      final request = RemoteImageRequest(
        uri: 'https://example.test/api/assets/missing/thumbnail?size=preview&edited=false&token=private',
      );
      await expectLater(
        encoded ? request.loadCodec() : request.load((_, {getTargetSize}) => throw UnimplementedError()),
        throwsA(
          isA<RemoteImageHttpException>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.requestId, 'actual requestId', request.requestId)
              .having((e) => e.assetId, 'assetId', 'missing')
              .having((e) => e.stage, 'stage', 'preview')
              .having((e) => e.edited, 'edited', false)
              .having((e) => e.requestPath, 'requestPath', '/api/assets/missing/thumbnail')
              .having((e) => e.finalPath, 'finalPath', '/api/assets/missing/original')
              .having((e) => e.toString(), 'redacted diagnostic', isNot(contains('private'))),
        ),
      );
    });

    test('an in-flight 404 after intentional cancellation is a cancelled ${encoded ? 'codec' : 'image'}', () async {
      final started = Completer<void>();
      final response = Completer<Object?>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler(channel, (
        _,
      ) async {
        started.complete();
        return response.future;
      });
      final request = RemoteImageRequest(uri: 'https://example.test/api/assets/deleted/thumbnail?size=preview');
      final result = encoded ? request.loadCodec() : request.load((_, {getTargetSize}) => throw UnimplementedError());
      await started.future;
      request.cancel();
      response.complete([
        'HTTP_ERROR',
        'Remote image request failed (HTTP 404)',
        {
          'statusCode': 404,
          'requestPath': '/api/assets/deleted/thumbnail',
          'finalPath': '/api/assets/deleted/thumbnail',
        },
      ]);
      expect(await result, isNull);
    });
  }

  test('never infers a 404 status by parsing a generic IOException message', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler(
      channel,
      (_) async => ['IOException', 'java.io.IOException: HTTP 404', null],
    );
    final request = RemoteImageRequest(uri: 'https://example.test/api/assets/id/original');
    await expectLater(
      request.load((_, {getTargetSize}) => throw UnimplementedError()),
      throwsA(isA<PlatformException>().having((e) => e.code, 'original code', 'IOException')),
    );
  });

  test('malformed structured status remains a platform failure', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler(
      channel,
      (_) async => [
        'HTTP_ERROR',
        'Malformed HTTP diagnostics',
        {'statusCode': '404'},
      ],
    );
    final request = RemoteImageRequest(uri: 'https://example.test/api/assets/id/original');
    await expectLater(
      request.load((_, {getTargetSize}) => throw UnimplementedError()),
      throwsA(isA<PlatformException>()),
    );
  });

  Future<ui.Image> loadEncoded(String path, ui.Size decodeSize) async {
    final bytes = await File(path).readAsBytes();
    final pointer = malloc<Uint8>(bytes.length)..asTypedList(bytes.length).setAll(0, bytes);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler(channel, (
      message,
    ) async {
      return <Object?>[
        <Object?, Object?>{'pointer': pointer.address, 'length': bytes.length},
      ];
    });
    final request = RemoteImageRequest(uri: 'https://example.test/fallback', decodeSize: decodeSize);

    return (await request.load((_, {getTargetSize}) => throw UnimplementedError()))!.image;
  }

  test('passes the requested decode size to the platform', () async {
    final request = RemoteImageRequest(uri: 'https://example.test/thumbnail', decodeSize: const ui.Size(319.1, 179.1));

    await request.load((_, {getTargetSize}) => throw UnimplementedError());

    expect(args[0], 'https://example.test/thumbnail');
    expect(args[2], isFalse);
    expect(args[3], 320);
    expect(args[4], 180);
  });

  test('leaves requests without a size unbounded', () async {
    final request = RemoteImageRequest(uri: 'https://example.test/thumbnail');

    await request.load((_, {getTargetSize}) => throw UnimplementedError());

    expect(args[3], isNull);
    expect(args[4], isNull);
  });

  test('leaves encoded animation requests unbounded', () async {
    final request = RemoteImageRequest(uri: 'https://example.test/animation', decodeSize: const ui.Size(320, 180));

    await request.loadCodec();

    expect(args[2], isTrue);
    expect(args[3], isNull);
    expect(args[4], isNull);
  });

  test('keeps portrait cover quality in a wide tile', () async {
    final image = await loadEncoded('assets/feature_message/ocr.webp', const ui.Size(963, 642));

    expect(image.width, 963);
    expect(image.height, 1453);
    image.dispose();
  });

  test('preserves cover quality for extreme aspect ratios', () async {
    // Cover-fitting a square box keeps the source aspect ratio, so the expected
    // width is tied to whichever artwork ships at this path. The fork replaces it
    // with the Gallery mark (984x282, ~3.49:1) where upstream ships 3038x742
    // (~4.09:1). Re-derive as `box * width / height` if branding swaps the logo
    // again — and keep the box BELOW the artwork's height (282 here), or the
    // loader's no-upscale rule returns the native size and this stops testing
    // cover-downscaling at all, which is the whole point of the case.
    final image = await loadEncoded('assets/immich-logo-inline-light.png', const ui.Size.square(200));

    expect(image.width, 698);
    expect(image.height, 200);
    image.dispose();
  });

  test('does not upscale encoded fallback', () async {
    final image = await loadEncoded('assets/feature_message/ocr.webp', const ui.Size.square(2000));

    expect(image.width, 1206);
    expect(image.height, 1819);
    image.dispose();
  });

  test('uses the decode size in the provider cache key', () {
    final small = RemoteImageProvider(url: 'https://example.test/thumbnail', decodeSize: const ui.Size.square(160));
    final large = RemoteImageProvider(url: 'https://example.test/thumbnail', decodeSize: const ui.Size.square(320));

    expect(small, isNot(large));
  });

  test('shares the cache key when no decode size is set', () {
    final first = RemoteImageProvider(url: 'https://example.test/thumbnail');
    final second = RemoteImageProvider(url: 'https://example.test/thumbnail');

    expect(first, second);
    expect(first.hashCode, second.hashCode);
  });
}
