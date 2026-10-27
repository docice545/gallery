import 'package:flutter/foundation.dart';

/// A place keeps the server's geographic fields as its identity. Localized labels
/// are display data only and must never be written back to EXIF or timeline keys.
@immutable
class Place {
  const Place({required this.name, required this.assetId, this.state, this.country, this.latitude, this.longitude});

  final String name;
  final String assetId;
  final String? state;
  final String? country;
  final double? latitude;
  final double? longitude;

  /// A city name alone is ambiguous across regions and countries. Keep null and
  /// empty source values distinct, matching the read-only EXIF query exactly.
  (String, String?, String?) get scopeIdentity => (name, state, country);

  /// Administrative context is source data, used as a fallback when no reliable
  /// localized label is available. It must not be guessed from the city spelling.
  String get sourceRegion => [state, country].whereType<String>().where((value) => value.trim().isNotEmpty).join(', ');

  /// Prefer refreshed metadata for this exact group, retaining the selected
  /// anchor until the next result is available. Legacy city-only routes localize
  /// only an unambiguous group rather than borrowing another city's label.
  static Place? resolveSelection(String name, Iterable<Place> places, {Place? selectedPlace}) {
    if (selectedPlace != null) {
      if (selectedPlace.name != name) {
        return null;
      }
      for (final place in places) {
        if (place.scopeIdentity == selectedPlace.scopeIdentity) {
          return place;
        }
      }
      return selectedPlace;
    }
    Place? result;
    for (final place in places) {
      if (place.name == name) {
        if (result != null) {
          return null;
        }
        result = place;
      }
    }
    return result;
  }

  bool get hasCoordinates =>
      latitude != null &&
      longitude != null &&
      latitude!.isFinite &&
      longitude!.isFinite &&
      latitude! >= -90 &&
      latitude! <= 90 &&
      longitude! >= -180 &&
      longitude! <= 180;

  @override
  bool operator ==(Object other) =>
      other is Place &&
      name == other.name &&
      assetId == other.assetId &&
      state == other.state &&
      country == other.country &&
      latitude == other.latitude &&
      longitude == other.longitude;

  @override
  int get hashCode => Object.hash(name, assetId, state, country, latitude, longitude);
}
