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
}
