import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/widgets/common/confirm_dialog.dart';
import 'package:logging/logging.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

class MapUtils {
  static final Logger _logger = Logger("MapUtils");

  static const mapZoomToAssetLevel = 12.0;
  static const defaultSourceId = 'asset-map-markers';
  static const clusterLayerId = 'asset-photo-clusters';
  static const countLayerId = 'asset-photo-counts';

  static const photoSource = GeojsonSourceProperties(
    data: {'type': 'FeatureCollection', 'features': []},
    cluster: true,
    clusterRadius: 40,
    clusterMaxZoom: 20,
  );

  static const photoCircleProperties = CircleLayerProperties(
    circleRadius: [
      'case',
      ['has', 'point_count'],
      17,
      10,
    ],
    circleColor: '#4f46e5',
    circleBlur: 0,
    circleOpacity: 1,
    circleStrokeWidth: 2,
    circleStrokeColor: '#ffffff',
  );

  static const photoCountProperties = SymbolLayerProperties(
    textField: [
      'to-string',
      [
        'coalesce',
        ['get', 'point_count_abbreviated'],
        1,
      ],
    ],
    textFont: ['Noto Sans Regular'],
    textSize: 12,
    textColor: '#ffffff',
    textAllowOverlap: true,
    textIgnorePlacement: true,
  );

  /// Bounds for a marker/cluster selection, preserving native coordinates and
  /// the shortest longitude arc for clusters that cross the date line.
  static LatLngBounds? photoBounds(Iterable<dynamic> features) {
    final points = <LatLng>[];
    for (final feature in features) {
      if (feature is! Map || feature['geometry'] is! Map) {
        continue;
      }
      final geometry = feature['geometry'] as Map;
      final coordinates = geometry['coordinates'];
      if (geometry['type'] != 'Point' || coordinates is! List || coordinates.length < 2) {
        continue;
      }
      final longitude = coordinates[0];
      final latitude = coordinates[1];
      if (longitude is! num ||
          latitude is! num ||
          !longitude.isFinite ||
          !latitude.isFinite ||
          longitude.abs() > 180 ||
          latitude.abs() > 90) {
        continue;
      }
      points.add(LatLng(latitude.toDouble(), longitude.toDouble()));
    }
    if (points.isEmpty) {
      return null;
    }
    final latitudes = points.map((point) => point.latitude);
    final longitudes = points.map((point) => point.longitude).toList()..sort();
    var west = longitudes.first;
    var east = longitudes.last;
    var largestGap = 360 - east + west;
    for (var index = 1; index < longitudes.length; index++) {
      final gap = longitudes[index] - longitudes[index - 1];
      if (gap > largestGap) {
        largestGap = gap;
        west = longitudes[index];
        east = longitudes[index - 1];
      }
    }
    final south = latitudes.reduce((a, b) => a < b ? a : b);
    final north = latitudes.reduce((a, b) => a > b ? a : b);
    // Include the selected point in SQL BETWEEN even for zero-size coordinates.
    const epsilon = 0.000001;
    return LatLngBounds(
      southwest: LatLng((south - epsilon).clamp(-90, 90), (west - epsilon).clamp(-180, 180)),
      northeast: LatLng((north + epsilon).clamp(-90, 90), (east + epsilon).clamp(-180, 180)),
    );
  }

  static Future<(Position?, LocationPermission?)> checkPermAndGetLocation({
    required BuildContext context,
    bool silent = false,
  }) async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!context.mounted) {
        return (null, LocationPermission.unableToDetermine);
      }

      if (!serviceEnabled && !silent) {
        unawaited(showDialog(context: context, builder: (context) => _LocationServiceDisabledDialog(context)));
        return (null, LocationPermission.deniedForever);
      }

      LocationPermission permission = await Geolocator.checkPermission();
      bool shouldContinueFromDisclosure = false;

      if ((permission == LocationPermission.denied || permission == LocationPermission.deniedForever) && !silent) {
        if (!context.mounted) {
          return (null, LocationPermission.unableToDetermine);
        }

        shouldContinueFromDisclosure =
            await showDialog<bool>(
              context: context,
              builder: (context) => _LocationPermissionDisabledDialog(context),
            ) ??
            false;
        if (shouldContinueFromDisclosure && permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
        } else if (shouldContinueFromDisclosure && permission == LocationPermission.deniedForever) {
          await Geolocator.openAppSettings();
        }
      }

      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        return (null, LocationPermission.deniedForever);
      }

      final Position currentUserLocation = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 0,
          timeLimit: Duration(seconds: 5),
        ),
      );
      return (currentUserLocation, null);
    } catch (error, stack) {
      _logger.severe("Cannot get user's current location", error, stack);
      return (null, LocationPermission.unableToDetermine);
    }
  }
}

class _LocationServiceDisabledDialog extends ConfirmDialog {
  _LocationServiceDisabledDialog(BuildContext context)
    : super(
        title: context.t.map_location_service_disabled_title,
        content: context.t.map_location_service_disabled_content,
        cancel: context.t.cancel,
        ok: context.t.yes,
        onOk: () async {
          await Geolocator.openLocationSettings();
        },
      );
}

class _LocationPermissionDisabledDialog extends ConfirmDialog {
  _LocationPermissionDisabledDialog(BuildContext context)
    : super(
        title: context.t.map_no_location_permission_title,
        content: context.t.map_no_location_permission_content,
        cancel: context.t.cancel,
        ok: context.t.yes,
        onOk: () {},
      );
}
