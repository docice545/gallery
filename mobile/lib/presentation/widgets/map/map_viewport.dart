import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:immich_mobile/domain/models/map.model.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

/// Camera-only Web Mercator projection. Original GPS and library data are never
/// normalized or written. Computing the camera here avoids native bounds APIs
/// interpreting a date-line extent as almost the whole world.
class MapViewportCamera {
  const MapViewportCamera._();

  static CameraPosition cameraForViewport(
    MapViewport? viewport, {
    required Size size,
    EdgeInsets padding = const EdgeInsets.all(24),
    double maxZoom = 12,
  }) {
    if (viewport == null || !size.width.isFinite || !size.height.isFinite || size.isEmpty) {
      return const CameraPosition(target: LatLng(0, 0), zoom: 0);
    }
    final bounds = viewport.bounds;
    final west = bounds.southwest.longitude;
    var east = bounds.northeast.longitude;
    if (east < west) {
      east += 360;
    }
    final northY = _project(bounds.northeast.latitude);
    final southY = _project(bounds.southwest.latitude);
    final width = math.max(1.0, size.width - padding.horizontal);
    final height = math.max(1.0, size.height - padding.vertical);
    final xSpan = (east - west) / 360;
    final ySpan = (southY - northY).abs();
    final zoomX = xSpan == 0 ? maxZoom : _log2(width / (512 * xSpan));
    final zoomY = ySpan == 0 ? maxZoom : _log2(height / (512 * ySpan));
    final zoom = math.min(zoomX, zoomY).clamp(0.0, maxZoom);
    final scale = 512 * math.pow(2, zoom);
    final x = (west + east) / 720 + (padding.right - padding.left) / (2 * scale);
    final y = (northY + southY) / 2 + (padding.bottom - padding.top) / (2 * scale);
    return CameraPosition(target: LatLng(_unproject(y), (x * 360 + 180) % 360 - 180), zoom: zoom);
  }

  static double _log2(double value) => math.log(value) / math.ln2;

  static double _project(double latitude) {
    final radians = latitude.clamp(-85.05112878, 85.05112878) * math.pi / 180;
    return (1 - math.log(math.tan(math.pi / 4 + radians / 2)) / math.pi) / 2;
  }

  static double _unproject(double y) {
    final value = math.pi * (1 - 2 * y.clamp(0.0, 1.0));
    return math.atan((math.exp(value) - math.exp(-value)) / 2) * 180 / math.pi;
  }
}
