import 'dart:math';

import 'package:immich_mobile/presentation/widgets/map/map_utils.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

class MapPhotoSelection {
  final LatLngBounds bounds;
  final double zoom;

  const MapPhotoSelection({required this.bounds, required this.zoom});

  /// Resolve the native feature currently under the tap. Cluster ids are only
  /// meaningful for the current source generation, so cancel between each await
  /// when the style, viewport selection or owning widget changes.
  static Future<MapPhotoSelection?> fromTap(
    MapLibreMapController controller,
    Point<double> point, {
    required bool Function() isCurrent,
  }) async {
    final features = await controller.queryRenderedFeatures(point, [MapUtils.clusterLayerId], null);
    if (!isCurrent() || features.isEmpty || features.first is! Map) {
      return null;
    }
    final feature = features.first as Map;
    final properties = feature['properties'];
    if (properties is! Map) {
      return null;
    }
    Iterable<dynamic> selected = [feature];
    var zoom = max(controller.cameraPosition?.zoom ?? 0, 16.0);
    if (properties['cluster_id'] case final num clusterId) {
      final count = properties['point_count'];
      if (count is! num || count <= 0 || count > 10000) {
        throw const FormatException('Photo cluster has an invalid point count');
      }
      zoom = (await controller.getClusterExpansionZoom(MapUtils.defaultSourceId, clusterId.toInt())).toDouble();
      if (!isCurrent()) {
        return null;
      }
      selected = await controller.getClusterLeaves(MapUtils.defaultSourceId, clusterId.toInt(), limit: count.toInt());
    }
    if (!isCurrent()) {
      return null;
    }
    final bounds = MapUtils.photoBounds(selected);
    return bounds == null ? null : MapPhotoSelection(bounds: bounds, zoom: zoom.clamp(0, 21));
  }
}
