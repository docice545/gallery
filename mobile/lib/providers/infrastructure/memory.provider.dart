import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/memory.model.dart';
import 'package:immich_mobile/domain/services/memory.service.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/repositories/memory_api.repository.dart';

final memoryManagementServiceProvider = Provider((ref) {
  return MemoryService(ref.watch(driftProvider).memoryRepository, ref.watch(memoryApiRepositoryProvider));
});

/// Session tombstones shield the UI from stale in-flight server responses. The
/// durable source remains the server and the ordinary synced memory cache.
final confirmedMemoryRemovalsProvider = StateProvider.family<Set<String>, String>((ref, ownerId) => const {});

final visibleMemoryLaneProvider = Provider<AsyncValue<List<Memory>>>(
  (ref) => ref
      .watch(memoryLaneProvider)
      .whenData(
        (memories) => memories
            .where(
              (memory) =>
                  memory.deletedAt == null &&
                  !ref.watch(confirmedMemoryRemovalsProvider(memory.ownerId)).contains(memory.id),
            )
            .toList(growable: false),
      ),
  dependencies: [memoryLaneProvider, confirmedMemoryRemovalsProvider],
);

final visibleAllMemoriesProvider = Provider.autoDispose.family<AsyncValue<List<Memory>>, bool>(
  (ref, onlyFavorites) => ref
      .watch(allMemoriesProvider(onlyFavorites))
      .whenData(
        (memories) => memories
            .where(
              (memory) =>
                  memory.deletedAt == null &&
                  !ref.watch(confirmedMemoryRemovalsProvider(memory.ownerId)).contains(memory.id),
            )
            .toList(growable: false),
      ),
  dependencies: [allMemoriesProvider, confirmedMemoryRemovalsProvider],
);

final memoryLocalChangesProvider = StreamProvider.autoDispose<int>((ref) {
  final userId = ref.watch(currentUserProvider.select((user) => user?.id));
  if (userId == null) {
    return const Stream.empty();
  }
  return ref.watch(driftProvider).memoryRepository.watchChanges(userId);
});

void _refreshAfterMemorySync(Ref ref) {
  ref.listen(memoryLocalChangesProvider, (previous, next) {
    // Ignore the initial snapshot; subsequent changes include another device's
    // hide/deletion delivered by the existing memory sync streams.
    if (previous?.hasValue == true && next.hasValue) {
      ref.invalidateSelf();
    }
  });
}

final memoryCandidatesProvider = FutureProvider.autoDispose<List<({String id, Memory memory})>>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null || !user.memoryEnabled) {
    return const [];
  }
  final timer = Timer(const Duration(minutes: 1), ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  return ref.watch(memoryApiRepositoryProvider).getCandidates();
});

final memoryLaneProvider = FutureProvider.autoDispose<List<Memory>>((ref) {
  final (userId, enabled) = ref.watch(currentUserProvider.select((user) => (user?.id, user?.memoryEnabled ?? true)));
  if (userId == null || !enabled) {
    return const [];
  }

  _refreshAfterMemorySync(ref);

  final now = DateTime.now();
  final nextMidnight = DateTime(now.year, now.month, now.day + 1);
  final timer = Timer(nextMidnight.difference(now) + const Duration(seconds: 5), ref.invalidateSelf);
  ref.onDispose(timer.cancel);

  final service = MemoryService(ref.watch(driftProvider).memoryRepository, ref.watch(memoryApiRepositoryProvider));
  return service.getMemoryLane(userId);
});

final allMemoriesProvider = FutureProvider.autoDispose.family<List<Memory>, bool>((ref, onlyFavorites) {
  final (userId, enabled) = ref.watch(currentUserProvider.select((user) => (user?.id, user?.memoryEnabled ?? true)));
  if (userId == null || !enabled) {
    return const [];
  }

  _refreshAfterMemorySync(ref);

  final service = MemoryService(ref.watch(driftProvider).memoryRepository, ref.watch(memoryApiRepositoryProvider));
  return service.getAll(userId, onlyFavorites: onlyFavorites);
});
