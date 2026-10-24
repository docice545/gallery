import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/local_trash.model.dart';
import 'package:immich_mobile/domain/models/pending_local_trash.model.dart';
import 'package:immich_mobile/domain/services/local_trash_sync.service.dart';
import 'package:mocktail/mocktail.dart';

import '../../fixtures/asset.stub.dart';
import '../../infrastructure/repository.mock.dart';
import '../../repository.mocks.dart';

void main() {
  final now = DateTime.utc(2026, 10, 24);
  PendingLocalTrash pending(String id) => PendingLocalTrash(
    key: 'queue/$id',
    rawValue: 'claimed-$id',
    asset: LocalAssetStub.image1.copyWith(id: id),
    albumIds: const ['camera'],
    remoteReasons: {'remote-$id': false},
    attempts: 1,
    nextAttemptAt: now.add(const Duration(minutes: 2)),
  );

  late MockTrashedLocalAssetRepository repository;
  late MockAssetMediaRepository media;
  late MockPermissionRepository permission;
  late LocalTrashSyncService service;

  setUpAll(() {
    registerFallbackValue(pending('fallback'));
  });

  setUp(() {
    repository = MockTrashedLocalAssetRepository();
    media = MockAssetMediaRepository();
    permission = MockPermissionRepository();
    when(() => permission.hasManageMediaPermission()).thenAnswer((_) async => true);
    when(() => repository.updateManageMediaPermission(any())).thenAnswer((_) async => false);
    when(() => repository.clearPermissionHashFailures()).thenAnswer((_) async {});
    when(() => repository.retryPermissionBlockedTrash(now: now)).thenAnswer((_) async {});
    when(() => repository.claimPendingTrash(now: now, limit: 32)).thenAnswer((_) async => []);
    when(() => repository.completePendingTrash(any())).thenAnswer((_) async {});
    when(() => repository.failPendingTrash(any(), any(), any(), now: now)).thenAnswer((_) async {});
    service = LocalTrashSyncService(
      repository: repository,
      mediaRepository: media,
      permissionRepository: permission,
      clock: () => now,
    );
  });

  test('missing MANAGE_MEDIA retains the queue without claiming or touching media', () async {
    when(() => permission.hasManageMediaPermission()).thenAnswer((_) async => false);

    await service.drain();

    verify(() => repository.updateManageMediaPermission(false)).called(1);
    verifyNever(() => repository.claimPendingTrash(now: now, limit: 32));
    verifyNever(() => media.trashForSync(any()));
    verifyNever(() => media.deleteAll(any(), trash: false));
  });

  test('permission restoration makes blocked work eligible before the next bounded pass', () async {
    when(() => repository.updateManageMediaPermission(true)).thenAnswer((_) async => true);

    await service.drain();

    verifyInOrder([
      () => repository.updateManageMediaPermission(true),
      () => repository.clearPermissionHashFailures(),
      () => repository.retryPermissionBlockedTrash(now: now),
      () => repository.claimPendingTrash(now: now, limit: 32),
    ]);
  });

  test('PlatformException persists each failure and never records successful deletion', () async {
    final first = pending('first');
    final second = pending('second');
    when(() => repository.claimPendingTrash(now: now, limit: 32)).thenAnswer((_) async => [first, second]);
    when(() => media.trashForSync(any())).thenThrow(
      PlatformException(
        code: 'deleteWithIds failed',
        message: 'MediaStore rejected the request',
        details: 'SecurityException',
      ),
    );

    await service.drain();
    await Future<void>.delayed(Duration.zero);

    final failures = verify(
      () => repository.failPendingTrash(captureAny(), 'deleteWithIds failed', captureAny(), now: now),
    ).captured;
    expect(failures[0], same(first));
    expect(failures[1], contains('SecurityException'));
    expect(failures[2], same(second));
    expect(failures[3], contains('MediaStore rejected'));
    verifyNever(() => repository.completePendingTrash(any()));
    verify(() => repository.claimPendingTrash(now: now, limit: 32)).called(1);
    verify(() => media.trashForSync(any())).called(1);
    verifyNever(() => media.deleteAll(any()));
    verifyNever(() => media.deleteAll(any(), trash: false));
  });

  test('partial success completes only verified IDs and keeps rejected and omitted IDs pending', () async {
    final moved = pending('moved');
    final denied = pending('denied');
    final missingResponse = pending('omitted');
    when(
      () => repository.claimPendingTrash(now: now, limit: 32),
    ).thenAnswer((_) async => [moved, denied, missingResponse]);
    when(() => media.trashForSync(any())).thenAnswer(
      (_) async => {
        'moved': const LocalTrashResult(code: 'trashed'),
        'denied': const LocalTrashResult(code: 'permissionDenied', message: 'Permission revoked'),
      },
    );

    await service.drain();

    verify(() => repository.completePendingTrash(moved)).called(1);
    verify(() => repository.failPendingTrash(denied, 'permissionDenied', 'Permission revoked', now: now)).called(1);
    verify(() => repository.failPendingTrash(missingResponse, 'invalidResponse', any(), now: now)).called(1);
    verifyNever(() => repository.completePendingTrash(denied));
    verifyNever(() => repository.completePendingTrash(missingResponse));
  });

  test('a full refusal leaves every intent pending and preserves concrete diagnostics', () async {
    final item = pending('rejected');
    when(() => repository.claimPendingTrash(now: now, limit: 32)).thenAnswer((_) async => [item]);
    when(
      () => media.trashForSync(any()),
    ).thenAnswer((_) async => {'rejected': const LocalTrashResult(code: 'userDenied', message: 'RESULT_CANCELED')});

    await service.drain();

    verify(() => repository.failPendingTrash(item, 'userDenied', 'RESULT_CANCELED', now: now)).called(1);
    verifyNever(() => repository.completePendingTrash(any()));
    verifyNever(() => media.restoreAssetsFromTrash(any()));
  });

  test('already-trashed reconciliation completes the durable intent without permanent deletion', () async {
    final item = pending('already');
    when(() => repository.claimPendingTrash(now: now, limit: 32)).thenAnswer((_) async => [item]);
    when(
      () => media.trashForSync(any()),
    ).thenAnswer((_) async => {'already': const LocalTrashResult(code: 'alreadyTrashed')});

    await service.drain();

    verify(() => repository.completePendingTrash(item)).called(1);
    verifyNever(() => repository.failPendingTrash(any(), any(), any(), now: now));
    verifyNever(() => media.deleteAll(any(), trash: false));
  });

  test('database failure cannot be reported as a completed intent', () async {
    final item = pending('db-failure');
    when(() => repository.claimPendingTrash(now: now, limit: 32)).thenAnswer((_) async => [item]);
    when(
      () => media.trashForSync(any()),
    ).thenAnswer((_) async => {'db-failure': const LocalTrashResult(code: 'trashed')});
    when(() => repository.completePendingTrash(item)).thenThrow(StateError('SQLite unavailable'));

    await expectLater(service.drain(), throwsStateError);
    verifyNever(() => repository.failPendingTrash(any(), any(), any(), now: now));
  });
}
