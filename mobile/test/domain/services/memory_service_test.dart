import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/memory.model.dart';
import 'package:immich_mobile/domain/services/memory.service.dart';
import 'package:immich_mobile/infrastructure/repositories/memory.repository.dart';
import 'package:immich_mobile/repositories/memory_api.repository.dart';
import 'package:mocktail/mocktail.dart';

class MockMemoryRepository extends Mock implements MemoryRepository {}

class MockMemoryApiRepository extends Mock implements MemoryApiRepository {}

void main() {
  late MemoryService sut;
  late MockMemoryRepository mockRepository;
  late MockMemoryApiRepository mockApiRepository;

  setUpAll(() => registerFallbackValue(DateTime.utc(2026)));

  Memory memory(String id, {String ownerId = 'user-1'}) => Memory(
    id: id,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
    ownerId: ownerId,
    type: MemoryTypeEnum.onThisDay,
    data: const MemoryData({'year': 2019}),
    isSaved: false,
    memoryAt: DateTime.utc(2019, 8, 17),
    assets: const [],
  );

  setUp(() {
    mockRepository = MockMemoryRepository();
    mockApiRepository = MockMemoryApiRepository();
    sut = MemoryService(mockRepository, mockApiRepository);

    // The local sync DB is owner-scoped: `memory` / `memory_asset` only ever stream rows
    // whose ownerId is the viewer, so a Space-shared memory never reaches it.
    when(() => mockRepository.getAll(any())).thenAnswer((_) async => [memory('own-memory')]);
    when(
      () => mockApiRepository.getMemoryLane(),
    ).thenAnswer((_) async => [memory('own-memory'), memory('shared-memory', ownerId: 'space-owner')]);
    when(() => mockRepository.markRemoved(any(), any())).thenAnswer((_) async {});
  });

  group('management', () {
    test('hide marks only the acknowledged memory cache as removed', () async {
      final removedAt = DateTime.utc(2026, 10, 5);
      when(
        () => mockApiRepository.hide('own-memory'),
      ).thenAnswer((_) async => memory('own-memory').copyWith(deletedAt: removedAt));
      await sut.hide('own-memory');
      verify(() => mockRepository.markRemoved('own-memory', removedAt)).called(1);
      verifyNever(() => mockApiRepository.delete(any()));
    });

    test('delete waits for server success before marking the cache', () async {
      when(() => mockApiRepository.delete('own-memory')).thenAnswer((_) async {});
      await sut.delete('own-memory');
      verify(() => mockApiRepository.delete('own-memory')).called(1);
      verify(() => mockRepository.markRemoved('own-memory', any())).called(1);
    });

    for (final action in ['hide', 'delete']) {
      test('$action failure leaves the local memory visible', () async {
        when(() => mockApiRepository.hide('own-memory')).thenThrow(Exception('offline'));
        when(() => mockApiRepository.delete('own-memory')).thenThrow(Exception('offline'));
        await expectLater(action == 'hide' ? sut.hide('own-memory') : sut.delete('own-memory'), throwsException);
        verifyNever(() => mockRepository.markRemoved(any(), any()));
      });
    }

    test('a cache write failure does not undo an already committed server deletion', () async {
      when(() => mockApiRepository.delete('own-memory')).thenAnswer((_) async {});
      when(() => mockRepository.markRemoved(any(), any())).thenThrow(Exception('disk unavailable'));
      await sut.delete('own-memory');
      verify(() => mockApiRepository.delete('own-memory')).called(1);
    });
  });

  group('getMemoryLane', () {
    test('offline fallback excludes pending and declined candidates', () async {
      when(() => mockApiRepository.getMemoryLane()).thenThrow(Exception('offline'));
      when(() => mockRepository.getAll(any())).thenAnswer(
        (_) async => [
          memory('ordinary'),
          memory('pending').copyWith(data: const MemoryData({'candidateState': 'pending'})),
          memory('dismissed').copyWith(data: const MemoryData({'candidateState': 'dismissed'})),
          memory('saved').copyWith(data: const MemoryData({'candidateState': 'saved'})),
          memory('hidden').copyWith(deletedAt: DateTime.utc(2026)),
        ],
      );
      expect((await sut.getMemoryLane('user-1')).map((memory) => memory.id), ['ordinary', 'saved']);
    });
    // Regression test for issue #997: memories built from Space-shared photos showed on
    // web but not in the Android app.
    test('returns the server list, which includes Space-shared memories', () async {
      final result = await sut.getMemoryLane('user-1');

      expect(result.map((m) => m.id), ['own-memory', 'shared-memory']);
      verify(() => mockApiRepository.getMemoryLane()).called(1);
      verifyNever(() => mockRepository.getAll(any()));
    });

    test('falls back to the local sync DB when the server fetch fails', () async {
      when(() => mockApiRepository.getMemoryLane()).thenThrow(Exception('offline'));

      final result = await sut.getMemoryLane('user-1');

      expect(result.map((m) => m.id), ['own-memory']);
      verify(() => mockRepository.getAll('user-1')).called(1);
    });

    // "No memories today" is a valid answer, not a failure. Falling back here would surface
    // stale local memories the server has already decided not to show.
    test('does not fall back when the server returns no memories', () async {
      when(() => mockApiRepository.getMemoryLane()).thenAnswer((_) async => []);

      final result = await sut.getMemoryLane('user-1');

      expect(result, isEmpty);
      verifyNever(() => mockRepository.getAll(any()));
    });
  });

  group('getAll', () {
    test('reads from the server so shared-space memories appear', () async {
      when(
        () => mockApiRepository.getAllMemories(onlyFavorites: any(named: 'onlyFavorites')),
      ).thenAnswer((_) async => [memory('from-server')]);

      final result = await sut.getAll('owner-1');

      expect(result.single.id, 'from-server');
      verifyNever(
        () => mockRepository.getAll(
          any(),
          onlyToday: any(named: 'onlyToday'),
          onlyFavorites: any(named: 'onlyFavorites'),
        ),
      );
    });

    test('falls back to the owner-scoped local list when the server fails', () async {
      when(
        () => mockApiRepository.getAllMemories(onlyFavorites: any(named: 'onlyFavorites')),
      ).thenThrow(Exception('offline'));
      when(
        () => mockRepository.getAll('owner-1', onlyToday: false, onlyFavorites: false),
      ).thenAnswer((_) async => [memory('from-local')]);

      expect((await sut.getAll('owner-1')).single.id, 'from-local');
    });

    test('returns empty when the server fails and the local DB is empty', () async {
      when(
        () => mockApiRepository.getAllMemories(onlyFavorites: any(named: 'onlyFavorites')),
      ).thenThrow(Exception('offline'));
      when(() => mockRepository.getAll('owner-1', onlyToday: false, onlyFavorites: false)).thenAnswer((_) async => []);

      expect(await sut.getAll('owner-1'), isEmpty);
    });

    test('threads onlyFavorites through to both paths', () async {
      when(() => mockApiRepository.getAllMemories(onlyFavorites: true)).thenAnswer((_) async => []);

      await sut.getAll('owner-1', onlyFavorites: true);

      verify(() => mockApiRepository.getAllMemories(onlyFavorites: true)).called(1);
    });
  });
}
