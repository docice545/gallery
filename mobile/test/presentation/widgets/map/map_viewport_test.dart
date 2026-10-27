import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/map.model.dart';
import 'package:immich_mobile/presentation/widgets/map/map_viewport.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

void main() {
  MapViewport extent(LatLng southWest, LatLng northEast) => MapViewport(
    bounds: LatLngBounds(southwest: southWest, northeast: northEast),
    photoCount: 2,
  );

  test('no GPS is neutral without requiring device location', () {
    final camera = MapViewportCamera.cameraForViewport(null, size: const Size(400, 800));
    expect(camera.target, const LatLng(0, 0));
    expect(camera.zoom, 0);
  });

  test('real GPS fits both photos and adapts to usable viewport and orientation', () {
    final viewport = extent(const LatLng(55, 37), const LatLng(56, 38));
    final portrait = MapViewportCamera.cameraForViewport(viewport, size: const Size(400, 800));
    final landscape = MapViewportCamera.cameraForViewport(viewport, size: const Size(800, 400));
    final padded = MapViewportCamera.cameraForViewport(
      viewport,
      size: const Size(400, 800),
      padding: const EdgeInsets.only(top: 50, bottom: 400),
    );
    expect(portrait.target.longitude, closeTo(37.5, 0.00001));
    expect(portrait.target.latitude, inInclusiveRange(55, 56));
    expect(portrait.zoom, greaterThan(5));
    expect(padded.zoom, lessThan(portrait.zoom));
    expect(padded.target.latitude, lessThan(portrait.target.latitude));
    expect(landscape.zoom.isFinite, isTrue);
  });

  test('date-line library fits the short Pacific arc, not Greenwich', () {
    final camera = MapViewportCamera.cameraForViewport(
      extent(const LatLng(10, 179), const LatLng(11, -179)),
      size: const Size(400, 800),
    );
    expect(camera.target.longitude.abs(), closeTo(180, 0.00001));
    expect(camera.zoom, greaterThan(6));
  });

  test('one zero-coordinate photo and polar GPS keep a finite bounded camera', () {
    for (final point in [const LatLng(0, 0), const LatLng(90, 180)]) {
      final camera = MapViewportCamera.cameraForViewport(extent(point, point), size: const Size(400, 800));
      expect(camera.target.latitude.isFinite, isTrue);
      expect(camera.zoom, 12);
    }
  });
}
