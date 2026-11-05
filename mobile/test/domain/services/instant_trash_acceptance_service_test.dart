import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/deletion_result.model.dart';
import 'package:immich_mobile/domain/services/asset.service.dart';
import 'package:immich_mobile/infrastructure/repositories/sync_stream.repository.dart';
import 'package:mocktail/mocktail.dart';

import '../../infrastructure/repository.mock.dart';
import '../../repository.mocks.dart';

void main() {
  late MockRemoteAssetRepository remote;
  late MockAssetApiRepository api;
  late MockAssetMediaRepository media;
  late AssetService service;
  final AssetTrashSnapshot snapshot = (
    scope: 'sync.trash-reset.fixture/',
    id: 'asset',
    ownerId: 'owner',
    checksum: 'checksum',
    deletedAt: DateTime.utc(2026, 11, 1),
    retainedKey: 'sync.trash-reset.fixture/owner/asset',
    retainedValue: '{"operation":"permanent","phase":"inFlight"}',
  );

  setUp(() {
    remote = MockRemoteAssetRepository();
    api = MockAssetApiRepository();
    media = MockAssetMediaRepository();
    service = AssetService(
      remoteRepository: remote,
      exifRepository: MockRemoteExifRepository(),
      localRepository: MockLocalAssetRepository(),
      apiRepository: api,
      mediaRepository: media,
      trashedLocalRepository: MockTrashedLocalAssetRepository(),
    );
    when(() => remote.beginPermanentDeletion(any())).thenAnswer((_) async => [snapshot]);
    when(() => remote.acceptPermanentDeletion(any(), any(), any())).thenAnswer((_) async {});
    when(
      () => remote.completeTrashOperation(any(), success: false, definiteFailure: any(named: 'definiteFailure')),
    ).thenAnswer((_) async {});
  });

  test('capture is persisted before the request, and durable admission retires rows without MediaStore', () async {
    final response = Completer<List<PermanentDeletionResult>>();
    when(() => api.acceptPermanentDeletion(['asset'])).thenAnswer((_) => response.future);
    final work = service.acceptPermanentDeletion(['asset']);
    await Future<void>.delayed(Duration.zero);
    verifyInOrder([
      () => remote.beginPermanentDeletion(['asset']),
      () => api.acceptPermanentDeletion(['asset']),
    ]);
    verifyNever(() => remote.acceptPermanentDeletion(any(), any(), any()));
    response.complete([const PermanentDeletionResult(id: 'asset', state: 'pending', serverAccepted: true)]);
    final result = await work;
    expect(result.single.accepted, isTrue);
    expect(result.single.complete, isFalse);
    verify(() => remote.acceptPermanentDeletion([snapshot], ['asset'], const [])).called(1);
    verifyZeroInteractions(media);
  });

  for (final state in ['pending', 'failed', 'complete']) {
    test('accepted $state is suppressed without falsely completing physical work', () async {
      when(
        () => api.acceptPermanentDeletion(['asset']),
      ).thenAnswer((_) async => [PermanentDeletionResult(id: 'asset', state: state, serverAccepted: true)]);
      final result = await service.acceptPermanentDeletion(['asset']);
      expect(result.single.complete, state == 'complete');
      verify(
        () => remote.acceptPermanentDeletion([snapshot], ['asset'], state == 'complete' ? ['asset'] : const []),
      ).called(1);
      verifyNever(
        () => remote.completeTrashOperation(any(), success: false, definiteFailure: any(named: 'definiteFailure')),
      );
      verifyZeroInteractions(media);
    });
  }

  for (final state in ['blocked', 'uncertain', 'pending']) {
    test('unaccepted $state never hides the row, with only definite rejection rolling back', () async {
      when(
        () => api.acceptPermanentDeletion(['asset']),
      ).thenAnswer((_) async => [PermanentDeletionResult(id: 'asset', state: state)]);
      final result = await service.acceptPermanentDeletion(['asset']);
      expect(result.single.accepted, isFalse);
      verify(() => remote.acceptPermanentDeletion([snapshot], const [], const [])).called(1);
      verify(
        () => remote.completeTrashOperation([snapshot], success: false, definiteFailure: state == 'blocked'),
      ).called(1);
      verifyZeroInteractions(media);
    });
  }

  test('an unexpected transport failure preserves an uncertain durable operation', () async {
    when(() => api.acceptPermanentDeletion(['asset'])).thenThrow(StateError('unknown request outcome'));
    await expectLater(service.acceptPermanentDeletion(['asset']), throwsStateError);
    verify(() => remote.completeTrashOperation([snapshot], success: false)).called(1);
    verifyNever(() => remote.acceptPermanentDeletion(any(), any(), any()));
    verifyZeroInteractions(media);
  });

  test('empty selection creates no local intent or server request', () async {
    expect(await service.acceptPermanentDeletion(const []), isEmpty);
    verifyZeroInteractions(remote);
    verifyZeroInteractions(api);
    verifyZeroInteractions(media);
  });
}
