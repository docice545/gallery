import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/place.model.dart';
import 'package:immich_mobile/domain/services/place_name.service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const place = Place(
    name: 'Moscow',
    assetId: 'preview-1',
    state: 'Moscow',
    country: 'Russia',
    latitude: 55.75,
    longitude: 37.62,
  );
  late String? stored;
  late DateTime now;
  late int lookups;
  late PlaceNameLookup lookup;

  PlaceNameService service({String scope = 'server|owner', int maxEntries = 256}) => PlaceNameService(
    namespace: () async => scope,
    readCache: () async => stored,
    writeCache: (value) async => stored = value,
    lookup: (place, language) {
      lookups++;
      return lookup(place, language);
    },
    now: () => now,
    maxCacheEntries: maxEntries,
    requestInterval: Duration.zero,
  );

  Future<String> resolve(PlaceNameService names, [Place target = place, String locale = 'ru-RU']) =>
      names.resolve(target, locale, isWanted: () => true);

  setUp(() {
    stored = null;
    now = DateTime(2026, 10, 25);
    lookups = 0;
    lookup = (_, locale) async {
      expect(locale, 'ru-RU');
      return 'Москва';
    };
  });

  test('native lookup receives requested locale and unchanged source metadata', () async {
    const channel = MethodChannel('de.opennoodle.gallery/place_names');
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return 'Москва';
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
    );
    expect(await PlaceNameService.nativeLookup(place, 'ru-RU'), 'Москва');
    expect(received!.method, 'localizePlace');
    expect(received!.arguments, {
      'city': 'Moscow',
      'state': 'Moscow',
      'country': 'Russia',
      'latitude': 55.75,
      'longitude': 37.62,
      'languageTag': 'ru-RU',
    });
  });

  test('persists a trusted localized label, keeps original identity, restores after restart', () async {
    expect(await resolve(service()), 'Москва');
    expect(lookups, 1);
    expect(stored, isNotNull);
    expect(await resolve(service()), 'Москва');
    expect(lookups, 1, reason: 'new service instance restores the persistent cache');
    expect(place.name, 'Moscow');
    expect(place.latitude, 55.75);
    expect(place.assetId, 'preview-1');
  });

  test('a missing geocoder retains the source and caches the failure for an hour', () async {
    lookup = (_, _) async => throw PlatformException(code: 'GEOCODER_UNAVAILABLE');
    final names = service();
    expect(await resolve(names), 'Moscow');
    expect(await resolve(names), 'Moscow');
    expect(await resolve(service()), 'Moscow');
    expect(lookups, 1);
    now = now.add(const Duration(hours: 2));
    lookup = (_, _) async => 'Москва';
    expect(await resolve(names), 'Москва');
    expect(lookups, 2);
  });

  test('transient device failure does not survive restart and retries after a bounded backoff', () async {
    lookup = (_, _) async => throw PlatformException(code: 'GEOCODER_FAILED');
    final names = service();
    expect(await resolve(names), 'Moscow');
    expect(await resolve(names), 'Moscow');
    expect(lookups, 1);
    expect((jsonDecode(stored!) as Map)['entries'], isEmpty);
    lookup = (_, _) async => 'Москва';
    expect(await resolve(service()), 'Москва', reason: 'transient misses do not survive restart');
    expect(lookups, 2);
    now = now.add(const Duration(seconds: 16));
    expect(await resolve(names), 'Москва');
    expect(lookups, 3);
  });

  test('explicit foreground retry clears negative results without clearing good translations', () async {
    lookup = (_, _) async => null;
    final names = service();
    expect(await resolve(names), 'Moscow');
    lookup = (_, _) async => 'Москва';
    expect(await resolve(names), 'Moscow');
    await names.retryFailures();
    expect(await resolve(names), 'Москва');
    await names.retryFailures();
    expect(await resolve(names), 'Москва');
    expect(lookups, 2);
  });

  test('Build 19 hour-long negative cache does not pin a recovered provider to English', () async {
    stored = jsonEncode({
      'version': 1,
      'scope': 'server|owner',
      'entries': [
        {
          'key': PlaceNameService.key(place, 'ru-RU'),
          'label': null,
          'expiresAt': now.add(const Duration(hours: 1)).millisecondsSinceEpoch,
        },
      ],
    });
    expect(await resolve(service()), 'Москва');
    expect(lookups, 1);
    expect((jsonDecode(stored!) as Map)['version'], 2);
  });

  test('unsupported platforms and ignored Russian locale preserve the source spelling', () async {
    lookup = (_, _) async => throw MissingPluginException();
    expect(await resolve(service()), 'Moscow');
    stored = null;
    lookup = (_, _) async => 'Moskva';
    expect(await resolve(service()), 'Moscow');
    expect(lookups, 2);
  });

  test('no GPS and already Russian source names need no geocoder request', () async {
    expect(await resolve(service(), const Place(name: 'Mũi Né', assetId: 'p')), 'Mũi Né');
    const russian = Place(name: 'Восточное Дегунино', assetId: 'p', latitude: 55.8, longitude: 37.6);
    expect(await resolve(service(), russian), 'Восточное Дегунино');
    expect(lookups, 0);
  });

  test('cached labels are isolated by locale, source coordinates and account/server scope', () async {
    final names = service();
    expect(await resolve(names), 'Москва');
    expect(await names.cachedLabels(), containsPair(PlaceNameService.key(place, 'ru-RU'), 'Москва'));
    lookup = (_, _) async => 'Moscow';
    expect(await resolve(names, place, 'en'), 'Moscow');
    expect(lookups, 2);
    lookup = (_, _) async => 'Москва';
    expect(await resolve(service(scope: 'another-server|owner')), 'Москва');
    expect(lookups, 3);
  });

  test('concurrent requests share one native operation', () async {
    final result = Completer<String?>();
    final entered = Completer<void>();
    lookup = (_, _) {
      entered.complete();
      return result.future;
    };
    final names = service();
    final first = resolve(names);
    await entered.future;
    final second = resolve(names);
    result.complete('Москва');
    expect(await first, 'Москва');
    expect(await second, 'Москва');
    expect(lookups, 1);
  });

  test('serial queue skips disposed rows and accepts a new subscriber for a queued row', () async {
    final firstResult = Completer<String?>();
    final entered = Completer<void>();
    lookup = (request, _) {
      if (request.name == 'Moscow') {
        entered.complete();
        return firstResult.future;
      }
      return Future.value('Химки');
    };
    final names = service();
    final first = resolve(names);
    await entered.future;
    const khimki = Place(name: 'Khimki', assetId: 'p2', latitude: 55.89, longitude: 37.45);
    var originalWanted = true;
    final original = names.resolve(khimki, 'ru-RU', isWanted: () => originalWanted);
    originalWanted = false;
    final replacement = resolve(names, khimki);
    var disposedWanted = true;
    final disposed = names.resolve(
      const Place(name: 'Vnukovo', assetId: 'p3', latitude: 55.6, longitude: 37.3),
      'ru-RU',
      isWanted: () => disposedWanted,
    );
    disposedWanted = false;
    firstResult.complete('Москва');
    expect(await first, 'Москва');
    expect(await original, 'Химки');
    expect(await replacement, 'Химки');
    expect(await disposed, 'Vnukovo');
    expect(lookups, 2);
  });

  test('a slow provider cannot create an unbounded queue while scrolling', () async {
    final entered = Completer<void>();
    final result = Completer<String?>();
    lookup = (_, _) {
      entered.complete();
      return result.future;
    };
    final names = service(maxEntries: 1);
    final first = resolve(names);
    await entered.future;
    expect(
      await resolve(names, const Place(name: 'Khimki', assetId: 'p2', latitude: 55.89, longitude: 37.45)),
      'Khimki',
    );
    expect(lookups, 1);
    result.complete('Москва');
    expect(await first, 'Москва');
  });

  test('an unexpected provider error is contained without poisoning later lookups', () async {
    lookup = (_, _) async => throw StateError('synthetic provider failure');
    final names = service();
    expect(await resolve(names), 'Moscow');
    lookup = (_, _) async => 'Москва';
    expect(await resolve(names), 'Москва');
    expect(lookups, 2);
  });

  test('positive entries expire and the persistent cache has a hard size bound', () async {
    final names = service(maxEntries: 1);
    await resolve(names);
    await resolve(names, const Place(name: 'Khimki', assetId: 'p2', latitude: 55.89, longitude: 37.45));
    expect((await names.cachedLabels()).length, 1);
    await resolve(names);
    expect(lookups, 3, reason: 'oldest entry was evicted');
    now = now.add(const Duration(days: 31));
    await resolve(names);
    expect(lookups, 4);
  });

  test('corrupt cache and cache write errors leave lookup and later operations usable', () async {
    stored = 'invalid JSON';
    final names = PlaceNameService(
      namespace: () async => 'owner',
      readCache: () async => stored,
      writeCache: (_) async => throw Exception('disk unavailable'),
      lookup: (_, _) async => 'Москва',
      requestInterval: Duration.zero,
    );
    expect(await resolve(names), 'Москва');
    expect(await resolve(names), 'Москва');
  });
}
