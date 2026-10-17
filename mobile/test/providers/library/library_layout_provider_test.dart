import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/library_card.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/domain/services/user.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/sync_stream.repository.dart';
import 'package:immich_mobile/providers/library/library_layout.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:mocktail/mocktail.dart';

const _a = LibraryLayoutScope(serverId: 'https://photos.example', userId: 'a');
const _b = LibraryLayoutScope(serverId: 'https://photos.example', userId: 'b');

class _MemoryPrefs implements LibraryLayoutPrefs {
  final Map<String, LibraryLayoutPreferences> saved = {};
  Completer<void>? delay;
  int writes = 0;

  @override
  LibraryLayoutPreferences load(LibraryLayoutScope scope) =>
      saved[scope.storageId] ?? LibraryLayoutPreferences.defaults();

  @override
  Future<void> save(LibraryLayoutScope scope, LibraryLayoutPreferences preferences) {
    writes++;
    saved[scope.storageId] = preferences;
    return delay?.future ?? Future.value();
  }
}

class _MockUserService extends Mock implements UserService {}

class _MockStoreRepository extends Mock implements StoreRepository {}

void main() {
  group('scope', () {
    test('canonicalizes API/trailing slash and ignores credentials/query/fragment', () {
      expect(LibraryLayoutScope.canonicalServer('https://photos.example/api/'), 'https://photos.example');
      expect(
        LibraryLayoutScope.canonicalServer('https://user:secret@photos.example/photos/?q=x#x'),
        'https://photos.example/photos',
      );
      expect(LibraryLayoutScope.canonicalServer('https://photos.example:8443'), 'https://photos.example:8443');
      expect(LibraryLayoutScope.canonicalServer('not a URL'), isNull);
      expect(LibraryLayoutScope.canonicalServer(null), isNull);
    });

    test('server and owner both participate in persistence key', () {
      const anotherServer = LibraryLayoutScope(serverId: 'https://other.example', userId: 'a');
      expect(_a.storageId, isNot(_b.storageId));
      expect(_a.storageId, isNot(anotherServer.storageId));
      expect(jsonDecode(_a.storageId), [_a.serverId, _a.userId]);
    });
  });

  group('layout notifier', () {
    late _MemoryPrefs prefs;
    late StateProvider<LibraryLayoutScope?> selectedScope;
    late ProviderContainer container;

    setUp(() {
      prefs = _MemoryPrefs();
      selectedScope = StateProvider((ref) => _a);
      container = ProviderContainer(
        overrides: [
          libraryLayoutPrefsProvider.overrideWithValue(prefs),
          libraryLayoutScopeProvider.overrideWith((ref) => ref.watch(selectedScope)),
        ],
      );
      addTearDown(container.dispose);
    });

    test('hide/show, reorder and reset persist; new container restores state', () async {
      final notifier = container.read(libraryLayoutProvider.notifier);
      await notifier.setVisible('people', false);
      await notifier.reorder(8, 0);
      expect(container.read(libraryLayoutProvider).orderedIds.first, 'albums');
      expect(container.read(libraryLayoutProvider).isVisible('people'), isFalse);

      final restarted = ProviderContainer(
        overrides: [
          libraryLayoutPrefsProvider.overrideWithValue(prefs),
          libraryLayoutScopeProvider.overrideWithValue(_a),
        ],
      );
      addTearDown(restarted.dispose);
      expect(restarted.read(libraryLayoutProvider).isVisible('people'), isFalse);
      expect(restarted.read(libraryLayoutProvider).orderedIds.first, 'albums');

      await notifier.setVisible('people', true);
      expect(container.read(libraryLayoutProvider).isVisible('people'), isTrue);
      await notifier.resetDefaults();
      expect(container.read(libraryLayoutProvider).visibleCards(), libraryCardRegistry);
      expect(prefs.load(_a).orderedIds, LibraryLayoutPreferences.defaults().orderedIds);
    });

    test('A/B switching and logout/relogin keep separate user preferences', () async {
      await container.read(libraryLayoutProvider.notifier).setVisible('people', false);
      container.read(selectedScope.notifier).state = _b;
      expect(container.read(libraryLayoutProvider).isVisible('people'), isTrue);
      await container.read(libraryLayoutProvider.notifier).setVisible('places', false);
      container.read(selectedScope.notifier).state = null;
      expect(container.read(libraryLayoutProvider).visibleCards(), libraryCardRegistry);
      container.read(selectedScope.notifier).state = _a;
      expect(container.read(libraryLayoutProvider).isVisible('people'), isFalse);
      expect(container.read(libraryLayoutProvider).isVisible('places'), isTrue);
      container.read(selectedScope.notifier).state = _b;
      expect(container.read(libraryLayoutProvider).isVisible('people'), isTrue);
      expect(container.read(libraryLayoutProvider).isVisible('places'), isFalse);
    });

    test('unauthenticated customization cannot write any user preferences', () async {
      container.read(selectedScope.notifier).state = null;
      await container.read(libraryLayoutProvider.notifier).setVisible('people', false);
      await container.read(libraryLayoutProvider.notifier).reorder(0, 4);
      await container.read(libraryLayoutProvider.notifier).resetDefaults();
      expect(container.read(libraryLayoutProvider).visibleCards(), libraryCardRegistry);
      expect(prefs.writes, 0);
    });

    test('delayed A completion cannot replace B state or newer A layout', () async {
      final delayedCompletion = Completer<void>();
      prefs.delay = delayedCompletion;
      final pendingA = container.read(libraryLayoutProvider.notifier).setVisible('people', false);
      container.read(selectedScope.notifier).state = _b;
      prefs.delay = null;
      await container.read(libraryLayoutProvider.notifier).setVisible('places', false);
      final bBeforeCompletion = container.read(libraryLayoutProvider);
      expect(prefs.load(_a).isVisible('people'), isFalse);
      expect(bBeforeCompletion.isVisible('places'), isFalse);
      delayedCompletion.complete();
      await pendingA;
      expect(container.read(libraryLayoutProvider), same(bBeforeCompletion));
      container.read(selectedScope.notifier).state = _a;
      await container.read(libraryLayoutProvider.notifier).setVisible('people', true);
      expect(container.read(libraryLayoutProvider).isVisible('people'), isTrue);
    });
  });

  group('real Store persistence and lifecycle', () {
    late Drift db;
    late StoreService store;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      db = Drift(drift.DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
      store = await StoreService.init(storeRepository: StoreRepository(db));
    });
    tearDown(() async {
      await store.dispose();
      await db.close();
    });

    test('restart, simultaneous A/B saves, and logout sync reset retain owner layouts', () async {
      final prefs = StoreLibraryLayoutPrefs(store);
      await Future.wait([
        prefs.save(_a, LibraryLayoutPreferences.defaults().setVisible('people', false)),
        prefs.save(_b, LibraryLayoutPreferences.defaults().setVisible('places', false)),
      ]);
      await SyncStreamRepository(db).reset();
      final fresh = StoreLibraryLayoutPrefs(store);
      expect(fresh.load(_a).isVisible('people'), isFalse);
      expect(fresh.load(_a).isVisible('places'), isTrue);
      expect(fresh.load(_b).isVisible('places'), isFalse);
      expect(fresh.load(_b).isVisible('people'), isTrue);
      expect(await StoreRepository(db).tryGet(StoreKey.libraryLayoutPreferences), isNotNull);
    });

    test('real scope changes to defaults when auth token disappears, despite stale current user', () async {
      await store.put(StoreKey.serverUrl, 'https://photos.example/api/');
      await store.put(StoreKey.accessToken, 'test-token');
      final service = _MockUserService();
      when(
        () => service.tryGetMyUser(),
      ).thenReturn(UserDto(id: 'a', email: 'a@example.com', name: 'A', profileChangedAt: DateTime(2026)));
      when(() => service.watchMyUser()).thenAnswer((_) => const Stream.empty());
      final container = ProviderContainer(
        overrides: [currentUserProvider.overrideWith((ref) => CurrentUserProvider(service))],
      );
      addTearDown(container.dispose);
      final changes = container.listen(libraryLayoutProvider, (_, _) {});
      addTearDown(changes.close);
      expect(container.read(libraryLayoutScopeProvider)?.storageId, _a.storageId);
      await container.read(libraryLayoutProvider.notifier).setVisible('people', false);
      await store.delete(StoreKey.accessToken);
      await container.pump();
      expect(container.read(libraryLayoutScopeProvider), isNull);
      expect(container.read(libraryLayoutProvider).isVisible('people'), isTrue);
      expect(StoreLibraryLayoutPrefs(store).load(_a).isVisible('people'), isFalse);
    });

    test('corrupted stored preference map safely falls back to defaults', () async {
      await store.put(StoreKey.libraryLayoutPreferences, 'broken JSON');
      final prefs = StoreLibraryLayoutPrefs(store);
      expect(prefs.load(_a).visibleCards(), libraryCardRegistry);
      await prefs.save(_b, LibraryLayoutPreferences.defaults().setVisible('places', false));
      expect(StoreLibraryLayoutPrefs(store).load(_b).isVisible('places'), isFalse);
    });
  });

  test('write queue survives failure and preserves newest same-user preference', () async {
    final repository = _MockStoreRepository();
    when(repository.getAll).thenAnswer((_) async => []);
    final writes = <String>[];
    var first = true;
    when(() => repository.upsert(StoreKey.libraryLayoutPreferences, any<String>())).thenAnswer((invocation) async {
      writes.add(invocation.positionalArguments[1] as String);
      if (first) {
        first = false;
        throw StateError('disk full');
      }
      return true;
    });
    final store = await StoreService.create(storeRepository: repository, listenUpdates: false);
    addTearDown(store.dispose);
    final prefs = StoreLibraryLayoutPrefs(store);
    final older = prefs.save(_a, LibraryLayoutPreferences.defaults().setVisible('people', false));
    final newer = prefs.save(_a, LibraryLayoutPreferences.defaults().setVisible('places', false));
    expect(prefs.load(_a).isVisible('people'), isTrue);
    expect(prefs.load(_a).isVisible('places'), isFalse);
    await expectLater(older, throwsStateError);
    await newer;
    expect(writes, hasLength(2));
    final fresh = StoreLibraryLayoutPrefs(store);
    expect(fresh.load(_a).isVisible('people'), isTrue);
    expect(fresh.load(_a).isVisible('places'), isFalse);
  });
}
