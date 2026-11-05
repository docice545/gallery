import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/sqlite_fresh_start.dart';
import 'package:immich_mobile/data/db/sqlite_recovery_server.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/sync_event.model.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/domain/services/sync_stream.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/sync_api.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/user_api.repository.dart';
import 'package:immich_mobile/utils/semver.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart';

import '../../repository.mocks.dart';
import '../../service.mocks.dart';
import 'fixtures/recovery_http_server.dart';

class _AuthorizedTransport extends http.BaseClient {
  final _client = IOClient();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['Authorization'] = 'Bearer synthetic-token-stays-private';
    return _client.send(request);
  }

  @override
  void close() => _client.close();
}

class _LoopbackSyncApi extends SyncApiRepository {
  final http.Client transport;
  _LoopbackSyncApi(super.api, this.transport);
  @override
  Future<void> streamChanges(
    Future<void> Function(List<SyncEvent>, Function(), Function()) onData, {
    required SemVer serverVersion,
    Set<String>? supportedSyncTypes,
    Function()? onReset,
    int batchSize = 100,
    http.Client? httpClient,
    Future<void>? abortSignal,
  }) => super.streamChanges(
    onData,
    serverVersion: serverVersion,
    supportedSyncTypes: supportedSyncTypes,
    onReset: onReset,
    batchSize: batchSize,
    httpClient: transport,
    abortSignal: abortSignal,
  );
}

void main() {
  test('full app HTTP fixture satisfies the generated account, preferences and server contracts', () async {
    final server = (await RecoveryHttpServer.start())..fullFoto = true;
    addTearDown(server.close);
    final transport = _AuthorizedTransport();
    addTearDown(transport.close);
    final client = ApiClient(basePath: server.endpoint)..client = transport;
    final api = MockApiService();
    when(() => api.usersApi).thenReturn(UsersApi(client));
    final user = await UserApiRepository(api).getMyUser();
    expect(user?.id, 'existing-owner');
    expect(user?.memoryEnabled, false);
    final info = ServerApi(client);
    expect((await info.getServerConfig())?.isInitialized, true);
    expect((await info.getServerFeatures())?.passwordLogin, true);
    expect((await info.getServerVersion())?.major, 5);
    expect(server.requests.every((r) => r.method == 'GET' && r.authenticated), true);
  });
  test(
    'fresh generation reuses login and downloads actual photos/albums through production sync; no asset writes',
    () async {
      final directory = await Directory.systemTemp.createTemp('foto24-fresh-sync-');
      addTearDown(() => directory.delete(recursive: true));
      final server = (await RecoveryHttpServer.start())..fullFoto = true;
      addTearDown(server.close);
      final file = File('${directory.path}/immich.sqlite');
      await seedFreshSqliteCandidate(
        file,
        credentials: RecoveryServerCredentials(
          'existing-owner',
          'synthetic-token-stays-private',
          Uri.parse(server.endpoint),
        ),
        user: UserDto(
          id: 'existing-owner',
          email: 'owner@example.test',
          name: 'Existing owner',
          profileChangedAt: DateTime.utc(2026),
        ),
      );
      final db = Drift(NativeDatabase(file));
      final store = await StoreService.init(storeRepository: StoreRepository(db));
      addTearDown(() async {
        await store.dispose();
        await db.close();
      });
      final transport = _AuthorizedTransport();
      addTearDown(transport.close);
      final apiClient = ApiClient(basePath: server.endpoint)..client = transport;
      final api = MockApiService();
      when(() => api.apiClient).thenReturn(apiClient);
      when(() => api.syncApi).thenReturn(SyncApi(apiClient));
      when(() => api.serverInfoApi).thenReturn(ServerApi(apiClient));
      when(() => api.assetsApi).thenReturn(AssetsApi(apiClient));
      final service = SyncStreamService(
        syncApiRepository: _LoopbackSyncApi(api, transport),
        syncStreamRepository: db.syncStreamRepository,
        localAssetRepository: db.localAssetRepository,
        trashedLocalAssetRepository: db.trashedLocalAssetRepository,
        assetMediaRepository: MockAssetMediaRepository(),
        permissionRepository: MockPermissionRepository(),
        syncMigrationRepository: db.syncMigrationRepository,
        api: api,
      );
      expect(await service.sync(), true);
      expect(server.fullDownloadResets, 1);
      expect(server.syncStreams, 1);
      expect(
        (await db.customSelect('SELECT id FROM remote_asset_entity').getSingle()).data['id'],
        RecoveryHttpServer.photoId,
      );
      expect(
        (await db.customSelect('SELECT id FROM remote_album_entity').getSingle()).data['id'],
        RecoveryHttpServer.albumId,
      );
      expect(await db.syncStreamRepository.getPendingTrashOperations(), isEmpty);
      expect(await StoreRepository(db).tryGet(StoreKey.recoveryFreshStartLibraryReady), true);
      expect(await StoreRepository(db).tryGet(StoreKey.recoveryFreshStartReview), true);
      expect(server.acknowledged.every((ack) => ack.startsWith('fresh-')), true);
      expect(
        server.requests
            .where((r) => r.method != 'GET')
            .every((r) => ['/api/sync/ack', '/api/sync/stream'].contains(r.uri.path)),
        true,
      );
      await service.sync();
      expect(server.fullDownloadResets, 1);
      expect((await db.customSelect('SELECT COUNT(*) AS n FROM remote_asset_entity').getSingle()).data['n'], 1);
    },
  );
}
