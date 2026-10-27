import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/place.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/place_name.service.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/sync_status.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:logging/logging.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:openapi/api.dart';

/// Shared by the library card, Places preview and the default map route. The
/// owner library is the source of the initial viewport, never the device GPS.
final libraryMapLocationProvider = FutureProvider<LatLng?>((ref) {
  ref.watch(syncStatusProvider.select((state) => state.remoteContentChangedCount));
  final userId = ref.watch(currentUserProvider.select((user) => user?.id));
  if (userId == null) {
    return Future.value(null);
  }
  return ref.watch(driftProvider).mapRepository.getInitialLocation(userId);
});

final placeDetailsProvider = FutureProvider<List<Place>>((ref) {
  ref.watch(syncStatusProvider.select((state) => state.remoteContentChangedCount));
  final user = ref.watch(currentUserProvider);
  if (user == null) {
    return Future.value(const []);
  }
  return ref.watch(assetServiceProvider).getPlaceDetails(user.id);
});

// An endpoint can change without changing the signed-in owner's UUID. Keep
// this dependency local to Places so label caches follow the observed DB scope.
final _placeNamesEndpointProvider = StreamProvider<String?>((ref) {
  return ref.watch(driftProvider).storeRepository.watch(StoreKey.serverEndpoint).distinct();
});

final placeNameServiceProvider = Provider<PlaceNameService>((ref) {
  final store = ref.watch(driftProvider).storeRepository;
  final userId = ref.watch(currentUserProvider.select((user) => user?.id));
  final observedEndpoint = ref.watch(_placeNamesEndpointProvider);
  final capturedEndpoint = observedEndpoint.asData?.value;
  var disposed = false;
  bool isCurrent() {
    if (disposed || userId == null || ref.read(currentUserProvider)?.id != userId) {
      return false;
    }
    return observedEndpoint is! AsyncData<String?> ||
        ref.read(_placeNamesEndpointProvider).asData?.value == observedEndpoint.value;
  }

  final service = PlaceNameService(
    // Wait for the first authoritative DB event instead of issuing a native
    // lookup from a temporary loading instance that will immediately retire.
    namespace: () async {
      if (!isCurrent() || observedEndpoint.hasError) {
        return '';
      }
      if (observedEndpoint is! AsyncData<String?>) {
        await ref.read(_placeNamesEndpointProvider.future);
        return '';
      }
      // The loading instance only waits; the observed-data instance owns all
      // lookups, regardless of Riverpod's future/disposal notification order.
      return '$userId|${capturedEndpoint ?? ''}';
    },
    readCache: () => store.tryGet(StoreKey.localizedPlaceNames),
    writeCache: (value) async {
      if (!isCurrent()) {
        return;
      }
      // DB transactions serialize old/new session writers with endpoint
      // updates. The predicate and write must stay in the same transaction.
      await store.attachedDatabase.transaction(() async {
        if (!isCurrent() || await store.tryGet(StoreKey.serverEndpoint) != capturedEndpoint || !isCurrent()) {
          return;
        }
        await store.upsert(StoreKey.localizedPlaceNames, value);
      });
    },
    isCurrentSession: isCurrent,
    onRetryInitialization: () {
      if (observedEndpoint.hasError) {
        ref.invalidate(_placeNamesEndpointProvider);
      }
    },
  );
  ref.onDispose(() {
    disposed = true;
    service.dispose();
  });
  return service;
});

final persistedPlaceLabelsProvider = FutureProvider<Map<String, String>>((ref) {
  return ref.watch(placeNameServiceProvider).cachedLabels();
});

final resolvedPlaceLabelsProvider = StateProvider<Map<String, String>>((ref) {
  ref.watch(placeNameServiceProvider);
  return const {};
});

typedef PlaceLabelRequest = ({Place place, Locale locale});

final localizedPlaceLabelProvider = FutureProvider.autoDispose.family<String, PlaceLabelRequest>((ref, request) async {
  var wanted = true;
  ref.onDispose(() => wanted = false);
  final service = ref.watch(placeNameServiceProvider);
  final label = await service.resolve(request.place, request.locale.toLanguageTag(), isWanted: () => wanted);
  if (wanted && label != request.place.name.trim()) {
    final notifier = ref.read(resolvedPlaceLabelsProvider.notifier);
    final key = PlaceNameService.key(request.place, request.locale.toLanguageTag());
    final labels = {...notifier.state}..remove(key);
    labels[key] = label;
    while (labels.length > service.maxCacheEntries) {
      labels.remove(labels.keys.first);
    }
    notifier.state = labels;
  }
  return label;
});

/// Search the existing authenticated GeoNames endpoint for source-name aliases.
/// It supports Russian alternate names without changing stored city values or
/// sending coordinates to another service. Only a settled explicit search runs.
final placeSearchAliasesProvider = FutureProvider.autoDispose.family<List<PlacesResponseDto>, String>((
  ref,
  query,
) async {
  final normalized = query.trim();
  if (normalized.runes.length < 2) {
    return const [];
  }
  final ownerId = ref.watch(currentUserProvider.select((user) => user?.id));
  final endpoint = ref.watch(_placeNamesEndpointProvider);
  if (ownerId == null || endpoint is! AsyncData<String?>) {
    return const [];
  }
  final cancelled = Completer<void>();
  void cancel() {
    if (!cancelled.isCompleted) {
      cancelled.complete();
    }
  }

  ref.onDispose(cancel);
  await Future<void>.delayed(const Duration(milliseconds: 350));
  if (cancelled.isCompleted) {
    return const [];
  }
  try {
    final matches = await ref
        .read(apiServiceProvider)
        .searchApi
        .searchPlaces(normalized, abortTrigger: cancelled.future)
        .timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            cancel();
            return const [];
          },
        );
    return cancelled.isCompleted ? const [] : matches ?? const [];
  } on Exception {
    if (!cancelled.isCompleted) {
      Logger('PlaceSearch').info('Place-name aliases unavailable; keeping local name search');
    }
    return const [];
  }
});
