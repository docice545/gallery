import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:immich_mobile/domain/models/map.model.dart';
import 'package:immich_mobile/extensions/asyncvalue_extensions.dart';
import 'package:immich_mobile/extensions/maplibrecontroller_extensions.dart';
import 'package:immich_mobile/presentation/widgets/map/map_utils.dart';
import 'package:immich_mobile/presentation/widgets/map/map_viewport.dart';
import 'package:immich_mobile/utils/async_mutex.dart';
import 'package:immich_mobile/widgets/map/asset_marker_icon.dart';
import 'package:immich_mobile/widgets/map/map_style_presentation.dart';
import 'package:immich_mobile/widgets/map/map_theme_override.dart';
import 'package:logging/logging.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

/// A non-interactive map, optionally showing an asset pin or library clusters.
class MapThumbnail extends StatelessWidget {
  final Function(Point<double>, LatLng)? onTap;
  final LatLng centre;
  final String? assetMarkerRemoteId;
  final String? assetThumbhash;
  final bool showMarkerPin;
  final double zoom;
  final double height;
  final double width;
  final ThemeMode? themeMode;
  final bool showAttribution;
  final MapCreatedCallback? onCreated;
  final MapViewport? viewport;
  final Map<String, dynamic>? photoMarkers;

  const MapThumbnail({
    super.key,
    required this.centre,
    this.height = 100,
    this.width = 100,
    this.onTap,
    this.zoom = 8,
    this.assetMarkerRemoteId,
    this.assetThumbhash,
    this.showMarkerPin = false,
    this.themeMode,
    this.showAttribution = true,
    this.onCreated,
    this.viewport,
    this.photoMarkers,
  });

  @override
  Widget build(BuildContext context) => MapThemeOverride(
    themeMode: themeMode,
    mapBuilder: (style) => SizedBox(
      height: height,
      width: width,
      child: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(15)),
        child: LayoutBuilder(
          builder: (context, constraints) => style.widgetWhen(
            onData: (style) => _MapThumbnailCanvas(
              // Style replacement invalidates all native source/layer IDs.
              key: ValueKey((style, viewport != null)),
              thumbnail: this,
              style: style,
              camera: viewport == null
                  ? CameraPosition(target: centre, zoom: zoom)
                  : MapViewportCamera.cameraForViewport(viewport, size: constraints.biggest),
            ),
          ),
        ),
      ),
    ),
  );
}

class _MapThumbnailCanvas extends HookWidget {
  const _MapThumbnailCanvas({super.key, required this.thumbnail, required this.style, required this.camera});

  final MapThumbnail thumbnail;
  final String style;
  final CameraPosition camera;

