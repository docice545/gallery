import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/place.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/domain/services/place_name.service.dart';
import 'package:immich_mobile/domain/services/user.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/place_names.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:mocktail/mocktail.dart';

import '../medium/repository_context.dart';

class _MockUserService extends Mock implements UserService {}

class _MockDrift extends Mock implements Drift {}

class _MockStoreRepository extends Mock implements StoreRepository {}

Future<void> _waitFor(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for the Places session');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

UserDto _user(String id) => UserDto(id: id, email: '$id@example.test', name: id, profileChangedAt: DateTime(2026));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('de.opennoodle.gallery/place_names');
  const oldEndpoint = 'https://first.example.test/api';
  const newEndpoint = 'https://second.example.test/api';
  const place = Place(name: 'Moscow', assetId: 'preview', latitude: 55.75, longitude: 37.62);
  const request = (place: place, locale: Locale('ru', 'RU'));
  late MediumRepositoryContext context;
  late ProviderContainer container;
  late StreamController<UserDto?> users;
  late Future<String?> Function(MethodCall) nativeResult;
  late int nativeCalls;
  late _MockUserService userService;

  setUp(() async {
    context = MediumRepositoryContext();
    await context.db.storeRepository.upsert(StoreKey.serverEndpoint, oldEndpoint);
    users = StreamController<UserDto?>.broadcast();
    userService = _MockUserService();
    when(() => userService.tryGetMyUser()).thenReturn(_user('owner'));
    when(() => userService.watchMyUser()).thenAnswer((_) => users.stream);
    container = ProviderContainer(
      overrides: [
        driftProvider.overrideWithValue(context.db),
        currentUserProvider.overrideWith((_) => CurrentUserProvider(userService)),
      ],
    );
    nativeCalls = 0;
    nativeResult = (_) async => 'Москва';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) {
      nativeCalls++;
      return nativeResult(call);
    });
  });

  tearDown(() async {
    container.dispose();
    await users.close();
    await context.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  Future<PlaceNameService> currentService() async {
    container.read(placeNameServiceProvider);
    await pumpEventQueue();
    return container.read(placeNameServiceProvider);
  }

  test('initial endpoint loading creates one native lookup and reopening uses its trusted cache', () async {
    final provider = localizedPlaceLabelProvider(request);
    final subscription = container.listen(provider, (_, _) {});
    await _waitFor(() => nativeCalls == 1);
    await pumpEventQueue();
    expect(await container.read(provider.future), 'Москва');
    expect(nativeCalls, 1, reason: 'the loading instance must never race the observed-data instance');
    subscription.close();
    await container.pump();

    final reopened = container.listen(provider, (_, _) {});
    addTearDown(reopened.close);
    expect(await container.read(provider.future), 'Москва');
    expect(nativeCalls, 1, reason: 'reopening a page must not pin the native geocoder to GEOCODER_BUSY');
    final cache = jsonDecode((await context.db.storeRepository.tryGet(StoreKey.localizedPlaceNames))!) as Map;
    expect(cache['scope'], 'owner|$oldEndpoint');
    expect((cache['entries'] as List).length, 1);
  });

  test('same owner UUID on another endpoint retires pending work and its old persistent writer', () async {
    final oldResult = Completer<String?>();
    nativeResult = (_) => nativeCalls == 1 ? oldResult.future : Future.value('Москва новая');
    final old = await currentService();
    final pending = old.resolve(place, 'ru-RU', isWanted: () => true);
    await _waitFor(() => nativeCalls == 1);

    await context.db.storeRepository.upsert(StoreKey.serverEndpoint, newEndpoint);
    await pumpEventQueue();
    final current = container.read(placeNameServiceProvider);
    expect(current, isNot(same(old)));
    expect(await current.resolve(place, 'ru-RU', isWanted: () => true), 'Москва новая');
    final currentCache = await context.db.storeRepository.tryGet(StoreKey.localizedPlaceNames);
    expect((jsonDecode(currentCache!) as Map)['scope'], 'owner|$newEndpoint');

    oldResult.complete('Москва старая');
    expect(await pending, 'Moscow');
    await pumpEventQueue();
    expect(await context.db.storeRepository.tryGet(StoreKey.localizedPlaceNames), currentCache);
    expect(await old.cachedLabels(), isEmpty);
    expect(await current.cachedLabels(), containsPair(PlaceNameService.key(place, 'ru-RU'), 'Москва новая'));
  });

  test('changing owner clears presentation labels and rejects old in-flight geocoder data', () async {
    final oldResult = Completer<String?>();
    nativeResult = (_) => nativeCalls == 1 ? oldResult.future : Future.value('Москва другая');
    final old = await currentService();
    final pending = old.resolve(place, 'ru-RU', isWanted: () => true);
    await _waitFor(() => nativeCalls == 1);
    container.read(resolvedPlaceLabelsProvider.notifier).state = {'previous': 'Предыдущая'};

    users.add(_user('another-owner'));
    await pumpEventQueue();
    final current = container.read(placeNameServiceProvider);
    expect(current, isNot(same(old)));
    expect(container.read(resolvedPlaceLabelsProvider), isEmpty);
    expect(await current.resolve(place, 'ru-RU', isWanted: () => true), 'Москва другая');
    oldResult.complete('Москва старая');
    expect(await pending, 'Moscow');
    await pumpEventQueue();
    final cache = jsonDecode((await context.db.storeRepository.tryGet(StoreKey.localizedPlaceNames))!) as Map;
    expect(cache['scope'], 'another-owner|$oldEndpoint');
  });

  test('DB endpoint predicate rejects an old writer even before provider notification is consumed', () async {
    final oldResult = Completer<String?>();
    nativeResult = (_) => oldResult.future;
    final old = await currentService();
    final pending = old.resolve(place, 'ru-RU', isWanted: () => true);
    await _waitFor(() => nativeCalls == 1);
    await context.db.storeRepository.upsert(StoreKey.serverEndpoint, newEndpoint);
    oldResult.complete('Москва устаревшая');
    await pending;
    await pumpEventQueue();
    expect(await context.db.storeRepository.tryGet(StoreKey.localizedPlaceNames), isNull);
  });

  test('endpoint stream errors keep source labels and explicit retry recovers one native lookup', () async {
    container.dispose();
    final database = _MockDrift();
    final repository = _MockStoreRepository();
    var watches = 0;
    when(() => database.storeRepository).thenReturn(repository);
    when(() => repository.attachedDatabase).thenReturn(context.db);
    when(() => repository.watch(StoreKey.serverEndpoint)).thenAnswer((_) {
      watches++;
      return watches == 1
          ? Stream.error(StateError('synthetic endpoint stream failure'))
          : context.db.storeRepository.watch(StoreKey.serverEndpoint);
    });
    when(
      () => repository.tryGet(StoreKey.localizedPlaceNames),
    ).thenAnswer((_) => context.db.storeRepository.tryGet(StoreKey.localizedPlaceNames));
    when(
      () => repository.tryGet(StoreKey.serverEndpoint),
    ).thenAnswer((_) => context.db.storeRepository.tryGet(StoreKey.serverEndpoint));
    when(() => repository.upsert<String>(StoreKey.localizedPlaceNames, any())).thenAnswer(
      (invocation) =>
          context.db.storeRepository.upsert(StoreKey.localizedPlaceNames, invocation.positionalArguments[1] as String),
    );
    container = ProviderContainer(
      overrides: [
        driftProvider.overrideWithValue(database),
        currentUserProvider.overrideWith((_) => CurrentUserProvider(userService)),
      ],
    );
    final subscription = container.listen(placeNameServiceProvider, (_, _) {});
    addTearDown(subscription.close);
    await pumpEventQueue();
    final broken = container.read(placeNameServiceProvider);
    expect(await broken.resolve(place, 'ru-RU', isWanted: () => true), 'Moscow');
    expect(nativeCalls, 0);
    await broken.retryFailures();
    // Observe the same reactive provider as a mounted row. A temporary loading
    // service deliberately returns its source until the new DB stream emits.
    final labelProvider = localizedPlaceLabelProvider(request);
    final labels = container.listen(labelProvider, (_, _) {});
    addTearDown(labels.close);
    await _waitFor(() => container.read(labelProvider).valueOrNull == 'Москва');
    expect(await container.read(labelProvider.future), 'Москва');
    expect(container.read(placeNameServiceProvider), isNot(same(broken)));
    expect(watches, 2);
    expect(nativeCalls, 1);
  });

  test('runtime display labels keep an LRU bound across rows and locales without caching source fallbacks', () async {
    final service = PlaceNameService(
      namespace: () async => 'test|owner',
      readCache: () async => null,
      writeCache: (_) async {},
      lookup: (place, language) async {
        if (place.name.trim() == 'Unknown') {
          return null;
        }
        return language == 'ru-RU' ? '${place.name} по-русски' : '${place.name} in English';
      },
      maxCacheEntries: 2,
      requestInterval: Duration.zero,
    );
    addTearDown(service.dispose);
    container.dispose();
    container = ProviderContainer(overrides: [placeNameServiceProvider.overrideWithValue(service)]);
    const khimki = Place(name: 'Khimki', assetId: 'another', latitude: 55.89, longitude: 37.45);

    Future<void> visit(Place place, Locale locale) async {
      final provider = localizedPlaceLabelProvider((place: place, locale: locale));
      final subscription = container.listen(provider, (_, _) {});
      await container.read(provider.future);
      subscription.close();
      await container.pump();
    }

    await visit(place, const Locale('ru', 'RU'));
    await visit(khimki, const Locale('ru', 'RU'));
    await visit(place, const Locale('ru', 'RU'));
    expect(container.read(resolvedPlaceLabelsProvider).keys.toList(), [
      PlaceNameService.key(khimki, 'ru-RU'),
      PlaceNameService.key(place, 'ru-RU'),
    ]);
    await visit(place, const Locale('en'));
    final labels = container.read(resolvedPlaceLabelsProvider);
    expect(labels.keys.toList(), [PlaceNameService.key(place, 'ru-RU'), PlaceNameService.key(place, 'en')]);
    await visit(
      const Place(name: ' Unknown ', assetId: 'missing', latitude: 1, longitude: 2),
      const Locale('ru', 'RU'),
    );
    expect(container.read(resolvedPlaceLabelsProvider), labels, reason: 'trimmed source fallback is not a translation');
    expect(nativeCalls, 0, reason: 'the isolated lookup does not use an actual platform geocoder');
  });
}
