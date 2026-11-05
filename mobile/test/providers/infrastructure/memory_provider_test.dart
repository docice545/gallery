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
import 'package:immich_mobile/providers/infrastructure/network_status.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/repositories/memory_api.repository.dart';
import 'package:mocktail/mocktail.dart';

import '../../infrastructure/repository.mock.dart';
import '../../test_utils.dart';

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

  ProviderContainer makeContainer({Stream<bool> network = const Stream.empty()}) {
    final container = ProviderContainer(
      overrides: [
        networkTransportAvailableProvider.overrideWith((_) => network),
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
    assets: [TestUtils.createRemoteAsset(id: 'photo-$id')],
  );

  test('cached unique memories appear before offline API timeout, then server replaces the lane', () async {
    final response = Completer<List<Memory>>();
    when(() => memoryApiRepository.getMemoryLane()).thenAnswer((_) => response.future);
    when(() => memoryRepository.getAll('user-1')).thenAnswer((_) async => [memory('local'), memory('local')]);
    final container = makeContainer();
    container.listen(visibleMemoryLaneProvider, (_, _) {});
    await Future<void>.delayed(Duration.zero);
    expect(response.isCompleted, isFalse);
    expect(container.read(visibleMemoryLaneProvider).value?.map((item) => item.id), ['local']);
    container.read(confirmedMemoryRemovalsProvider('user-1').notifier).state = {'local'};
    expect(container.read(visibleMemoryLaneProvider).value, isEmpty);
    response.complete([memory('local'), memory('shared'), memory('shared')]);
    await container.read(memoryLaneProvider.future);
    expect(container.read(visibleMemoryLaneProvider).requireValue.map((item) => item.id), ['shared']);
  });

  test('offline cached lane refreshes once on reconnect without duplicating cards', () async {
    final network = StreamController<bool>.broadcast();
    addTearDown(network.close);
    var online = false;
    when(() => memoryApiRepository.getMemoryLane()).thenAnswer((_) async {
      if (!online) {
        throw StateError('Synthetic offline refusal');
      }
      return [memory('local'), memory('shared'), memory('local')];
    });
    when(() => memoryRepository.getAll('user-1')).thenAnswer((_) async => [memory('local')]);
    final container = makeContainer(network: network.stream);
    container.listen(visibleMemoryLaneProvider, (_, _) {});
    await container.read(memoryLaneProvider.future);
    network.add(false);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(visibleMemoryLaneProvider).requireValue.map((item) => item.id), ['local']);
    online = true;
    network.add(true);
    await Future<void>.delayed(Duration.zero);
    await container.read(memoryLaneProvider.future);
    expect(container.read(visibleMemoryLaneProvider).requireValue.map((item) => item.id), ['local', 'shared']);
    network.add(true);
    await Future<void>.delayed(Duration.zero);
    verify(() => memoryApiRepository.getMemoryLane()).called(2);
  });

  test('a failed memory cache cannot turn the photo surface into an error while server is pending', () async {
    final response = Completer<List<Memory>>();
    when(() => memoryApiRepository.getMemoryLane()).thenAnswer((_) => response.future);
    when(() => memoryRepository.getAll('user-1')).thenThrow(StateError('Synthetic cache read failure'));
    final container = makeContainer();
    container.listen(visibleMemoryLaneProvider, (_, _) {});
    await Future<void>.delayed(Duration.zero);
    expect(container.read(visibleMemoryLaneProvider).hasError, isFalse);
    expect(container.read(visibleMemoryLaneProvider).isLoading, isTrue);
    response.complete([memory('available')]);
    await container.read(memoryLaneProvider.future);
    expect(container.read(visibleMemoryLaneProvider).requireValue.single.id, 'available');
  });

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
