import 'package:flutter/foundation.dart';

/// A place keeps the server's city as its identity. Localized labels are display
/// data only: they must never be written back to EXIF or used as timeline keys.
@immutable
class Place {
  const Place({required this.name, required this.assetId, this.state, this.country, this.latitude, this.longitude});

  final String name;
  final String assetId;
  final String? state;
  final String? country;
  final double? latitude;
  final double? longitude;

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
