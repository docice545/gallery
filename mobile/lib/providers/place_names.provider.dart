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

final placeNameServiceProvider = Provider<PlaceNameService>((ref) {
  final store = ref.watch(driftProvider).storeRepository;
  final userId = ref.watch(currentUserProvider.select((user) => user?.id));
  return PlaceNameService(
    namespace: () async => '$userId|${await store.tryGet(StoreKey.serverEndpoint) ?? ''}',
    readCache: () => store.tryGet(StoreKey.localizedPlaceNames),
    writeCache: (value) async {
      await store.upsert(StoreKey.localizedPlaceNames, value);
    },
  );
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
  final label = await ref
      .watch(placeNameServiceProvider)
      .resolve(request.place, request.locale.toLanguageTag(), isWanted: () => wanted);
  if (wanted && label != request.place.name) {
    final notifier = ref.read(resolvedPlaceLabelsProvider.notifier);
    notifier.state = {...notifier.state, PlaceNameService.key(request.place, request.locale.toLanguageTag()): label};
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
    return await ref
            .read(apiServiceProvider)
            .searchApi
            .searchPlaces(normalized, abortTrigger: cancelled.future)
            .timeout(
              const Duration(seconds: 5),
              onTimeout: () {
                cancel();
                return const [];
              },
            ) ??
        const [];
  } on Exception {
    if (!cancelled.isCompleted) {
      Logger('PlaceSearch').info('Place-name aliases unavailable; keeping local name search');
    }
    return const [];
  }
});
