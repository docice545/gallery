import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/map.model.dart';
import 'package:immich_mobile/domain/services/map.service.dart';
import 'package:immich_mobile/presentation/widgets/map/map.state.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/sync_status.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';

final mapServiceProvider = Provider<MapService>(
  (ref) {
    final user = ref.watch(currentUserProvider);
    if (user == null) {
      throw Exception('User must be logged in to access map');
    }

    // Camera bounds change during every pan. They must not rebuild the source
    // or repeat the whole-library initial extent aggregation.
    final options = ref.watch(
      mapStateProvider.select(
        (state) =>
            (state.onlyFavorites, state.includeArchived, state.withPartners, state.relativeDays, state.timeRange),
      ),
    );
    final users = options.$3 ? ref.watch(timelineUsersProvider).valueOrNull ?? [user.id] : [user.id];

    final mapFactory = MapFactory(mapRepository: ref.watch(driftProvider).mapRepository);
    final mapService = mapFactory.remote(users, user.id, ref.read(mapStateProvider).toOptions());
    return mapService;
  },
  // Empty dependencies to inform the framework that this provider
  // might be used in a ProviderScope
  dependencies: const [],
);

final initialMapViewportProvider = FutureProvider<MapViewport?>((ref) {
  ref.watch(syncStatusProvider.select((state) => state.remoteContentChangedCount));
  return ref.watch(mapServiceProvider).getInitialViewport();
}, dependencies: [mapServiceProvider]);