  @override
  Widget build(BuildContext context) {
    final controller = useRef<MapLibreMapController?>(null);
    final styleLoaded = useState(false);
    final loadedStyle = useState(0);
    final readyLayers = useState(0);
    final languageGeneration = useRef(0);
    final styleGeneration = useRef(0);
    final markerGeneration = useRef(0);
    final markerMutex = useMemoized(AsyncMutex.new);
    final language = Localizations.localeOf(context).languageCode;
    final log = useMemoized(() => Logger('LibraryMapPreview'));

    useEffect(() {
      return () {
        styleGeneration.value++;
        languageGeneration.value++;
        markerGeneration.value++;
        controller.value = null;
      };
    }, const []);

    useEffect(() {
      final generation = ++languageGeneration.value;
      final current = controller.value;
      if (current != null && styleLoaded.value) {
        unawaited(
          MapStylePresentation.applyLanguage(
            current,
            language,
            isCurrent: () => context.mounted && generation == languageGeneration.value,
          ),
        );
      }
      return () {
        // Hooks may dispose the old effect after starting its replacement.
        // An old cleanup must not invalidate the newer request's generation.
        if (generation == languageGeneration.value) {
          languageGeneration.value++;
        }
      };
    }, [language, loadedStyle.value]);

    useEffect(() {
      final current = controller.value;
      if (styleLoaded.value && current != null && current.cameraPosition != camera) {
        Future<void> updateCamera() async {
          try {
            await current.moveCamera(CameraUpdate.newCameraPosition(camera));
          } catch (error, stack) {
            if (context.mounted && identical(current, controller.value)) {
              log.warning('Cannot update library map viewport', error, stack);
            }
          }
        }

        unawaited(updateCamera());
      }
      return null;
    }, [camera, styleLoaded.value]);

    useEffect(() {
      final generation = ++markerGeneration.value;
      final current = controller.value;
      final markers = thumbnail.photoMarkers;
      if (current != null && readyLayers.value == styleGeneration.value && readyLayers.value != 0 && markers != null) {
        unawaited(
          markerMutex.run(() async {
            if (!context.mounted || generation != markerGeneration.value) {
              return;
            }
            try {
              await current.setGeoJsonSource(MapUtils.defaultSourceId, markers);
            } catch (error, stack) {
              if (context.mounted && generation == markerGeneration.value) {
                log.warning('Cannot update library photo markers', error, stack);
              }
            }
          }),
        );
      }
      return () {
        // See language cleanup: changed keys can start the new effect first.
        if (generation == markerGeneration.value) {
          markerGeneration.value++;
        }
      };
    }, [thumbnail.photoMarkers, readyLayers.value]);

    void onMapCreated(MapLibreMapController mapController) {
      languageGeneration.value++;
      styleGeneration.value++;
      controller.value = mapController;
      styleLoaded.value = false;
      readyLayers.value = 0;
      thumbnail.onCreated?.call(mapController);
    }

    Future<void> onStyleLoaded() async {
      final current = controller.value;
      final generation = ++styleGeneration.value;
      bool isCurrent() =>
          context.mounted && generation == styleGeneration.value && identical(current, controller.value);
      if (current == null || !isCurrent()) {
        return;
      }
      languageGeneration.value++;
      markerGeneration.value++;
      readyLayers.value = 0;
      // A label patch or pin failure must never hide a rendered map in gray.
      styleLoaded.value = true;
      loadedStyle.value = generation;
      if (thumbnail.viewport != null) {
        try {
          await current.addSource(MapUtils.defaultSourceId, MapUtils.photoSource);
          if (!isCurrent()) {
            return;
          }
          await current.addCircleLayer(
            MapUtils.defaultSourceId,
            MapUtils.clusterLayerId,
            MapUtils.photoCircleProperties,
          );
          if (!isCurrent()) {
            return;
          }
          await current.addSymbolLayer(MapUtils.defaultSourceId, MapUtils.countLayerId, MapUtils.photoCountProperties);
          if (!isCurrent()) {
            return;
          }
          readyLayers.value = generation;
        } catch (error, stack) {
          if (isCurrent()) {
            log.warning('Cannot initialize library photo markers', error, stack);
          }
        }
      }
      if (thumbnail.showMarkerPin && isCurrent()) {
        try {
          await current.addMarkerAtLatLng(thumbnail.centre);
        } catch (error, stack) {
          if (isCurrent()) {
            log.warning('Cannot initialize map preview pin', error, stack);
          }
        }
      }
    }

    return Stack(
      alignment: Alignment.topCenter,
      children: [
        MapLibreMap(
          initialCameraPosition: camera,
          trackCameraPosition: true,
          styleString: style,
          onMapCreated: onMapCreated,
          onStyleLoadedCallback: onStyleLoaded,
          onMapClick: thumbnail.onTap,
          doubleClickZoomEnabled: false,
          dragEnabled: false,
          zoomGesturesEnabled: false,
          tiltGesturesEnabled: false,
          scrollGesturesEnabled: false,
          rotateGesturesEnabled: false,
          myLocationEnabled: false,
          attributionButtonMargins: thumbnail.showAttribution ? null : const Point(-100, 0),
        ),
        if (!styleLoaded.value)
          const Positioned.fill(
            child: IgnorePointer(child: Center(child: CircularProgressIndicator())),
          ),
        if (thumbnail.assetMarkerRemoteId != null && thumbnail.assetThumbhash != null)
          Container(
            width: thumbnail.width,
            height: thumbnail.height / 2,
            alignment: Alignment.bottomCenter,
            child: SizedBox.square(
              dimension: thumbnail.height / 2.5,
              child: AssetMarkerIcon(id: thumbnail.assetMarkerRemoteId!, thumbhash: thumbnail.assetThumbhash!),
            ),
          ),
      ],
    );
  }
}
