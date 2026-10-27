import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/domain/services/user.service.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/place_names.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart';

import '../medium/repository_context.dart';

class _MockApiService extends Mock implements ApiService {}

class _MockSearchApi extends Mock implements SearchApi {}

class _MockUserService extends Mock implements UserService {}

UserDto _user(String id) => UserDto(id: id, email: '$id@example.test', name: id, profileChangedAt: DateTime(2026));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _MockApiService api;
  late _MockSearchApi search;
  late ProviderContainer container;
  late MediumRepositoryContext context;
  late StreamController<UserDto?> users;

  setUp(() async {
    context = MediumRepositoryContext();
    await context.db.storeRepository.upsert(StoreKey.serverEndpoint, 'https://first.example.test/api');
    users = StreamController<UserDto?>.broadcast();
    final userService = _MockUserService();
    when(() => userService.tryGetMyUser()).thenReturn(_user('owner'));
    when(() => userService.watchMyUser()).thenAnswer((_) => users.stream);
    api = _MockApiService();
    search = _MockSearchApi();
    when(() => api.searchApi).thenReturn(search);
    container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(api),
        driftProvider.overrideWithValue(context.db),
        currentUserProvider.overrideWith((_) => CurrentUserProvider(userService)),
      ],
    );
    container.read(placeNameServiceProvider);
    await pumpEventQueue();
  });

  tearDown(() async {
    container.dispose();
    await users.close();
    await context.dispose();
  });

  test('Russian alias search uses the existing server endpoint once after settling', () async {
    when(
      () => search.searchPlaces(any(), abortTrigger: any(named: 'abortTrigger')),
    ).thenAnswer((_) async => [PlacesResponseDto(latitude: 55.75, longitude: 37.62, name: 'Moscow')]);
    final provider = placeSearchAliasesProvider('Москва');
    final subscription = container.listen(provider, (_, _) {});
    addTearDown(subscription.close);
    verifyNever(() => search.searchPlaces(any(), abortTrigger: any(named: 'abortTrigger')));
    final matches = await container.read(provider.future);
    expect(matches.single.name, 'Moscow');
    verify(() => search.searchPlaces('Москва', abortTrigger: any(named: 'abortTrigger'))).called(1);
  });

  test('short or disposed queries do not make network requests', () async {
    final short = placeSearchAliasesProvider(' М ');
    final shortSubscription = container.listen(short, (_, _) {});
    expect(await container.read(short.future), isEmpty);
    shortSubscription.close();
    final obsolete = container.listen(placeSearchAliasesProvider('Москва'), (_, _) {});
    obsolete.close();
    await container.pump();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    verifyNever(() => search.searchPlaces(any(), abortTrigger: any(named: 'abortTrigger')));
  });

  test('leaving search aborts an in-flight alias request', () async {
    final started = Completer<void>();
    final cancelled = Completer<void>();
    final result = Completer<List<PlacesResponseDto>?>();
    when(() => search.searchPlaces(any(), abortTrigger: any(named: 'abortTrigger'))).thenAnswer((invocation) {
      unawaited((invocation.namedArguments[#abortTrigger] as Future<void>).then((_) => cancelled.complete()));
      started.complete();
      return result.future;
    });
    final subscription = container.listen(placeSearchAliasesProvider('Москва'), (_, _) {});
    await started.future;
    subscription.close();
    await container.pump();
    await cancelled.future;
    result.complete(const []);
  });

  test('offline server search retains the local name search instead of failing the page', () async {
    when(
      () => search.searchPlaces(any(), abortTrigger: any(named: 'abortTrigger')),
    ).thenThrow(ApiException(503, 'offline'));
    final provider = placeSearchAliasesProvider('Москва');
    final subscription = container.listen(provider, (_, _) {});
    addTearDown(subscription.close);
    expect(await container.read(provider.future), isEmpty);
  });

  for (final sessionChange in ['owner', 'endpoint']) {
    test('changing $sessionChange aborts the same-query alias request and ignores its old result', () async {
      final started = Completer<void>();
      final cancelled = Completer<void>();
      final obsolete = Completer<List<PlacesResponseDto>?>();
      var calls = 0;
      when(() => search.searchPlaces(any(), abortTrigger: any(named: 'abortTrigger'))).thenAnswer((invocation) {
        calls++;
        if (calls == 1) {
          unawaited((invocation.namedArguments[#abortTrigger] as Future<void>).then((_) => cancelled.complete()));
          started.complete();
          return obsolete.future;
        }
        return Future.value([PlacesResponseDto(latitude: 55.75, longitude: 37.62, name: 'Current Moscow')]);
      });
      final provider = placeSearchAliasesProvider('Москва');
      final subscription = container.listen(provider, (_, _) {});
      addTearDown(subscription.close);
      await started.future;
      if (sessionChange == 'owner') {
        users.add(_user('another-owner'));
      } else {
        await context.db.storeRepository.upsert(StoreKey.serverEndpoint, 'https://second.example.test/api');
      }
      await pumpEventQueue();
      await cancelled.future;
      obsolete.complete([PlacesResponseDto(latitude: 0, longitude: 0, name: 'Obsolete place')]);
      final matches = await container.read(provider.future);
      expect(matches.single.name, 'Current Moscow');
      expect(calls, 2);
    });
  }
}
