import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS background worker derives branded task identifiers from permitted identifiers', () {
    final source = File('ios/Runner/Background/BackgroundWorkerApiImpl.swift').readAsStringSync();

    expect(source, contains('BGTaskSchedulerPermittedIdentifiers'));
    expect(source, contains('hasSuffix(".refreshUpload")'));
    expect(source, contains('hasSuffix(".processingUpload")'));
    expect(source, contains('BGAppRefreshTaskRequest(identifier: refreshTaskID)'));
    expect(source, contains('BGProcessingTaskRequest(identifier: processingTaskID)'));
  });

  test('Android background worker preserves media triggers, charging constraint, and periodic worker', () {
    final source = File(
      'android/app/src/main/kotlin/app/alextran/immich/background/BackgroundWorkerApiImpl.kt',
    ).readAsStringSync();

    expect(source, contains('addContentUriTrigger(MediaStore.Images.Media.INTERNAL_CONTENT_URI'));
    expect(source, contains('addContentUriTrigger(MediaStore.Images.Media.EXTERNAL_CONTENT_URI'));
    expect(source, contains('addContentUriTrigger(MediaStore.Video.Media.INTERNAL_CONTENT_URI'));
    expect(source, contains('addContentUriTrigger(MediaStore.Video.Media.EXTERNAL_CONTENT_URI'));
    expect(source, contains('setRequiresCharging(settings.requiresCharging)'));
    expect(source, contains('setRequiresBatteryNotLow(true)'));
    expect(source, contains('PeriodicWorkRequestBuilder<PeriodicWorker>'));
  });

  // These source-contract checks complement the behavioral Dart drain suite;
  // they are not a claim that FlutterEngine/BGTaskScheduler ran on Linux.
  test('iOS expiration queues cancellation until bootstrap readiness and never force-destroys', () {
    final worker = File('ios/Runner/Background/BackgroundWorker.swift').readAsStringSync();
    final scheduler = File('ios/Runner/Background/BackgroundWorkerApiImpl.swift').readAsStringSync();
    expect(worker, contains('if cancellationRequested'));
    expect(worker, contains('if isInitialized'));
    expect(worker, contains('guard drained, pendingReplies == 0'));
    expect(worker, contains('complete(success: succeeded && !cancellationRequested)'));
    expect(worker, contains('guard let self, !self.isComplete'));
    expect(scheduler, contains('worker.requestCancellation()'));
    expect(scheduler, isNot(contains('withTimeInterval: 2')));
    expect(scheduler, isNot(contains('semaphore.wait()')));
    expect(scheduler, contains('task.expirationHandler = nil'));
  });

  test('native hashing and sync cancellation acknowledge task drain', () {
    final native = File('ios/Runner/Sync/MessagesImpl.swift').readAsStringSync();
    final pigeon = File('pigeon/native_sync_api.dart').readAsStringSync();
    expect(pigeon, contains('@async\n  void cancelHashing()'));
    expect(pigeon, contains('@async\n  void cancelSync()'));
    expect(native, contains('func cancelHashing(completion:'));
    expect(native, contains('func cancelSync(completion:'));
    expect(native, contains('await activeTask?.value'));
  });

  test('native callbacks check detachment at main-queue delivery time', () {
    final plugin = File('ios/Runner/Core/ImmichPlugin.swift').readAsStringSync();
    expect(plugin, contains('let deliver = { [weak self] in'));
    expect(plugin, contains('guard let self, !self.detached else { return }'));
    expect(plugin, contains('DispatchQueue.main.async(execute: deliver)'));
    expect(plugin, contains('DispatchQueue.main.sync { self.detached = true }'));
    expect(plugin.indexOf('guard let self, !self.detached'), greaterThan(plugin.indexOf('let deliver =')));
    expect(plugin.indexOf('completion(value)'), greaterThan(plugin.indexOf('guard let self, !self.detached')));
  });
}
