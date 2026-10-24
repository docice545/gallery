import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/album/album.model.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/services/sync_linked_album.service.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/repositories/album_api_repository.dart';
import 'package:logging/logging.dart';
import 'package:mocktail/mocktail.dart';

import '../../infrastructure/repository.mock.dart';
import '../../service.mocks.dart';

void main() {
  // A container with the service's deps overridden but cancellationProvider left
  // alone, i.e. the root (main) isolate, where cancellationProvider has no
  // override and throws if read. The UI reads this provider here.
  ProviderContainer rootContainer() {
    final drift = MockDrift();
    when(() => drift.localAlbumRepository).thenReturn(MockLocalAlbumRepository());
    when(() => drift.remoteAlbumRepository).thenReturn(MockRemoteAlbumRepository());
    final container = ProviderContainer(
      overrides: [
        driftProvider.overrideWithValue(drift),
        albumApiRepositoryProvider.overrideWithValue(MockAlbumApiRepository()),
        storeServiceProvider.overrideWithValue(MockStoreService()),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  // Regression for #29125 (Sync Albums toggle) and #29119 (can't leave the album
  // selection screen): #28694 made the provider watch cancellationProvider, so
  // reading it off the isolate threw. The cancellation now lives on the isolate
  // call path, not the provider, so the UI can build it.
  test('builds on the root isolate without a cancellationProvider override', () {
    final container = rootContainer();

    expect(() => container.read(syncLinkedAlbumServiceProvider), returnsNormally);
    expect(container.read(syncLinkedAlbumServiceProvider), isA<SyncLinkedAlbumService>());
  });

  test('manageLinkedAlbums runs from the UI without a cancellation signal', () {
    final service = rootContainer().read(syncLinkedAlbumServiceProvider);

    expect(service.manageLinkedAlbums(const [], 'user-1'), completes);
  });

  group('syncLinkedAlbums', () {
    late MockLocalAlbumRepository localAlbums;
    late MockRemoteAlbumRepository remoteAlbums;
    late MockAlbumApiRepository api;
    late MockStoreService store;
    late SyncLinkedAlbumService service;
    late StreamSubscription<LogRecord> logSubscription;
    late Level previousLogLevel;
    final records = <LogRecord>[];
    final updatedAt = DateTime.utc(2026, 10, 24);

    LocalAlbum localAlbum(String name, {String? remoteId}) => LocalAlbum(
      id: name.toLowerCase(),
      name: name,
      updatedAt: updatedAt,
      backupSelection: BackupSelection.selected,
      linkedRemoteAlbumId: remoteId,
    );

    RemoteAlbum remoteAlbum() => RemoteAlbum(
      id: 'remote-camera',
      name: 'Camera',
      ownerId: 'owner',
      ownerName: 'Owner',
      description: '',
      createdAt: updatedAt,
      updatedAt: updatedAt,
      isActivityEnabled: true,
      order: AlbumAssetOrder.desc,
      assetCount: 1,
      isShared: false,
    );

    setUp(() {
      localAlbums = MockLocalAlbumRepository();
      remoteAlbums = MockRemoteAlbumRepository();
      api = MockAlbumApiRepository();
      store = MockStoreService();
      service = SyncLinkedAlbumService(localAlbums, remoteAlbums, api, store);
      records.clear();
      previousLogLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      logSubscription = Logger.root.onRecord.listen((record) {
        if (record.loggerName == 'SyncLinkedAlbumService') {
          records.add(record);
        }
      });
    });

    tearDown(() async {
      await logSubscription.cancel();
      Logger.root.level = previousLogLevel;
    });

    test('unlinked Camera, Screenshots and Download are normal backup albums', () async {
      when(
        () => localAlbums.getBackupAlbums(),
      ).thenAnswer((_) async => [localAlbum('Camera'), localAlbum('Screenshots'), localAlbum('Download')]);

      await service.syncLinkedAlbums('owner');

      expect(records.where((record) => record.level >= Level.WARNING), isEmpty);
      verify(() => localAlbums.getBackupAlbums()).called(1);
      verifyNoMoreInteractions(localAlbums);
      verifyZeroInteractions(remoteAlbums);
      verifyZeroInteractions(api);
      verifyZeroInteractions(store);
    });

    test('a configured link to a missing remote album still warns without changing the link', () async {
      when(
        () => localAlbums.getBackupAlbums(),
      ).thenAnswer((_) async => [localAlbum('Camera', remoteId: 'missing-remote')]);
      when(() => remoteAlbums.get('missing-remote')).thenAnswer((_) async => null);

      await service.syncLinkedAlbums('owner');

      final warnings = records.where((record) => record.level >= Level.WARNING);
      expect(warnings, hasLength(1));
      expect(warnings.single.message, contains('Linked remote album not found for ID: missing-remote'));
      verify(() => localAlbums.getBackupAlbums()).called(1);
      verifyNoMoreInteractions(localAlbums);
      verify(() => remoteAlbums.get('missing-remote')).called(1);
      verifyNoMoreInteractions(remoteAlbums);
      verifyZeroInteractions(api);
      verifyZeroInteractions(store);
    });

    test('valid links still sync missing assets and persist only successful additions', () async {
      final cancellation = Completer<void>();
      when(
        () => localAlbums.getBackupAlbums(),
      ).thenAnswer((_) async => [localAlbum('Camera', remoteId: 'remote-camera')]);
      when(() => remoteAlbums.get('remote-camera')).thenAnswer((_) async => remoteAlbum());
      when(
        () => remoteAlbums.getLinkedAssetIds('owner', 'camera', 'remote-camera'),
      ).thenAnswer((_) async => ['new-asset', 'existing-asset', 'failed-asset']);
      when(
        () => api.addAssets('remote-camera', [
          'new-asset',
          'existing-asset',
          'failed-asset',
        ], abortTrigger: cancellation.future),
      ).thenAnswer((_) async => (added: ['new-asset'], failed: ['failed-asset']));
      when(() => remoteAlbums.addAssets('remote-camera', ['new-asset'])).thenAnswer((_) async => 1);

      await service.syncLinkedAlbums('owner', cancellation: cancellation);

      verify(
        () => api.addAssets('remote-camera', [
          'new-asset',
          'existing-asset',
          'failed-asset',
        ], abortTrigger: cancellation.future),
      ).called(1);
      verifyNoMoreInteractions(api);
      verify(() => remoteAlbums.addAssets('remote-camera', ['new-asset'])).called(1);
      expect(records.where((record) => record.level >= Level.WARNING), isEmpty);
      verify(() => localAlbums.getBackupAlbums()).called(1);
      verifyNoMoreInteractions(localAlbums);
      verifyZeroInteractions(store);
    });

    test('a synchronized linked album does not repeat an add request', () async {
      when(
        () => localAlbums.getBackupAlbums(),
      ).thenAnswer((_) async => [localAlbum('Camera', remoteId: 'remote-camera')]);
      when(() => remoteAlbums.get('remote-camera')).thenAnswer((_) async => remoteAlbum());
      when(() => remoteAlbums.getLinkedAssetIds('owner', 'camera', 'remote-camera')).thenAnswer((_) async => []);

      await service.syncLinkedAlbums('owner');

      verifyZeroInteractions(api);
      verify(() => remoteAlbums.get('remote-camera')).called(1);
      verify(() => remoteAlbums.getLinkedAssetIds('owner', 'camera', 'remote-camera')).called(1);
      verifyNoMoreInteractions(remoteAlbums);
    });

    test('cancellation before sync starts performs no album work', () async {
      final cancellation = Completer<void>()..complete();

      await service.syncLinkedAlbums('owner', cancellation: cancellation);

      verifyZeroInteractions(localAlbums);
      verifyZeroInteractions(remoteAlbums);
      verifyZeroInteractions(api);
      verifyZeroInteractions(store);
    });

    test('cancellation while loading backup albums cannot start a remote request', () async {
      final cancellation = Completer<void>();
      final selectedAlbums = Completer<List<LocalAlbum>>();
      when(() => localAlbums.getBackupAlbums()).thenAnswer((_) => selectedAlbums.future);
      final sync = service.syncLinkedAlbums('owner', cancellation: cancellation);
      cancellation.complete();
      selectedAlbums.complete([localAlbum('Camera', remoteId: 'remote-camera')]);

      await sync;

      verifyZeroInteractions(remoteAlbums);
      verifyZeroInteractions(api);
    });

    test('transport cancellation is forwarded and cannot publish unconfirmed album additions', () async {
      final cancellation = Completer<void>();
      final requestStarted = Completer<void>();
      final cancelled = StateError('Request cancelled');
      when(
        () => localAlbums.getBackupAlbums(),
      ).thenAnswer((_) async => [localAlbum('Camera', remoteId: 'remote-camera')]);
      when(() => remoteAlbums.get('remote-camera')).thenAnswer((_) async => remoteAlbum());
      when(
        () => remoteAlbums.getLinkedAssetIds('owner', 'camera', 'remote-camera'),
      ).thenAnswer((_) async => ['new-asset']);
      when(() => api.addAssets('remote-camera', ['new-asset'], abortTrigger: cancellation.future)).thenAnswer((
        _,
      ) async {
        requestStarted.complete();
        await cancellation.future;
        throw cancelled;
      });

      final sync = service.syncLinkedAlbums('owner', cancellation: cancellation);
      final expectCancellation = expectLater(sync, throwsA(same(cancelled)));
      await requestStarted.future;
      cancellation.complete();
      await expectCancellation;

      verify(() => api.addAssets('remote-camera', ['new-asset'], abortTrigger: cancellation.future)).called(1);
      verifyNoMoreInteractions(api);
      verifyNever(() => remoteAlbums.addAssets('remote-camera', ['new-asset']));
    });
  });
}
