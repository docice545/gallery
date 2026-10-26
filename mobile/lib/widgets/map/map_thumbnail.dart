import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:immich_mobile/extensions/asyncvalue_extensions.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/maplibrecontroller_extensions.dart';
import 'package:immich_mobile/widgets/map/asset_marker_icon.dart';
import 'package:immich_mobile/widgets/map/map_style_presentation.dart';
import 'package:immich_mobile/widgets/map/map_theme_override.dart';
import 'package:logging/logging.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

/// A non-interactive thumbnail of a map in the given coordinates with optional markers
///
/// User can provide either a [assetMarkerRemoteId] to display the asset's thumbnail or set
/// [showMarkerPin] to true which would display a marker pin instead. If both are provided,
/// [assetMarkerRemoteId] will take precedence
class MapThumbnail extends HookWidget {
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
  });

  @override
  Widget build(BuildContext context) {
    final controller = useRef<MapLibreMapController?>(null);
    final styleLoaded = useState(false);
    final languageGeneration = useRef(0);
    final styleGeneration = useRef(0);
    final language = Localizations.localeOf(context).languageCode;
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
      return () => languageGeneration.value++;
    }, [language, styleLoaded.value]);

    useEffect(() {
      final current = controller.value;
      if (styleLoaded.value &&
          current != null &&
          (current.cameraPosition?.target != centre || current.cameraPosition?.zoom != zoom)) {
        // initialCameraPosition is read only when the native view is created.
        // A sync can provide newer library coordinates without recreating it.
        Future<void> updateCamera() async {
          try {
            await current.moveCamera(CameraUpdate.newLatLngZoom(centre, zoom));
          } catch (error, stack) {
            if (context.mounted && identical(current, controller.value)) {
              Logger('LibraryMapPreview').warning('Cannot update library map viewport', error, stack);
            }
          }
        }

        unawaited(updateCamera());
      }
      return null;
    }, [centre, zoom, styleLoaded.value]);

    Future<void> onMapCreated(MapLibreMapController mapController) async {
      languageGeneration.value++;
      styleGeneration.value++;
      controller.value = mapController;
      styleLoaded.value = false;
      onCreated?.call(mapController);
    }

    Future<void> onStyleLoaded() async {
      final current = controller.value;
      final generation = ++languageGeneration.value;
      final style = ++styleGeneration.value;
      bool isCurrentStyle() =>
          context.mounted && style == styleGeneration.value && identical(current, controller.value);
      if (current != null) {
        await MapStylePresentation.applyLanguage(
          current,
          language,
          isCurrent: () => isCurrentStyle() && generation == languageGeneration.value,
        );
      }
      if (!isCurrentStyle()) {
        return;
      }
      try {
        if (showMarkerPin && controller.value != null) {
          await controller.value?.addMarkerAtLatLng(centre);
        }
      } finally {
        // Calling methods on the controller after it is disposed will throw an error
        // We do not have a way to check if the controller is disposed for now
        // https://github.com/maplibre/flutter-maplibre-gl/issues/192
      }
      if (isCurrentStyle()) {
        styleLoaded.value = true;
      }
    }

    return MapThemeOverride(
      themeMode: themeMode,
      mapBuilder: (style) => AnimatedContainer(
        duration: Durations.medium2,
        curve: Curves.easeOut,
        foregroundDecoration: BoxDecoration(
          color: context.colorScheme.inverseSurface.withAlpha(styleLoaded.value ? 0 : 200),
          borderRadius: const BorderRadius.all(Radius.circular(15)),
        ),
        height: height,
        width: width,
        child: ClipRRect(
          borderRadius: const BorderRadius.all(Radius.circular(15)),
          child: Stack(
            alignment: AlignmentGeometry.topCenter,
            children: [
              style.widgetWhen(
                onData: (style) => MapLibreMap(
                  initialCameraPosition: CameraPosition(target: centre, zoom: zoom),
                  styleString: style,
                  onMapCreated: onMapCreated,
                  onStyleLoadedCallback: onStyleLoaded,
                  onMapClick: onTap,
                  doubleClickZoomEnabled: false,
                  dragEnabled: false,
                  zoomGesturesEnabled: false,
                  tiltGesturesEnabled: false,
                  scrollGesturesEnabled: false,
                  rotateGesturesEnabled: false,
                  myLocationEnabled: false,
                  attributionButtonMargins: showAttribution == false ? const Point(-100, 0) : null,
                ),
              ),
              if (assetMarkerRemoteId != null && assetThumbhash != null)
                Container(
                  width: width,
                  height: height / 2,
                  alignment: Alignment.bottomCenter,
                  child: SizedBox.square(
                    dimension: height / 2.5,
                    child: AssetMarkerIcon(id: assetMarkerRemoteId!, thumbhash: assetThumbhash!),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
