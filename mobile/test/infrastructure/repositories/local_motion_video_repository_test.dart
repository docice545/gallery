import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/repositories/storage.repository.dart';

import '../../fixtures/asset.stub.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('file_trash');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  late File component;
  late StorageRepository repository;
  late List<MethodCall> calls;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    directory = await Directory.systemTemp.createTemp('foto-motion-test-');
    component = await File('${directory.path}/component.mp4').writeAsBytes(List.filled(32, 0));
    repository = StorageRepository();
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return component.path;
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
    await directory.delete(recursive: true);
  });

  LocalAsset asset() => LocalAssetStub.image1.copyWith(id: '101', playbackStyle: AssetPlaybackStyle.livePhoto);

  test('cold source resolves a component directly from local identity without a viewer warm-up', () async {
    final file = await repository.getLocalMotionVideo(asset());
    expect(file?.path, component.path);
    expect(calls.single.method, 'localMotionVideo');
    final args = calls.single.arguments! as Map;
    expect(args['id'], '101');
    expect(args.containsKey('remoteId'), isFalse);
    expect(args.containsKey('url'), isFalse);
  });

  test('merged motion with stale local playbackStyle still asks for native component validation', () async {
    final local = asset().copyWith(remoteId: 'server-still', playbackStyle: AssetPlaybackStyle.image);
    expect((await repository.getLocalMotionVideo(local))?.path, component.path);
    expect((calls.single.arguments! as Map)['id'], '101');
  });

  test('missing local component remains unavailable without another source request', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    expect(await repository.getLocalMotionVideo(asset()), isNull);
    expect(calls, hasLength(1));
  });

  test('a returned server URL can never become autoplay proof', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => 'https://invalid.test/motion.mp4');
    expect(await repository.getLocalMotionVideo(asset()), isNull);
  });

  test('a vanished cache file is not treated as available local video', () async {
    await component.delete();
    expect(await repository.getLocalMotionVideo(asset()), isNull);
  });

  test('revoked media access is unavailable and cannot fall back to PhotoManager or server playback', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      throw PlatformException(code: 'LOCAL_MOTION_PERMISSION');
    });
    expect(await repository.getLocalMotionVideo(asset()), isNull);
    expect(calls.map((call) => call.method), ['localMotionVideo']);
  });

  test('cancellation before resolution starts no local extraction', () async {
    final stopped = Completer<void>()..complete();
    expect(await repository.getLocalMotionVideo(asset(), cancellation: stopped.future), isNull);
    expect(calls, isEmpty);
  });

  test('cancellation targets this native request and drains it before returning', () async {
    final stopped = Completer<void>();
    final started = Completer<void>();
    final response = Completer<String?>();
    String? requestId;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final args = call.arguments! as Map;
      if (call.method == 'localMotionVideo') {
        requestId = args['requestId']! as String;
        started.complete();
        return await response.future;
      }
      expect(call.method, 'cancelLocalMotionVideo');
      expect(args['requestId'], requestId);
      response.complete(null);
      return true;
    });
    final future = repository.getLocalMotionVideo(asset(), cancellation: stopped.future);
    await started.future;
    stopped.complete();
    expect(await future, isNull);
    expect(calls.map((call) => call.method), ['localMotionVideo', 'cancelLocalMotionVideo']);
  });
}
