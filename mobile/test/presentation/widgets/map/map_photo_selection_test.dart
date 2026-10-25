import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/map/map_photo_selection.dart';
import 'package:immich_mobile/presentation/widgets/map/map_utils.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:mocktail/mocktail.dart';

class _Controller extends Mock implements MapLibreMapController {}

Map<String, dynamic> point(double latitude, double longitude, [Map<String, dynamic> properties = const {}]) => {
  'type': 'Feature',
  'geometry': {
    'type': 'Point',
    'coordinates': [longitude, latitude],
  },
  'properties': properties,
};

void main() {
  const tap = Point<double>(10, 20);

  test('native source clusters nearby photos and renders crisp count markers', () {
    final source = MapUtils.photoSource.toJson();
    expect(source['cluster'], isTrue);
    expect(source['clusterRadius'], 40);
    expect(source['clusterMaxZoom'], 20);
    expect(MapUtils.photoCircleProperties.circleBlur, 0);
    expect(MapUtils.photoCircleProperties.circleOpacity, 1);
    expect(MapUtils.photoCountProperties.textField, [
      'to-string',
      [
        'coalesce',
        ['get', 'point_count_abbreviated'],
        1,
      ],
    ]);
  });

  test('cluster tap uses native split zoom and selects all matching photo coordinates', () async {
    final controller = _Controller();
    when(() => controller.queryRenderedFeatures(tap, [MapUtils.clusterLayerId], null)).thenAnswer(
      (_) async => [
        point(55.75, 37.61, {'cluster_id': 7, 'point_count': 10}),
      ],
    );
    when(() => controller.cameraPosition).thenReturn(const CameraPosition(target: LatLng(55.75, 37.61), zoom: 8));
    when(() => controller.getClusterExpansionZoom(MapUtils.defaultSourceId, 7)).thenAnswer((_) async => 12);
    when(() => controller.getClusterLeaves(MapUtils.defaultSourceId, 7, limit: 10)).thenAnswer(
      (_) async =>
          List.generate(10, (index) => point(55.75 + index / 1000, 37.61 + index / 1000, {'assetId': '$index'})),
    );
    final selection = await MapPhotoSelection.fromTap(controller, tap, isCurrent: () => true);
    expect(selection!.zoom, 12);
    expect(selection.bounds.southwest.latitude, lessThanOrEqualTo(55.75));
    expect(selection.bounds.northeast.latitude, greaterThanOrEqualTo(55.759));
    verify(() => controller.getClusterLeaves(MapUtils.defaultSourceId, 7, limit: 10)).called(1);
  });

  test('single photo keeps original coordinates and needs no cluster lookup', () async {
    final controller = _Controller();
    when(
      () => controller.queryRenderedFeatures(tap, [MapUtils.clusterLayerId], null),
    ).thenAnswer((_) async => [point(21.3, -157.8)]);
    when(() => controller.cameraPosition).thenReturn(const CameraPosition(target: LatLng(21.3, -157.8), zoom: 10));
    final selection = await MapPhotoSelection.fromTap(controller, tap, isCurrent: () => true);
    expect(selection!.zoom, 16);
    expect(selection.bounds.southwest.longitude, closeTo(-157.8, 0.00001));
    verifyNever(() => controller.getClusterExpansionZoom(any(), any()));
  });

  test('late cluster lookup cannot select photos after route/style disposal', () async {
    final controller = _Controller();
    when(() => controller.queryRenderedFeatures(tap, [MapUtils.clusterLayerId], null)).thenAnswer(
      (_) async => [
        point(55, 37, {'cluster_id': 7, 'point_count': 10}),
      ],
    );
    expect(await MapPhotoSelection.fromTap(controller, tap, isCurrent: () => false), isNull);
    verifyNever(() => controller.getClusterExpansionZoom(any(), any()));
  });

  test('date-line cluster uses shortest arc and preserves longitude association', () {
    final bounds = MapUtils.photoBounds([point(1, 179.8), point(2, -179.8)])!;
    expect(bounds.southwest.longitude, greaterThan(179));
    expect(bounds.northeast.longitude, lessThan(-179));
    expect(bounds.southwest.latitude, lessThanOrEqualTo(1));
    expect(bounds.northeast.latitude, greaterThanOrEqualTo(2));
  });

  test('missing/invalid GPS produces no selectable place, never a fake (0,0) pin', () {
    expect(
      MapUtils.photoBounds([
        {'type': 'Feature', 'geometry': null},
        {
          'geometry': {
            'type': 'Point',
            'coordinates': [null, null],
          },
        },
        point(91, 10),
        point(10, double.nan),
      ]),
      isNull,
    );
    final zero = MapUtils.photoBounds([point(0, 0)]);
    expect(zero, isNotNull); // real equator/Greenwich coordinate remains valid.
  });
}
