import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/remote_image_reconciliation.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/providers/auth.provider.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/sync_status.provider.dart';
import 'package:immich_mobile/repositories/asset_api.repository.dart';

// ApiService.resolveAndSetEndpoint changes both its mutable basePath and this
// stored key. Store.api itself does not change identity, so observe the key to
// retire the old resolver and its pending responses on a real Wi-Fi switch.
final _remoteImageServerEndpointProvider = StreamProvider<String?>((ref) {
  return ref.watch(driftProvider).storeRepository.watch(StoreKey.serverEndpoint).distinct();
});

final remoteImageReconciliationProvider = Provider<RemoteImageReconciliationService>((ref) {
  final auth = ref.watch(authProvider.select((state) => (state.isAuthenticated, state.userId)));
  final api = ref.watch(apiServiceProvider);
  final endpoint = api.apiClient.basePath;
  final observedEndpoint = ref.watch(_remoteImageServerEndpointProvider);
  // The DB notification may precede StoreService.put's in-memory cache update.
  // Capture the observed DB value, falling back only before its initial event.
  final canonicalEndpoint = switch (observedEndpoint) {
    AsyncData(:final value) => value ?? '',
    _ => Store.get(StoreKey.serverEndpoint, ''),
  };
  final repository = ref.watch(driftProvider).remoteAssetRepository;
  final assetApi = ref.watch(assetApiRepositoryProvider);
  var disposed = false;
  ref.onDispose(() => disposed = true);
  bool isCurrent() {
    if (disposed) {
      return false;
    }
    final current = ref.read(authProvider);
    return auth.$1 &&
        current.isAuthenticated &&
        current.userId == auth.$2 &&
        Store.get(StoreKey.serverEndpoint, '') == canonicalEndpoint;
  }

  return RemoteImageReconciliationService(
    endpoint: Uri.parse(endpoint),
    mediaEndpoint: Uri.parse(canonicalEndpoint),
    currentEndpoint: () => Uri.parse(api.apiClient.basePath),
    isCurrentSession: isCurrent,
    isDeletionComplete: (id) async => (await assetApi.deletionStatus(id)).state == 'complete',
    retireDeletedAsset: (id) async {
      if (!isCurrent()) {
        return false;
      }
      final retired = await repository.retireConfirmedDeletedAsset(id, ownerId: auth.$2, endpoint: canonicalEndpoint);
      if (retired && isCurrent()) {
        ref.read(syncStatusProvider.notifier).markRemoteContentChanged();
      }
      return retired;
    },
    syncIncrementally: () async {
      if (isCurrent()) {
        await ref.read(backgroundSyncProvider).syncRemote();
      }
    },
  );
});
