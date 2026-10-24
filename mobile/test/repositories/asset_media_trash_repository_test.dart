import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/repositories/storage.repository.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:mocktail/mocktail.dart';

import '../test_utils.dart';

class _MockNativeSyncApi extends Mock implements NativeSyncApi {}

class _MockStorageRepository extends Mock implements StorageRepository {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const trashChannel = MethodChannel('file_trash');
  const photoManagerChannel = MethodChannel('com.fluttercandies/photo_manager');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late AssetMediaRepository repository;
  late List<MethodCall> trashCalls;
  late List<MethodCall> photoManagerCalls;
  Object? nativeReply;
  PlatformException? nativeError;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    repository = AssetMediaRepository(_MockNativeSyncApi(), _MockStorageRepository());
    trashCalls = [];
    photoManagerCalls = [];
    nativeReply = <String, Object?>{};
    nativeError = null;
    messenger.setMockMethodCallHandler(trashChannel, (call) async {
      trashCalls.add(call);
      if (nativeError != null) {
        throw nativeError!;
      }
      return nativeReply;
    });
    messenger.setMockMethodCallHandler(photoManagerChannel, (call) async {
      photoManagerCalls.add(call);
      throw StateError('Automatic trash must never fall back to permanent deletion');
    });
  });

  tearDown(() {
    // Every failure mode must remain trash-only, including malformed native replies.
    expect(photoManagerCalls, isEmpty);
    messenger.setMockMethodCallHandler(trashChannel, null);
    messenger.setMockMethodCallHandler(photoManagerChannel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  group('trashForSync', () {
    test('empty work does not invoke a media operation', () async {
      expect(await repository.trashForSync([]), isEmpty);
      expect(trashCalls, isEmpty);
    });

    test('already cancelled work never starts a native operation', () async {
      final result = await repository.trashForSync([
        TestUtils.createLocalAsset(id: '101'),
      ], cancellation: Future<void>.value());

      expect(result['101']!.code, 'cancelled');
      expect(trashCalls, isEmpty);
    });

    test('cancellation targets and drains the exact native operation', () async {
      final cancellation = Completer<void>();
      final nativeResult = Completer<Object?>();
      final started = Completer<void>();
      String? operationId;
      messenger.setMockMethodCallHandler(trashChannel, (call) async {
        trashCalls.add(call);
        final arguments = call.arguments! as Map;
        if (call.method == 'trashForSync') {
          operationId = arguments['operationId']! as String;
          started.complete();
          return nativeResult.future;
        }
        expect(call.method, 'cancelTrashForSync');
        expect(arguments['operationId'], operationId);
        nativeResult.complete({
          '101': {'code': 'cancelled'},
        });
        return true;
      });

      final work = repository.trashForSync([TestUtils.createLocalAsset(id: '101')], cancellation: cancellation.future);
      await started.future;
      cancellation.complete();
      final result = await work;

      expect(result['101']!.code, 'cancelled');
      expect(trashCalls.map((call) => call.method), ['trashForSync', 'cancelTrashForSync']);
      expect(nativeResult.isCompleted, isTrue);
    });

    test('a completed request cannot later cancel another native operation', () async {
      final oldCancellation = Completer<void>();
      nativeReply = {
        '101': {'code': 'trashed'},
      };
      await repository.trashForSync([TestUtils.createLocalAsset(id: '101')], cancellation: oldCancellation.future);

      final secondResult = Completer<Object?>();
      final secondStarted = Completer<void>();
      messenger.setMockMethodCallHandler(trashChannel, (call) async {
        trashCalls.add(call);
        if (call.method == 'cancelTrashForSync') {
          fail('A completed operation must not leave an unowned cancellation callback');
        }
        secondStarted.complete();
        return secondResult.future;
      });
      final secondWork = repository.trashForSync([TestUtils.createLocalAsset(id: '102')]);
      await secondStarted.future;
      oldCancellation.complete();
      await Future<void>.value();
      secondResult.complete({
        '102': {'code': 'trashed'},
      });

      expect((await secondWork)['102']!.isTrashed, isTrue);
      expect(trashCalls.every((call) => call.method == 'trashForSync'), isTrue);
    });

    test('sends each asset once with identity metadata and media type', () async {
      final image = TestUtils.createLocalAsset(id: '101').copyWith(
        name: 'camera-original.jpg',
        createdAt: DateTime.utc(2026, 10, 24, 9),
        updatedAt: DateTime.utc(2026, 10, 24, 9, 1),
      );
      final video = TestUtils.createLocalAsset(id: '102').copyWith(type: AssetType.video, name: 'camera-original.mp4');
      nativeReply = {
        '101': {'code': 'trashed'},
        '102': {'code': 'trashed'},
      };

      final result = await repository.trashForSync([image, image, video]);

      expect(result.keys, unorderedEquals(['101', '102']));
      expect(trashCalls, hasLength(1));
      expect(trashCalls.single.method, 'trashForSync');
      final arguments = Map<Object?, Object?>.from(trashCalls.single.arguments! as Map);
      final assets = (arguments['assets']! as List).cast<Map>();
      expect(assets, hasLength(2));
      expect(assets.first, {
        'id': image.id,
        'type': AssetType.image.index,
        'name': image.name,
        'createdAt': image.createdAt.millisecondsSinceEpoch ~/ 1000,
        'updatedAt': image.updatedAt.millisecondsSinceEpoch ~/ 1000,
      });
      expect(assets.last['type'], AssetType.video.index);
    });

    test('reports partial success without converting rejected assets to success', () async {
      nativeReply = {
        '101': {'code': 'trashed'},
        '102': {'code': 'providerError', 'message': 'IllegalStateException: MediaStore unavailable'},
        '103': {'code': 'permissionDenied', 'message': 'SecurityException: media write permission revoked'},
      };

      final result = await repository.trashForSync([
        TestUtils.createLocalAsset(id: '101'),
        TestUtils.createLocalAsset(id: '102'),
        TestUtils.createLocalAsset(id: '103'),
      ]);

      expect(result['101']!.isTrashed, isTrue);
      expect(result['102']!.isTrashed, isFalse);
      expect(result['102']!.code, 'providerError');
      expect(result['102']!.message, 'IllegalStateException: MediaStore unavailable');
      expect(result['103']!.isTrashed, isFalse);
      expect(result['103']!.code, 'permissionDenied');
      expect(result['103']!.message, contains('SecurityException'));
    });

    test('bounds native requests and retains each batch result', () async {
      messenger.setMockMethodCallHandler(trashChannel, (call) async {
        trashCalls.add(call);
        final arguments = call.arguments as Map;
        final assets = arguments['assets'] as List;
        return {
          for (final asset in assets) (asset as Map)['id']: {'code': 'trashed'},
        };
      });
      final assets = [for (var index = 1; index <= 45; index++) TestUtils.createLocalAsset(id: '$index')];

      final result = await repository.trashForSync(assets);

      expect(result, hasLength(45));
      expect(result.values.every((entry) => entry.isTrashed), isTrue);
      expect(trashCalls, hasLength(2));
      expect((trashCalls.first.arguments as Map)['assets'], hasLength(40));
      expect((trashCalls.last.arguments as Map)['assets'], hasLength(5));
    });

    test('keeps full MANAGE_MEDIA refusal explicit without another deletion API', () async {
      nativeReply = {
        '101': {'code': 'permissionDenied', 'message': 'MANAGE_MEDIA permission is missing'},
        '102': {'code': 'permissionDenied', 'message': 'MANAGE_MEDIA permission is missing'},
      };

      final result = await repository.trashForSync([
        TestUtils.createLocalAsset(id: '101'),
        TestUtils.createLocalAsset(id: '102'),
      ]);

      expect(result.values.every((entry) => !entry.isTrashed && entry.code == 'permissionDenied'), isTrue);
      expect(trashCalls, hasLength(1));
    });

    test('recognizes an already trashed asset without claiming a missing asset was trashed', () async {
      nativeReply = {
        '101': {'code': 'alreadyTrashed'},
        '102': {'code': 'missing', 'message': 'No visible MediaStore row for this ID'},
        '103': {'code': 'assetChanged', 'message': 'MediaStore ID belongs to a different asset'},
      };

      final result = await repository.trashForSync([
        TestUtils.createLocalAsset(id: '101'),
        TestUtils.createLocalAsset(id: '102'),
        TestUtils.createLocalAsset(id: '103'),
      ]);

      expect(result['101']!.isTrashed, isTrue);
      expect(result['102']!.isTrashed, isFalse);
      expect(result['103']!.isTrashed, isFalse);
    });

    test('keeps lifecycle and cancellation outcomes pending rather than successful', () async {
      const codes = ['noActivity', 'busy', 'timeout', 'activityDetached', 'cancelled'];
      final assets = [for (var index = 0; index < codes.length; index++) TestUtils.createLocalAsset(id: '$index')];
      nativeReply = {
        for (var index = 0; index < codes.length; index++) '$index': {'code': codes[index]},
      };

      final result = await repository.trashForSync(assets);

      expect(result.values.map((entry) => entry.code), unorderedEquals(codes));
      expect(result.values.every((entry) => !entry.isTrashed), isTrue);
    });

    test('a missing native result cannot silently acknowledge a requested asset', () async {
      nativeReply = {
        '101': {'code': 'trashed'},
        'unexpected': {'code': 'trashed'},
      };

      final result = await repository.trashForSync([
        TestUtils.createLocalAsset(id: '101'),
        TestUtils.createLocalAsset(id: '102'),
      ]);

      expect(result.keys, unorderedEquals(['101', '102']));
      expect(result['101']!.isTrashed, isTrue);
      expect(result['102']!.code, 'invalidResponse');
      expect(result['102']!.isTrashed, isFalse);
    });

    test('an invalid native entry remains an explicit failure', () async {
      nativeReply = {
        '101': {'code': true},
        '102': 'trashed',
      };

      final result = await repository.trashForSync([
        TestUtils.createLocalAsset(id: '101'),
        TestUtils.createLocalAsset(id: '102'),
      ]);

      expect(result.values.every((entry) => entry.code == 'invalidResponse' && !entry.isTrashed), isTrue);
    });

    for (final reply in [null, true, <Object?>[]]) {
      test('a malformed native response ($reply) remains an explicit failure', () async {
        nativeReply = reply;

        final result = await repository.trashForSync([TestUtils.createLocalAsset(id: '101')]);

        expect(result['101']!.code, 'invalidResponse');
        expect(result['101']!.isTrashed, isFalse);
      });
    }

    test('preserves a platform exception for the durable queue to record and retry', () async {
      nativeError = PlatformException(
        code: 'deleteWithIds failed',
        message: 'SecurityException: denied',
        details: {'class': 'SecurityException'},
      );

      await expectLater(
        repository.trashForSync([TestUtils.createLocalAsset(id: '101')]),
        throwsA(
          isA<PlatformException>()
              .having((error) => error.code, 'code', 'deleteWithIds failed')
              .having((error) => error.message, 'message', 'SecurityException: denied'),
        ),
      );
      expect(trashCalls, hasLength(1));
    });

    test('unsupported Android versions do not fall back to permanent delete', () async {
      nativeReply = {
        '101': {'code': 'unsupported', 'message': 'Android API 31 or newer is required'},
      };

      final result = await repository.trashForSync([TestUtils.createLocalAsset(id: '101')]);

      expect(result['101']!.code, 'unsupported');
      expect(result['101']!.isTrashed, isFalse);
    });

    test('other platforms are unsupported without issuing a native operation', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

      final result = await repository.trashForSync([TestUtils.createLocalAsset(id: '101')]);

      expect(result['101']!.code, 'unsupported');
      expect(result['101']!.isTrashed, isFalse);
      expect(trashCalls, isEmpty);
    });
  });
}
