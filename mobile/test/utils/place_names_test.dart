import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/place.model.dart';
import 'package:immich_mobile/utils/place_names.dart';

void main() {
  test('Russian place labels retain their source spelling without transliteration', () {
    const names = [
      'Москва',
      'Химки',
      'Внуково',
      'Белек',
      'Муйне',
      'Немчиновка',
      'Восточное Дегунино',
      'Новая Купавна',
      'Гонолулу',
    ];
    for (final name in names) {
      expect(matchesPlaceName(Place(name: name, assetId: 'preview'), name, name.toUpperCase()), isTrue);
    }
    expect(foldPlaceName('Mũi Né'), 'mui ne');
    expect(foldPlaceName('Москва'), 'москва');
    expect(foldPlaceName('Москва'), isNot('moskva'));
  });

  test('Russian display fallbacks cover visible cities, regions and countries without mutating source fields', () {
    const cases = [
      (Place(name: 'Belek', assetId: 'b', state: 'Antalya', country: 'Türkiye'), 'Белек', 'Анталья, Турция'),
      (
        Place(name: 'Moscow', assetId: 'm', state: 'Moscow', country: 'Russian Federation'),
        'Москва',
        'Москва, Россия',
      ),
      (
        Place(name: 'Khot\'kovo', assetId: 'k', state: 'Moscow Oblast', country: 'Russian Federation'),
        'Хотьково',
        'Московская область, Россия',
      ),
      (Place(name: 'Mũi Né', assetId: 'v', state: 'Lam Dong', country: 'Vietnam'), 'Муйне', 'Ламдонг, Вьетнам'),
      (Place(name: 'Annino', assetId: 'a', state: 'Moscow', country: 'Russian Federation'), 'Аннино', 'Москва, Россия'),
      (Place(name: 'Khimki', assetId: 'h'), 'Химки', ''),
      (Place(name: 'Druzhba', assetId: 'd'), 'Дружба', ''),
      (Place(name: 'Vnukovo', assetId: 'n'), 'Внуково', ''),
      (Place(name: 'Nemchinovka', assetId: 'e'), 'Немчиновка', ''),
      (Place(name: 'Vostochnoye Degunino', assetId: 'o'), 'Восточное Дегунино', ''),
      (Place(name: 'Yakovlevskoye', assetId: 'y'), 'Яковлевское', ''),
    ];
    for (final (place, name, region) in cases) {
      final identity = place.scopeIdentity;
      expect(localizedPlaceNameFallback(place, 'ru'), name);
      expect(localizedPlaceRegion(place, 'ru'), region);
      expect(localizedPlaceNameFallback(place, 'en'), place.name);
      expect(localizedPlaceRegion(place, 'en'), place.sourceRegion);
      expect(place.scopeIdentity, identity);
    }
    const unknown = Place(name: 'Unknown Village', assetId: 'u', state: 'Unknown Province', country: 'Unknownland');
    expect(localizedPlaceNameFallback(unknown, 'ru'), 'Unknown Village');
    expect(localizedPlaceRegion(unknown, 'ru'), 'Unknown Province, Unknownland');
  });

  test('stable Russian order never depends on asynchronous geocoder labels', () {
    final places = [
      const Place(name: 'Vnukovo', assetId: 'v'),
      const Place(name: 'Moscow', assetId: 'm'),
      const Place(name: 'Belek', assetId: 'b'),
      const Place(name: 'Annino', assetId: 'a'),
    ]..sort((a, b) => comparePlacesForDisplay(a, b, languageCode: 'ru'));
    expect(places.map((place) => place.name), ['Annino', 'Belek', 'Moscow', 'Vnukovo']);
    // A different native spelling can change the visible row label, but the
    // comparator cannot be influenced by asynchronously resolved names.
    expect(
      comparePlacesForDisplay(places.first, places.last, languageCode: 'ru'),
      lessThan(0),
    );
    expect(comparePlacesForDisplay(places[2], places[2], languageCode: 'ru'), 0);
  });

  test('search accepts both localized and original names, casing and ё', () {
    const place = Place(name: 'Moscow', assetId: 'preview');
    expect(matchesPlaceName(place, 'Москва', ' МОСКВА '), isTrue);
    expect(matchesPlaceName(place, 'Москва', 'MOSCOW'), isTrue);
    expect(matchesPlaceName(place, 'Москва', 'Khimki'), isFalse);
    expect(matchesPlaceName(const Place(name: 'Орёл', assetId: 'p'), 'Орёл', 'орел'), isTrue);
  });

  test('Russian sorting puts Ё between Е and Ж and Russian labels before source fallbacks', () {
    final names = ['Honolulu', 'Жуковский', 'Химки', 'Москва', 'Белек', 'Ёлки', 'Екатеринбург'];
    names.sort((a, b) => comparePlaceNames(a, b, languageCode: 'ru'));
    expect(names, ['Белек', 'Екатеринбург', 'Ёлки', 'Жуковский', 'Москва', 'Химки', 'Honolulu']);
  });

  test('source search results must match the representative area', () {
    const place = Place(name: 'Moscow', assetId: 'p', latitude: 55.75, longitude: 37.62);
    expect(isNearbyPlace(place, 55.76, 37.61), isTrue);
    expect(isNearbyPlace(place, 46.73, -117), isFalse);
    expect(isNearbyPlace(place, double.nan, 37), isFalse);
    expect(isNearbyPlace(const Place(name: 'No GPS', assetId: 'p'), 55, 37), isFalse);
    expect(place.latitude, 55.75);
    expect(place.longitude, 37.62);
  });

  test('valid zero coordinates are not confused with missing GPS', () {
    expect(const Place(name: 'Equator', assetId: 'p', latitude: 0, longitude: 0).hasCoordinates, isTrue);
    expect(const Place(name: 'No GPS', assetId: 'p').hasCoordinates, isFalse);
    expect(const Place(name: 'Invalid', assetId: 'p', latitude: 91, longitude: 0).hasCoordinates, isFalse);
  });

  test('localized search alias chooses the nearest same-name group instead of every nearby homonym', () {
    const first = Place(name: 'Annino', assetId: 'a', state: 'Moscow', latitude: 55.5, longitude: 37.5);
    const nearHomonym = Place(name: 'Annino', assetId: 'b', state: 'Other region', latitude: 55.6, longitude: 37.5);
    const wrongName = Place(name: 'Other city', assetId: 'c', latitude: 55.60001, longitude: 37.5);
    final places = [first, nearHomonym, wrongName];
    expect(nearestPlaceForAlias(places, 'ANNINO', 55.6, 37.5), nearHomonym);
    expect(nearestPlaceForAlias(places.reversed, 'Annino', 55.6, 37.5), nearHomonym);
    expect(nearestPlaceForAlias(places, 'Annino', 55.5, 37.5), first);
    // Direct source/localized searches still match visible names independently
    // of optional alias lookup and its coordinate validation.
    expect(matchesPlaceName(first, 'Аннино', 'Аннино'), isTrue);
    expect(matchesPlaceName(nearHomonym, 'Аннино', 'Annino'), isTrue);
  });

  test('ambiguous, absent or invalid alias coordinates never borrow another place label', () {
    const first = Place(name: 'Druzhba', assetId: 'a', state: 'First', latitude: 55, longitude: 37);
    const tied = Place(name: 'Druzhba', assetId: 'b', state: 'Second', latitude: 55, longitude: 37);
    const noGps = Place(name: 'Druzhba', assetId: 'c', state: 'Third');
    expect(nearestPlaceForAlias([first, tied], 'Druzhba', 55, 37), isNull);
    expect(nearestPlaceForAlias([tied, first], 'Druzhba', 55, 37), isNull);
    expect(nearestPlaceForAlias([noGps], 'Druzhba', 55, 37), isNull);
    expect(nearestPlaceForAlias([first], 'Druzhba', 30, 31), isNull);
    expect(nearestPlaceForAlias([first], 'Druzhba', double.nan, 37), isNull);
    expect(nearestPlaceForAlias([first], 'Druzhba', 55, 181), isNull);
    expect(nearestPlaceForAlias([first], 'Unknown', 55, 37), isNull);
  });
}
