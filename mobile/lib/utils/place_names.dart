import 'dart:convert';
import 'dart:math' as math;

import 'package:diacritic/diacritic.dart';
import 'package:immich_mobile/domain/models/place.model.dart';
import 'package:immich_mobile/domain/services/place_name.service.dart';

/// One display policy for cards, detail titles, search and Timeline metadata.
/// The cache index is built once per locale/cache revision, never per frame.
/// Neither raw GeoNames alternateNames nor transliteration identify a language.
class PlaceDisplayNames {
  PlaceDisplayNames(String languageTag, Map<String, String> cached)
    : languageTag = PlaceNameService.normalizeLanguageTag(languageTag),
      _cached = Map.unmodifiable(cached) {
    final candidates = <(String, String?, String?), Set<String>>{};
    for (final entry in cached.entries) {
      try {
        final parts = jsonDecode(entry.key);
        if (parts is! List ||
            parts.length != 6 ||
            parts[0] != this.languageTag ||
            parts[1] is! String ||
            (parts[2] != null && parts[2] is! String) ||
            (parts[3] != null && parts[3] is! String)) {
          continue;
        }
        final label = _trusted(entry.value);
        if (label != null) {
          final scope = (parts[1] as String, parts[2] as String?, parts[3] as String?);
          (candidates[scope] ??= {}).add(label);
        }
      } on FormatException {
        // A malformed display cache must never affect place identity or routing.
      }
    }
    _byScope = {
      for (final entry in candidates.entries)
        if (entry.value.length == 1) entry.key: entry.value.single,
    };
  }

  final String languageTag;
  final Map<String, String> _cached;
  late final Map<(String, String?, String?), String> _byScope;
  String get languageCode => languageTag.split('-').first;

  String? _trusted(String? label) {
    final value = label?.trim();
    if (value == null ||
        value.isEmpty ||
        value.length > 200 ||
        RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(value) ||
        (languageCode == 'ru' && !RegExp(r'[А-Яа-яЁё]').hasMatch(value))) {
      return null;
    }
    return value;
  }

  String label(Place place) =>
      _trusted(_cached[PlaceNameService.key(place, languageTag)]) ??
      _byScope[place.scopeIdentity] ??
      localizedPlaceNameFallback(place, languageCode);

  String? timelineLabel(Place? place) {
    if (place == null) {
      return null;
    }
    final name = place.name.trim().isNotEmpty ? label(place) : localizedPlaceRegion(place, languageCode);
    return name.isEmpty ? null : name;
  }
}

/// Search folding is deliberately not transliteration. A source name remains
/// available alongside its localized label; unknown names are shown unchanged.
String foldPlaceName(String value) => removeDiacritics(value.trim().toLowerCase()).replaceAll('ё', 'е');

/// Offline Russian display fallbacks for common source spellings. The native
/// geocoder may replace these labels when it returns a trusted localized name.
/// These labels never change stored place/EXIF metadata or photo grouping.
const _russianPlaceNames = <String, String>{
  'annino': 'Аннино',
  'belek': 'Белек',
  'druzhba': 'Дружба',
  'khimki': 'Химки',
  "khot'kovo": 'Хотьково',
  'khot’kovo': 'Хотьково',
  'moscow': 'Москва',
  'mui ne': 'Муйне',
  'nemchinovka': 'Немчиновка',
  'vnukovo': 'Внуково',
  // Two attested source aliases of the same named district, not a general
  // spelling/transliteration rule. The name was confirmed by the user.
  'vostochnoe degunino': 'Восточное Дегунино',
  'vostochnoye degunino': 'Восточное Дегунино',
  'yakovlevskoye': 'Яковлевское',
};

const _russianCountryNames = <String, String>{
  'russian federation': 'Россия',
  'russia': 'Россия',
  'turkiye': 'Турция',
  'turkey': 'Турция',
  'vietnam': 'Вьетнам',
};

const _russianRegionNames = <String, String>{
  'moscow oblast': 'Московская область',
  'moscow': 'Москва',
  'antalya': 'Анталья',
  'lam dong': 'Ламдонг',
};

/// Stable, synchronous labels keep rows readable while native localization
/// resolves. Sorting by these values also avoids reordering the scrollable
/// list whenever an asynchronous geocoder result arrives.
String localizedPlaceNameFallback(Place place, String languageCode) {
  final source = place.name.trim();
  if (languageCode != 'ru') {
    return source;
  }
  return _russianPlaceNames[foldPlaceName(source)] ?? source;
}

