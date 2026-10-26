import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/deletion_result.model.dart';
import 'package:immich_mobile/domain/models/remote_image_http_exception.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/models/auth/auth_state.model.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/providers/auth.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/remote_image_reconciliation.provider.dart';
import 'package:immich_mobile/repositories/asset_api.repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart';

import '../medium/repository_context.dart';
import '../repository.mocks.dart';
import '../service.mocks.dart';

class _AuthNotifier extends StateNotifier<AuthState> with Mock implements AuthNotifier {
  _AuthNotifier()
    : super(
        const AuthState(
          deviceId: 'test-device',
          userId: 'owner',
          userEmail: 'owner@example.test',
          name: 'owner',
          profileImagePath: '',
          isAdmin: false,
          isAuthenticated: true,
        ),
      );
}

const _oldEndpoint = 'https://example.test/api';
const _newEndpoint = 'http://192.0.2.2:2283/api';
const _id = '8dd6007e-f11b-4bf8-bc3a-121794f37303';
const _other = 'a37fcb48-5cf3-47e2-97ea-4b16898756ee';
RemoteImageHttpException _error(String id) => RemoteImageHttpException(
  statusCode: 400,
  requestId: 1,
  requestPath: '/api/assets/$id/thumbnail',
  finalPath: '/api/assets/$id/thumbnail',
  stage: 'thumbnail',
);
String _url(String endpoint, String id) => '$endpoint/assets/$id/thumbnail?size=thumbnail';

void main() {
  late MediumRepositoryContext context;
  late StoreService store;
  late ProviderContainer container;
  late ApiClient client;
  late MockAssetApiRepository assetApi;
  late int authCreations;

  setUp(() async {
    context = MediumRepositoryContext();
    store = await StoreService.init(storeRepository: context.db.storeRepository, listenUpdates: false);
    await store.put(StoreKey.serverEndpoint, _oldEndpoint);
    await context.newUser(id: 'owner');
    await context.newAuthUser(id: 'owner');
    await context.newRemoteAsset(id: _id, ownerId: 'owner', checksum: 'first');
    await context.newRemoteAsset(id: _other, ownerId: 'owner', checksum: 'second');
    client = ApiClient(basePath: _oldEndpoint);
    final api = MockApiService();
    when(() => api.apiClient).thenReturn(client);
    assetApi = MockAssetApiRepository();
    authCreations = 0;
    container = ProviderContainer(
      overrides: [
        driftProvider.overrideWithValue(context.db),
        apiServiceProvider.overrideWithValue(api),
        assetApiRepositoryProvider.overrideWithValue(assetApi),
        authProvider.overrideWith((_) {
          authCreations++;
          return _AuthNotifier();
        }),
      ],
    );
    // Thumbnail's error callback uses ref.read, without a permanent listener.
    container.read(remoteImageReconciliationProvider);
    await pumpEventQueue();
  });

  tearDown(() async {
    container.dispose();
    await store.dispose();
    await context.dispose();
  });

  test('actual Store.put on Wi-Fi switch recreates the resolver and rejects its previous in-flight response', () async {
    final oldReceipt = Completer<PermanentDeletionResult>();
    when(() => assetApi.deletionStatus(_id)).thenAnswer((_) => oldReceipt.future);
    when(
      () => assetApi.deletionStatus(_other),
    ).thenAnswer((_) async => const PermanentDeletionResult(id: _other, state: 'complete'));
    final old = container.read(remoteImageReconciliationProvider);
    final pending = old.reconcile(_error(_id), _url(_oldEndpoint, _id));
    await pumpEventQueue();

    // These are the same two mutations performed by resolveAndSetEndpoint.
    client.basePath = _newEndpoint;
    await store.put(StoreKey.serverEndpoint, _newEndpoint);
    await pumpEventQueue();
    final current = container.read(remoteImageReconciliationProvider);
    expect(current, isNot(same(old)));
    expect(current.mediaEndpoint.toString(), _newEndpoint);
    expect(authCreations, 1, reason: 'network switching must not require reauthentication');

    oldReceipt.complete(const PermanentDeletionResult(id: _id, state: 'complete'));
    expect(await pending, isFalse);
    expect(await context.db.remoteAssetRepository.get(_id), isNotNull);
    expect(await current.reconcile(_error(_other), _url(_newEndpoint, _other)), isTrue);
    expect(await context.db.remoteAssetRepository.get(_other), isNull);
    expect(await current.reconcile(_error(_id), _url(_oldEndpoint, _id)), isFalse);
  });

  test('DB endpoint notification is authoritative even when it precedes the legacy Store cache update', () async {
    when(
      () => assetApi.deletionStatus(_other),
    ).thenAnswer((_) async => const PermanentDeletionResult(id: _other, state: 'complete'));
    final old = container.read(remoteImageReconciliationProvider);
    client.basePath = _newEndpoint;
    await context.db.storeRepository.upsert(StoreKey.serverEndpoint, _newEndpoint);
    await pumpEventQueue();
    expect(store.get(StoreKey.serverEndpoint), _oldEndpoint, reason: 'simulate notification before cache update');
    final current = container.read(remoteImageReconciliationProvider);
    expect(current, isNot(same(old)));
    expect(current.mediaEndpoint.toString(), _newEndpoint);
    expect(await current.reconcile(_error(_other), _url(_newEndpoint, _other)), isFalse);

    // Completing the cache update emits no second DB event. The already
    // recreated resolver must have captured the new DB endpoint correctly.
    await store.populateCache();
    expect(container.read(remoteImageReconciliationProvider), same(current));
    expect(await current.reconcile(_error(_other), _url(_newEndpoint, _other)), isTrue);
    expect(await context.db.remoteAssetRepository.get(_other), isNull);
    expect(authCreations, 1);
  });
}
