import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// These source-level safety gates run on Linux. They are not PhotoKit execution
// tests; the real iOS compile and paired-resource acceptance remain separate gates.
String _method(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, greaterThanOrEqualTo(0));
  final opening = source.indexOf('{', start);
  var depth = 1;
  var end = opening + 1;
  while (end < source.length && depth > 0) {
    if (source[end] == '{') {
      depth++;
    }
    if (source[end] == '}') {
      depth--;
    }
    end++;
  }
  expect(depth, 0);
  return source.substring(opening + 1, end - 1);
}

void main() {
  final validator = File('ios/Runner/Sync/AppleLivePhotoPairValidator.swift').readAsStringSync();
  final saver = File('ios/Runner/Sync/LivePhotoSaveApiImpl.swift').readAsStringSync();

  test('cancellation requests PhotoKit stop without an early terminal acknowledgement', () {
    final cancel = _method(validator, 'func cancel()');
    expect(cancel, contains('PHLivePhoto.cancelRequest('));
    expect(cancel, isNot(contains('completion(')));
    expect(cancel, isNot(contains('finished = true')));
    expect(cancel, isNot(contains('finish(')));
    expect(cancel, contains('cancelled = true'));
  });

  test('native cancellation/error acknowledgement terminates even a degraded callback', () {
    expect(validator, contains('PHLivePhotoInfoCancelledKey'));
    expect(validator, contains('PHLivePhotoInfoErrorKey'));
    expect(validator, contains('if !cancelled && !failed && info[PHLivePhotoInfoIsDegradedKey]'));
    final finish = _method(validator, 'func finish(');
    expect(finish, contains('guard !finished'));
    expect(finish, contains('cancelled ? nil : livePhoto'));
  });

  test('request registration retains a cancellation that won the ID race', () {
    final register = _method(validator, 'func register(');
    expect(register, contains('let shouldCancel = cancelled'));
    expect(register, contains('PHLivePhoto.cancelRequest('));
  });

  test('submitted save cancels by awaiting result, never deleting paired sources early', () {
    final cancel = _method(saver, 'func cancelSave(');
    expect(cancel, contains('save.cancelWaiters.append(completion)'));
    expect(cancel, contains('if !save.committed'));
    expect(cancel, contains('if !save.validating'));
    expect(cancel, contains('save.cancelValidation?()'));
    expect(cancel, isNot(contains('removeItem(')));
    final finish = _method(saver, 'private func finish(');
    expect(finish, contains('guard !save.finished'));
    expect(finish, contains('for waiter in save.cancelWaiters'));
  });
  test('save requests add-only authorization and denies before starting a media reader', () {
    final start = _method(saver, 'func saveLivePhoto(');
    expect(start, contains('PHPhotoLibrary.authorizationStatus(for: .addOnly)'));
    expect(start, contains('PHPhotoLibrary.requestAuthorization(for: .addOnly'));
    expect(start, contains('authorization == .authorized || authorization == .limited'));
    expect(start, contains('"PERMISSION_DENIED"'));
    expect(start, contains('!save.finished'));
    expect(start, contains('current === save'));
    expect(start, isNot(contains('PHAsset.fetchAssets(')));
    expect(start, isNot(contains('authorizationStatus(for: .readWrite)')));
    expect(start, isNot(contains('requestAuthorization(for: .readWrite')));
  });
}
