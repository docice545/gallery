import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/memory.model.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/domain/services/user.service.dart';
import 'package:immich_mobile/infrastructure/repositories/memory.repository.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/memory.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/repositories/memory_api.repository.dart';
import 'package:mocktail/mocktail.dart';

import '../../infrastructure/repository.mock.dart';

class MockUserService extends Mock implements UserService {}

class MockMemoryApiRepository extends Mock implements MemoryApiRepository {}

void main() {
  late MockMemoryRepository memoryRepository;
  late MockMemoryApiRepository memoryApiRepository;
  late MockUserService userService;

  UserDto user({bool memoryEnabled = true}) => UserDto(
    id: 'user-1',
    email: 'user@test.dev',
    name: 'user',
    memoryEnabled: memoryEnabled,
    profileChangedAt: DateTime(2026),
  );

  Drift mockDrift(MemoryRepository repository) {
    final drift = MockDrift();
    when(() => drift.memoryRepository).thenReturn(repository);
    return drift;
  }

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [
        driftProvider.overrideWithValue(mockDrift(memoryRepository)),
        memoryApiRepositoryProvider.overrideWithValue(memoryApiRepository),
        currentUserProvider.overrideWith((ref) => CurrentUserProvider(userService)),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  setUp(() {
    memoryRepository = MockMemoryRepository();
    memoryApiRepository = MockMemoryApiRepository();
    userService = MockUserService();

    // #997 moved the memory lane onto the server, falling back to the local table only on
    // failure — so the API repository, not `getAll`, is what a successful refresh calls.
    when(() => memoryApiRepository.getMemoryLane()).thenAnswer((_) async => []);
    when(() => memoryRepository.getAll('user-1')).thenAnswer((_) async => []);
    when(() => memoryRepository.watchChanges('user-1')).thenAnswer((_) => const Stream.empty());
    when(() => userService.tryGetMyUser()).thenReturn(user());
    when(() => userService.watchMyUser()).thenAnswer((_) => const Stream.empty());
  });

  Memory memory(String id) => Memory(
    id: id,
    ownerId: 'user-1',
    type: MemoryTypeEnum.onThisDay,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
    memoryAt: DateTime.utc(2024),
    isSaved: false,
    data: const MemoryData({'year': 2024}),
    assets: const [],
  );

  test('confirmed removal filters lane and list immediately while refresh remains pending', () async {
    final original = [memory('two-years-ago'), memory('remaining')];
    when(() => memoryApiRepository.getMemoryLane()).thenAnswer((_) async => original);
    when(() => memoryApiRepository.getAllMemories()).thenAnswer((_) async => original);
    final container = makeContainer();
    container.listen(visibleMemoryLaneProvider, (_, _) {});
    container.listen(visibleAllMemoriesProvider(false), (_, _) {});
    await container.read(memoryLaneProvider.future);
    await container.read(allMemoriesProvider(false).future);
    expect(container.read(visibleMemoryLaneProvider).requireValue, hasLength(2));
    final delayedRefresh = Completer<List<Memory>>();
    when(() => memoryApiRepository.getMemoryLane()).thenAnswer((_) => delayedRefresh.future);
    when(() => memoryApiRepository.getAllMemories()).thenAnswer((_) => delayedRefresh.future);
    container.read(confirmedMemoryRemovalsProvider('user-1').notifier).state = {'two-years-ago'};
    container.invalidate(memoryLaneProvider);
    container.invalidate(allMemoriesProvider);
    expect(container.read(visibleMemoryLaneProvider).requireValue.map((value) => value.id), ['remaining']);
    expect(container.read(visibleAllMemoriesProvider(false)).requireValue.map((value) => value.id), ['remaining']);
    delayedRefresh.complete(original);
    await container.read(memoryLaneProvider.future);
    await container.read(allMemoriesProvider(false).future);
    expect(container.read(visibleMemoryLaneProvider).requireValue.map((value) => value.id), ['remaining']);
    expect(container.read(visibleAllMemoriesProvider(false)).requireValue.map((value) => value.id), ['remaining']);
  });

  test('another device sync change refreshes the server-backed lane and full list', () async {
    final changes = StreamController<int>.broadcast();
    addTearDown(changes.close);
    when(() => memoryRepository.watchChanges('user-1')).thenAnswer((_) => changes.stream);
    var serverMemories = [memory('two-years-ago')];
    when(() => memoryApiRepository.getMemoryLane()).thenAnswer((_) async => serverMemories);
    when(() => memoryApiRepository.getAllMemories()).thenAnswer((_) async => serverMemories);
    final container = makeContainer();
    container.listen(visibleMemoryLaneProvider, (_, _) {});
    container.listen(visibleAllMemoriesProvider(false), (_, _) {});
    await container.read(memoryLaneProvider.future);
    await container.read(allMemoriesProvider(false).future);
    changes.add(1);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(visibleMemoryLaneProvider).requireValue, hasLength(1));
    serverMemories = [];
    changes.add(2);
    await Future<void>.delayed(Duration.zero);
    await container.read(memoryLaneProvider.future);
    await container.read(allMemoriesProvider(false).future);
    expect(container.read(visibleMemoryLaneProvider).requireValue, isEmpty);
    expect(container.read(visibleAllMemoriesProvider(false)).requireValue, isEmpty);
  });

  group('memoryLaneProvider', () {
    test('re-queries after local midnight', () {
      fakeAsync((async) {
        final container = makeContainer();
        container.listen(memoryLaneProvider, (_, _) {});
        async.flushMicrotasks();

        verify(() => memoryApiRepository.getMemoryLane()).called(1);

        async.elapse(const Duration(seconds: 4));
        async.flushMicrotasks();
        verifyNever(() => memoryApiRepository.getMemoryLane());

        async.elapse(const Duration(hours: 25));
        async.flushMicrotasks();
        verify(() => memoryApiRepository.getMemoryLane()).called(greaterThanOrEqualTo(1));
      });
    });

    test('cancels the midnight timer when disposed', () {
      fakeAsync((async) {
        final container = makeContainer();
        final subscription = container.listen(memoryLaneProvider, (_, _) {});
        async.flushMicrotasks();
        verify(() => memoryApiRepository.getMemoryLane()).called(1);

        subscription.close();
        async.elapse(const Duration(hours: 25));
        async.flushMicrotasks();

        verifyNever(() => memoryApiRepository.getMemoryLane());
      });
    });

    test('does not query or arm the timer when memories are disabled', () {
      when(() => userService.tryGetMyUser()).thenReturn(user(memoryEnabled: false));

      fakeAsync((async) {
        final container = makeContainer();
        container.listen(memoryLaneProvider, (_, _) {});
        async.flushMicrotasks();

        async.elapse(const Duration(hours: 25));
        async.flushMicrotasks();

        verifyNever(() => memoryRepository.getAll(any()));
      });
    });
  });
}
