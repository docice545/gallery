import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:immich_mobile/domain/models/time_range.model.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

part 'map.model.freezed.dart';

/// Read-only geography of the eligible photos, not a device location.
class MapViewport {
  const MapViewport({required this.bounds, required this.photoCount});

  final LatLngBounds bounds;
  final int photoCount;
}

@freezed
abstract class Marker with _$Marker {
  const factory Marker({required LatLng location, required String assetId}) = _Marker;
}

@Freezed(fromJson: false, toJson: false)
abstract class TimelineMapOptions with _$TimelineMapOptions {
  const factory TimelineMapOptions({
    required LatLngBounds bounds,

    @Default(false) bool onlyFavorites,
    @Default(false) bool includeArchived,
    @Default(false) bool withPartners,
    @Default(0) int relativeDays,

    @Default(TimeRange()) TimeRange timeRange,
  }) = _TimelineMapOptions;
}
