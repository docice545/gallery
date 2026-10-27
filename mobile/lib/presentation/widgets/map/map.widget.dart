import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:geolocator/geolocator.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/models/map.model.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/extensions/asyncvalue_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/map_bottom_sheet.widget.dart';
import 'package:immich_mobile/presentation/widgets/map/map.state.dart';
import 'package:immich_mobile/presentation/widgets/map/map_my_location_button.widget.dart';
import 'package:immich_mobile/presentation/widgets/map/map_photo_selection.dart';
import 'package:immich_mobile/presentation/widgets/map/map_utils.dart';
import 'package:immich_mobile/presentation/widgets/map/map_viewport.dart';
import 'package:immich_mobile/providers/infrastructure/map.provider.dart';
import 'package:immich_mobile/providers/routes.provider.dart';
import 'package:immich_mobile/providers/sync_status.provider.dart';
import 'package:immich_mobile/utils/async_mutex.dart';
import 'package:immich_mobile/utils/debounce.dart';
import 'package:immich_mobile/widgets/common/immich_toast.dart';
import 'package:immich_mobile/widgets/map/map_style_presentation.dart';
import 'package:immich_mobile/widgets/map/map_theme_override.dart';
import 'package:logging/logging.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

class MapView extends ConsumerStatefulWidget {
  final LatLng? initialLocation;

  const MapView({super.key, this.initialLocation});

  @override
  ConsumerState<MapView> createState() => _MapViewState();
}

class _MapViewState extends ConsumerState<MapView> {
  MapLibreMapController? mapController;
  final _reloadMutex = AsyncMutex();
  final _debouncer = Debouncer(interval: const Duration(milliseconds: 500), maxWaitTime: const Duration(seconds: 2));
  final ValueNotifier<double> bottomSheetOffset = ValueNotifier(0);
  final _sheetController = DraggableScrollableController();
  final _log = Logger('PhotoMapView');
  int _styleGeneration = 0;
  int _languageGeneration = 0;
  int _selectionGeneration = 0;
  bool _styleReady = false;
  bool _initialCameraApplied = false;
  bool _userInteracted = false;
  bool _initialCameraAvailable = false;
  CameraPosition? _initialCamera;
  bool _selecting = false;
  String? _languageCode;
  final GlobalKey _bottomSheetKey = GlobalKey();
  StreamSubscription? _eventSubscription;

  @override
  void initState() {
    super.initState();
    _eventSubscription = EventStream.shared.listen<MapMarkerReloadEvent>(_onEvent);
    ref.listenManual<int>(syncStatusProvider.select((state) => state.remoteContentChangedCount), (previous, next) {
      if (previous != null && next != previous) {
        _debouncer.run(() => setBounds(forceReload: true));
      }
    });
  }

  @override
  void dispose() {
    _debouncer.dispose();
    _styleGeneration++;
    _languageGeneration++;
    _selectionGeneration++;
    mapController?.removeListener(onMapMoved);
    mapController?.onFeatureTapped.remove(onFeatureTapped);
    _sheetController.dispose();
    bottomSheetOffset.dispose();
    unawaited(_eventSubscription?.cancel());
    super.dispose();
  }

  void onMapCreated(MapLibreMapController controller) {
    mapController?.removeListener(onMapMoved);
    mapController?.onFeatureTapped.remove(onFeatureTapped);
    _styleGeneration++;
    _languageGeneration++;
    _selectionGeneration++;
    _styleReady = false;
    _selecting = false;
    mapController = controller;
    controller.addListener(onMapMoved);
    controller.onFeatureTapped.add(onFeatureTapped);
  }

  void _onEvent(_) => _debouncer.run(() => setBounds(forceReload: true));