/// Region/country labels are presentation-only. Unrecognized source data
/// remains intact instead of guessing an administrative name.
String localizedPlaceRegion(Place place, String languageCode) {
  if (languageCode != 'ru') {
    return place.sourceRegion;
  }
  final countrySource = place.country?.trim() ?? '';
  final country = _russianCountryNames[foldPlaceName(countrySource)] ?? countrySource;
  final stateSource = place.state?.trim() ?? '';
  final state = _russianRegionNames[foldPlaceName(stateSource)] ?? stateSource;
  return [state, country].where((part) => part.isNotEmpty).join(', ');
}

bool matchesPlaceName(Place place, String label, String query) {
  final folded = foldPlaceName(query);
  return folded.isEmpty || foldPlaceName(place.name).contains(folded) || foldPlaceName(label).contains(folded);
}

/// Deterministic order while geocoder/cache results arrive asynchronously.
/// Sorting never reads the mutable localized-label providers.
int comparePlacesForDisplay(Place a, Place b, {required String languageCode}) {
  final comparison = comparePlaceNames(
    localizedPlaceNameFallback(a, languageCode),
    localizedPlaceNameFallback(b, languageCode),
    languageCode: languageCode,
  );
  if (comparison != 0) {
    return comparison;
  }
  final byName = a.name.compareTo(b.name);
  return byName != 0 ? byName : a.sourceRegion.compareTo(b.sourceRegion);
}

int comparePlaceNames(String first, String second, {required String languageCode}) {
  // Dart's code-point ordering puts Ё before А. Use the Russian alphabet when
  // requested, keeping unsupported source names intact rather than guessing.
  String sortKey(String value) {
    final folded = value.trim().toLowerCase();
    if (languageCode != 'ru') {
      return removeDiacritics(folded);
    }
    return folded.replaceAll('ё', 'е\uffff');
  }

  final firstKey = sortKey(first);
  final secondKey = sortKey(second);
  if (languageCode == 'ru') {
    final firstIsRussian = RegExp(r'^[а-яё]').hasMatch(firstKey);
    final secondIsRussian = RegExp(r'^[а-яё]').hasMatch(secondKey);
    if (firstIsRussian != secondIsRussian) {
      return firstIsRussian ? -1 : 1;
    }
  }
  final comparison = firstKey.compareTo(secondKey);
  return comparison != 0 ? comparison : first.compareTo(second);
}

/// A named search result must refer to the same area, not a homonymous city on
/// the other side of the world. No coordinates are changed by this comparison.
bool isNearbyPlace(Place place, double latitude, double longitude, {double maxDistanceMeters = 25000}) {
  final distance = _distanceToPlace(place, latitude, longitude);
  return distance != null && distance <= maxDistanceMeters;
}

/// A search alias belongs to the nearest matching library group, rather than
/// every homonym in the radius. Tied anchors are ambiguous and keep source-name
/// search available instead of guessing a region. This does not group photos or
/// change geographic metadata; the bounded radius only validates an alias.
Place? nearestPlaceForAlias(
  Iterable<Place> places,
  String sourceName,
  double latitude,
  double longitude, {
  double maxDistanceMeters = 25000,
}) {
  final foldedName = foldPlaceName(sourceName);
  Place? closest;
  double? closestDistance;
  final candidates = <({Place place, double distance})>[];
  for (final place in places) {
    if (foldPlaceName(place.name) != foldedName) {
      continue;
    }
    final distance = _distanceToPlace(place, latitude, longitude);
    if (distance == null || distance > maxDistanceMeters) {
      continue;
    }
    candidates.add((place: place, distance: distance));
    if (closestDistance == null || distance < closestDistance) {
      closest = place;
      closestDistance = distance;
    }
  }
  if (closest == null) {
    return null;
  }
  final ambiguous = candidates.any(
    (candidate) =>
        candidate.place.scopeIdentity != closest!.scopeIdentity && candidate.distance - closestDistance! <= 0.001,
  );
  return ambiguous ? null : closest;
}

double? _distanceToPlace(Place place, double latitude, double longitude) {
  if (!place.hasCoordinates ||
      !latitude.isFinite ||
      !longitude.isFinite ||
      latitude.abs() > 90 ||
      longitude.abs() > 180) {
    return null;
  }
  const radians = math.pi / 180;
  final latitudeDelta = (latitude - place.latitude!) * radians;
  final longitudeDelta = (longitude - place.longitude!) * radians;
  final haversine =
      math.pow(math.sin(latitudeDelta / 2), 2) +
      math.cos(latitude * radians) * math.cos(place.latitude! * radians) * math.pow(math.sin(longitudeDelta / 2), 2);
  return 6371000 * 2 * math.asin(math.sqrt(haversine.clamp(0, 1)));
}
