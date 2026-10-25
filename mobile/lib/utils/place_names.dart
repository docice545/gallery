import 'dart:math' as math;

import 'package:diacritic/diacritic.dart';
import 'package:immich_mobile/domain/models/place.model.dart';

/// Search folding is deliberately not transliteration. A source name remains
/// available alongside its localized label; unknown names are shown unchanged.
String foldPlaceName(String value) => removeDiacritics(value.trim().toLowerCase()).replaceAll('ё', 'е');

bool matchesPlaceName(Place place, String label, String query) {
  final folded = foldPlaceName(query);
  return folded.isEmpty || foldPlaceName(place.name).contains(folded) || foldPlaceName(label).contains(folded);
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
  if (!place.hasCoordinates ||
      !latitude.isFinite ||
      !longitude.isFinite ||
      latitude.abs() > 90 ||
      longitude.abs() > 180) {
    return false;
  }
  const radians = math.pi / 180;
  final latitudeDelta = (latitude - place.latitude!) * radians;
  final longitudeDelta = (longitude - place.longitude!) * radians;
  final haversine =
      math.pow(math.sin(latitudeDelta / 2), 2) +
      math.cos(latitude * radians) * math.cos(place.latitude! * radians) * math.pow(math.sin(longitudeDelta / 2), 2);
  final distance = 6371000 * 2 * math.asin(math.sqrt(haversine.clamp(0, 1)));
  return distance <= maxDistanceMeters;
}
