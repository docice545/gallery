import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/platform/live_photo_save_api.g.dart';
import 'package:immich_mobile/repositories/file_media.repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const photos = MethodChannel('com.fluttercandies/photo_manager');
  const files = MethodChannel('file_trash');
  late Directory cache;
  late List<MethodCall> photosCalls;
  late List<MethodCall> filesCalls;
  bool updateSucceeds = true;
  const livePhotoChannel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.LivePhotoSaveApi.saveLivePhoto',
    LivePhotoSaveApi.pigeonChannelCodec,
  );
  const cancelChannel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.LivePhotoSaveApi.cancelSave',
    LivePhotoSaveApi.pigeonChannelCodec,
  );

  setUp(() async {
    cache = await Directory.systemTemp.createTemp('file-media-test-');
    photosCalls = [];
    filesCalls = [];
    updateSucceeds = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(photos, (call) async {
      photosCalls.add(call);
      if (call.method == 'deleteWithIds') {
        return ['17'];
      }
      return {'id': '17', 'type': call.method == 'saveVideo' ? 2 : 1, 'width': 100, 'height': 100, 'duration': 0};
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(files, (call) async {
      filesCalls.add(call);
      return updateSucceeds;
    });
  });

  tearDown(() async {
    await cache.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
      livePhotoChannel,
      null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
      cancelChannel,
      null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(photos, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(files, null);
  });

  test('Android HEIC import preserves bytes and explicitly corrects the owned MediaStore MIME', () async {
    final original = await File(
      '${cache.path}/photo.HEIC',
    ).writeAsBytes([0, 0, 0, 24, 102, 116, 121, 112, 104, 101, 105, 99, 0, 0, 0, 0]);
    const repository = FileMediaRepository(isAndroid: true);
    final entity = await repository.saveImageWithFile(original.path, title: 'photo.HEIC', relativePath: 'DCIM/Photos');
    expect(entity?.id, '17');
    expect(photosCalls.single.method, 'saveImageWithPath');
    expect(photosCalls.single.arguments, containsPair('path', original.path));
    expect(photosCalls.single.arguments, containsPair('title', 'photo.HEIC'));
    expect(photosCalls.single.arguments, containsPair('relativePath', 'DCIM/Photos'));
    expect(filesCalls.single.method, 'updateDownloadedAssetMimeType');
    expect(filesCalls.single.arguments, {'mediaId': '17', 'type': 1, 'mimeType': 'image/heic'});
    expect(await original.readAsBytes(), [0, 0, 0, 24, 102, 116, 121, 112, 104, 101, 105, 99, 0, 0, 0, 0]);
  });

  test('Android video save uses the original file and exact video MIME without encoding', () async {
    final original = await File(
      '${cache.path}/movie.mp4',
    ).writeAsBytes([0, 0, 0, 24, 102, 116, 121, 112, 105, 115, 111, 109]);
    const repository = FileMediaRepository(isAndroid: true);
    await repository.saveVideo(original, title: 'movie.mp4');
    expect(photosCalls.single.method, 'saveVideo');
    expect(photosCalls.single.arguments, containsPair('path', original.path));
    expect(filesCalls.single.arguments, {'mediaId': '17', 'type': 2, 'mimeType': 'video/mp4'});
    expect(original.existsSync(), isTrue);
  });

  test('failed MIME metadata update rolls back only the new import before a retry', () async {
    final original = await File('${cache.path}/photo.jpg').writeAsBytes([255, 216, 255]);
    updateSucceeds = false;
    const repository = FileMediaRepository(isAndroid: true);
    await expectLater(repository.saveImageWithFile(original.path, title: 'photo.jpg'), throwsStateError);
    expect(photosCalls.map((call) => call.method), ['saveImageWithPath', 'deleteWithIds']);
    expect(photosCalls.last.arguments, containsPair('ids', ['17']));
  });

  test('non-Android saves continue to use the existing platform photo library API', () async {
    final original = await File('${cache.path}/photo.jpg').writeAsBytes([255, 216, 255]);
    const repository = FileMediaRepository(isAndroid: false);
    await repository.saveImageWithFile(original.path, title: 'photo.jpg');
    expect(photosCalls.single.method, 'saveImageWithPath');
    expect(filesCalls, isEmpty);
  });

  test('unrecognized media is rejected before any permanent import', () async {
    final original = await File('${cache.path}/unknown.bin').writeAsBytes([1, 2, 3]);
    const repository = FileMediaRepository(isAndroid: true);
    await expectLater(repository.saveImageWithFile(original.path), throwsStateError);
    expect(photosCalls, isEmpty);
  });
  for (final outcome in LivePhotoSaveOutcome.values) {
    test('iOS save forwards $outcome honestly without guessing from a fetched subtype', () async {
      final image = await File('${cache.path}/photo.HEIC').writeAsBytes([1, 2, 3]);
      final video = await File('${cache.path}/photo.MOV').writeAsBytes([4, 5, 6]);
      final expectedId = outcome == LivePhotoSaveOutcome.livePhoto || outcome == LivePhotoSaveOutcome.imageOnly
          ? 'local'
          : null;
      final expected = LivePhotoSaveResult(outcome: outcome, localIdentifier: expectedId);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
        livePhotoChannel,
        (message) async {
          expect(message, ['request', image.path, video.path, 'photo.HEIC', true]);
          return [expected];
        },
      );
      const repository = FileMediaRepository(isAndroid: false);
      final result = await repository.saveLivePhoto(
        requestId: 'request',
        image: image,
        video: video,
        title: 'photo.HEIC',
      );
      expect(result.outcome, outcome);
      expect(result.localIdentifier, expectedId);
      expect(photosCalls, isEmpty); // Add-only does not need a full-library query.
      expect(await image.readAsBytes(), [1, 2, 3]);
      expect(await video.readAsBytes(), [4, 5, 6]);
    });
  }

  test('missing PhotoKit placeholder is failure, never a falsely preserved Live Photo', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
      livePhotoChannel,
      (_) async {
        return [LivePhotoSaveResult(outcome: LivePhotoSaveOutcome.livePhoto)];
      },
    );
    const repository = FileMediaRepository(isAndroid: false);
    final result = await repository.saveLivePhoto(
      requestId: 'request',
      image: File('still'),
      video: File('motion'),
      title: 'photo.HEIC',
    );
    expect(result.outcome, LivePhotoSaveOutcome.failed);
    expect(result.errorCode, 'MISSING_LOCAL_IDENTIFIER');
  });

  test('platform failure is an explicit sanitized failure, not still success', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
      livePhotoChannel,
      (_) async {
        throw PlatformException(code: 'PHPhotosErrorDomain', message: 'private path must not be exposed');
      },
    );
    const repository = FileMediaRepository(isAndroid: false);
    final result = await repository.saveLivePhoto(
      requestId: 'request',
      image: File('still'),
      video: File('motion'),
      title: 'photo.HEIC',
    );
    expect(result.outcome, LivePhotoSaveOutcome.failed);
    expect(result.errorCode, 'PLATFORM_FAILURE');
    expect(photosCalls, isEmpty);
  });

  test('caller can explicitly prohibit image-only fallback', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
      livePhotoChannel,
      (message) async {
        expect((message! as List).last, false);
        return [LivePhotoSaveResult(outcome: LivePhotoSaveOutcome.failed, errorCode: 'INVALID_PAIR')];
      },
    );
    const repository = FileMediaRepository(isAndroid: false);
    final result = await repository.saveLivePhoto(
      requestId: 'request',
      image: File('still'),
      video: File('motion'),
      title: 'photo.HEIC',
      allowImageOnlyFallback: false,
    );
    expect(result.outcome, LivePhotoSaveOutcome.failed);
    expect(result.errorCode, 'INVALID_PAIR');
  });

  test('cancel is an awaited native drain for this request only', () async {
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
      cancelChannel,
      (message) async {
        calls++;
        expect(message, ['request']);
        return [null];
      },
    );
    const repository = FileMediaRepository(isAndroid: false);
    await repository.cancelLivePhotoSave('request');
    expect(calls, 1);
  });
}
