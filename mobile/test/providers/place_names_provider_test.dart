import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/providers/place_names.provider.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart';

class _MockApiService extends Mock implements ApiService {}

class _MockSearchApi extends Mock implements SearchApi {}

void main() {
  late _MockApiService api;
  late _MockSearchApi search;
  late ProviderContainer container;

  setUp(() {
    api = _MockApiService();
    search = _MockSearchApi();
    when(() => api.searchApi).thenReturn(search);
    container = ProviderContainer(overrides: [apiServiceProvider.overrideWithValue(api)]);
  });

  tearDown(() => container.dispose());

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
}