  void _prepareInitialCamera(CameraPosition camera, bool hasCoordinates) {
    _initialCamera = camera;
    _initialCameraAvailable = hasCoordinates;
    // A library may acquire its first geotags after the map is already open.
    // Fit that first real extent, but never replace an intentional user camera.
    if (_styleReady && !_initialCameraApplied && !_userInteracted && hasCoordinates) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final controller = mapController;
        if (mounted && _styleReady && controller != null) {
          unawaited(_applyInitialCamera(controller));
        }
      });
    }
  }

  Future<void> _applyInitialCamera(MapLibreMapController controller) async {
    if (_initialCameraApplied || _userInteracted || !_initialCameraAvailable || _initialCamera == null) {
      return;
    }
    _initialCameraApplied = true;
    try {
      await controller.moveCamera(CameraUpdate.newCameraPosition(_initialCamera!));
    } catch (error, stack) {
      if (mounted && identical(controller, mapController)) {
        _initialCameraApplied = false;
        _log.warning('Cannot fit initial photo map viewport', error, stack);
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final language = Localizations.localeOf(context).languageCode;
    if (_languageCode != null && _languageCode != language && _styleReady) {
      final controller = mapController;
      if (controller != null) {
        final generation = ++_languageGeneration;
        final styleGeneration = _styleGeneration;
        unawaited(
          MapStylePresentation.applyLanguage(
            controller,
            language,
            isCurrent: () =>
                mounted && _styleReady && generation == _languageGeneration && styleGeneration == _styleGeneration,
          ),
        );
      }
    }
    _languageCode = language;
  }

  Future<void> onMapReady() async {
    final controller = mapController;
    if (controller == null || !mounted) {
      return;
    }
    final generation = ++_styleGeneration;
    _styleReady = false;
    bool current() => mounted && generation == _styleGeneration && identical(controller, mapController);
    try {
      await _applyInitialCamera(controller);
      if (!current()) {
        return;
      }
      await controller.addSource(MapUtils.defaultSourceId, MapUtils.photoSource);
      if (!current()) {
        return;
      }
      await controller.addCircleLayer(
        MapUtils.defaultSourceId,
        MapUtils.clusterLayerId,
        MapUtils.photoCircleProperties,
      );
      if (!current()) {
        return;
      }
      await controller.addSymbolLayer(MapUtils.defaultSourceId, MapUtils.countLayerId, MapUtils.photoCountProperties);
      if (!current()) {
        return;
      }
      _styleReady = true;
      final languageGeneration = ++_languageGeneration;
      await MapStylePresentation.applyLanguage(
        controller,
        _languageCode ?? 'en',
        isCurrent: () => current() && languageGeneration == _languageGeneration,
      );
      if (current()) {
        _debouncer.run(() => setBounds(forceReload: true));
      }
    } catch (error, stack) {
      if (current()) {
        _log.warning('Cannot initialize photo map layers', error, stack);
      }
    }
  }

  void onMapMoved() {
    final controller = mapController;
    if (!mounted || controller == null || controller.isCameraMoving || _selecting || !_styleReady) {
      return;
    }
    _debouncer.run(setBounds);
  }

  void onFeatureTapped(Point<double> point, LatLng coordinates, String id, String layerId, Annotation? annotation) {
    if (layerId != MapUtils.clusterLayerId && layerId != MapUtils.countLayerId) {
      return;
    }
    unawaited(_selectPhotos(point, coordinates));
  }

  Future<void> _selectPhotos(Point<double> point, LatLng coordinates) async {
    final controller = mapController;
    if (controller == null || !_styleReady || !mounted || controller.isCameraMoving) {
      return;
    }
    final generation = ++_selectionGeneration;
    final styleGeneration = _styleGeneration;
    bool current() => mounted && generation == _selectionGeneration && styleGeneration == _styleGeneration;
    _selecting = true;
    try {
      final selection = await MapPhotoSelection.fromTap(controller, point, isCurrent: current);
      if (!current() || selection == null || controller.isCameraMoving) {
        return;
      }
      _debouncer.dispose();
      final completed = await controller.animateCamera(
        CameraUpdate.newLatLngZoom(coordinates, selection.zoom),
        duration: const Duration(milliseconds: 300),
      );
      if (!current() || completed == false) {
        return;
      }
      ref.read(mapStateProvider.notifier).setBounds(selection.bounds);
      if (_sheetController.isAttached) {
        await _sheetController.animateTo(0.65, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    } catch (error, stack) {
      if (current()) {
        _log.warning('Cannot select photos from map marker', error, stack);
      }
    } finally {
      if (generation == _selectionGeneration) {
        _selecting = false;
      }
    }
  }

  Future<void> setBounds({bool forceReload = false}) async {
    final controller = mapController;
    if (controller == null || !mounted || !_styleReady || _selecting) {
      return;
    }

    // When the AssetViewer is open, the MapView route stays alive in the background.
    // If we continue to update bounds, the map-scoped timeline service gets recreated and the previous one disposed,
    // which can invalidate the TimelineService instance that was passed into AssetViewerRoute (causing "loading forever").
    if (ref.read(isAssetViewerOpenProvider)) {
      return;
    }

    final generation = _styleGeneration;
    final selectionGeneration = _selectionGeneration;
    try {
      final bounds = await controller.getVisibleRegion();
      await _reloadMutex.run(() async {
        if (mounted &&
            _styleReady &&
            generation == _styleGeneration &&
            selectionGeneration == _selectionGeneration &&
            !_selecting &&
            (ref.read(mapStateProvider.notifier).setBounds(bounds) || forceReload)) {
          if (forceReload) {
            ref.invalidate(mapMarkerProvider(bounds));
          }
          try {
            final markers = await ref.read(mapMarkerProvider(bounds).future);
            if (mounted && generation == _styleGeneration && selectionGeneration == _selectionGeneration) {
              await reloadMarkers(markers);
            }
          } catch (error, stack) {
            if (mounted && generation == _styleGeneration) {
              _log.warning('Cannot refresh photo map markers', error, stack);
            }
          }
        }
      });
    } catch (error, stack) {
      if (mounted && generation == _styleGeneration) {
        _log.warning('Cannot read photo map viewport', error, stack);
      }
    }
  }

  Future<void> reloadMarkers(Map<String, dynamic> markers) async {
    final controller = mapController;
    if (controller == null || !mounted || !_styleReady) {
      return;
    }

    await controller.setGeoJsonSource(MapUtils.defaultSourceId, markers);
  }

  Future<void> onZoomToLocation() async {
    final (location, error) = await MapUtils.checkPermAndGetLocation(context: context);
    if (error != null) {
      if (error == LocationPermission.unableToDetermine && context.mounted) {
        ImmichToast.show(
          context: context,
          gravity: ToastGravity.BOTTOM,
          toastType: ToastType.error,
          msg: context.t.map_cannot_get_user_location,
        );
      }
      return;
    }

    final controller = mapController;
    if (mounted && _styleReady && controller != null && location != null) {
      await controller.animateCamera(
        CameraUpdate.newLatLngZoom(LatLng(location.latitude, location.longitude), MapUtils.mapZoomToAssetLevel),
        duration: const Duration(milliseconds: 800),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(isAssetViewerOpenProvider, (previous, current) {
      if (previous == true && !current) {
        _debouncer.run(() => setBounds(forceReload: true));
      }
    });
    return Stack(
      children: [
        _Map(
          initialLocation: widget.initialLocation,
          onMapCreated: onMapCreated,
          onMapReady: onMapReady,
          onCameraPrepared: _prepareInitialCamera,
          onInteraction: () => _userInteracted = true,
        ),
        _DynamicBottomSheet(
          bottomSheetOffset: bottomSheetOffset,
          sheetKey: _bottomSheetKey,
          controller: _sheetController,
        ),
        MapMyLocationButton(onZoomToLocation: onZoomToLocation, bottomSheetOffset: bottomSheetOffset),
      ],
    );
  }
}

class _Map extends ConsumerWidget {
  final LatLng? initialLocation;

  const _Map({
    this.initialLocation,
    required this.onMapCreated,
    required this.onMapReady,
    required this.onCameraPrepared,
    required this.onInteraction,
  });

  final MapCreatedCallback onMapCreated;

  final VoidCallback onMapReady;
  final void Function(CameraPosition, bool) onCameraPrepared;
  final VoidCallback onInteraction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final viewport = initialLocation == null
        ? ref.watch(initialMapViewportProvider)
        : const AsyncData<MapViewport?>(null);
    if (viewport.isLoading && !viewport.hasValue) {
      return const Center(child: CircularProgressIndicator());
    }
    if (viewport.hasError && !viewport.hasValue) {
      return Center(
        child: IconButton(
          tooltip: context.t.retry,
          onPressed: () => ref.invalidate(initialMapViewportProvider),
          icon: const Icon(Icons.refresh),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final camera = initialLocation != null
            ? CameraPosition(target: initialLocation!, zoom: MapUtils.mapZoomToAssetLevel)
            : MapViewportCamera.cameraForViewport(
                viewport.valueOrNull,
                size: constraints.biggest,
                padding: EdgeInsets.fromLTRB(
                  24,
                  kToolbarHeight + MediaQuery.paddingOf(context).top + 24,
                  24,
                  120 + MediaQuery.paddingOf(context).bottom,
                ),
              );
        onCameraPrepared(camera, initialLocation != null || viewport.valueOrNull != null);
        return MapThemeOverride(
          mapBuilder: (style) => style.widgetWhen(
            onData: (style) => Listener(
              onPointerDown: (_) => onInteraction(),
              child: MapLibreMap(
                initialCameraPosition: camera,
                trackCameraPosition: true,
                compassEnabled: false,
                rotateGesturesEnabled: false,
                styleString: style,
                onMapCreated: onMapCreated,
                onStyleLoadedCallback: onMapReady,
                attributionButtonPosition: AttributionButtonPosition.topRight,
                attributionButtonMargins: const Point(8, kToolbarHeight),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DynamicBottomSheet extends StatefulWidget {
  final ValueNotifier<double> bottomSheetOffset;
  final GlobalKey sheetKey;
  final DraggableScrollableController controller;

  const _DynamicBottomSheet({required this.bottomSheetOffset, required this.sheetKey, required this.controller});

  @override
  State<_DynamicBottomSheet> createState() => _DynamicBottomSheetState();
}

class _DynamicBottomSheetState extends State<_DynamicBottomSheet> {
  @override
  Widget build(BuildContext context) {
    return NotificationListener<DraggableScrollableNotification>(
      onNotification: (notification) {
        final sheet = notification.context.findAncestorWidgetOfExactType<MapBottomSheet>();
        if (sheet?.sheetKey == widget.sheetKey) {
          widget.bottomSheetOffset.value = notification.extent;
        }
        return false;
      },
      child: MapBottomSheet(sheetKey: widget.sheetKey, controller: widget.controller),
    );
  }
}
