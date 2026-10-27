import 'package:immich_mobile/domain/models/map.model.dart';
import 'package:immich_mobile/infrastructure/repositories/map.repository.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

typedef MapMarkerSource = Future<List<Marker>> Function(LatLngBounds? bounds);

typedef MapQuery = ({MapMarkerSource markerSource});

class MapFactory {
  final MapRepository _mapRepository;

  const MapFactory({required this._mapRepository});

  MapService remote(List<String> userIds, String currentUserId, TimelineMapOptions options) => MapService(
    _mapRepository.remote(userIds, currentUserId, options),
    viewportSource: () => _mapRepository.getInitialViewport(userIds, currentUserId, options),
  );
}

class MapService {
  final MapMarkerSource _markerSource;
  final Future<MapViewport?> Function()? _viewportSource;

  MapService(MapQuery query, {this._viewportSource}) : _markerSource = query.markerSource;

  Future<List<Marker>> Function(LatLngBounds? bounds) get getMarkers => _markerSource;

  Future<MapViewport?> getInitialViewport() => _viewportSource?.call() ?? Future.value(null);
}
