import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/map.model.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/map/map.state.dart';
import 'package:immich_mobile/providers/infrastructure/map.provider.dart';
import 'package:immich_mobile/widgets/map/map_thumbnail.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

/// Library and Places share the same real-photo extent. Wait for the initial
/// read before constructing the native map: initialCameraPosition is not a
/// reactive property. A library without GPS uses the neutral world viewport.
class LibraryMapPreview extends ConsumerWidget {
  const LibraryMapPreview({super.key, this.initialLocation, this.onTap});

  final LatLng? initialLocation;
  final ValueChanged<LatLng?>? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final viewport = initialLocation == null
        ? ref.watch(initialMapViewportProvider)
        : const AsyncData<MapViewport?>(null);
    return viewport.when(
      skipLoadingOnReload: true,
      skipError: true,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => IconButton(
        tooltip: context.t.retry,
        onPressed: () => ref.invalidate(initialMapViewportProvider),
        icon: const Icon(Icons.refresh),
      ),
      data: (extent) {
        final markers = extent == null ? null : ref.watch(mapMarkerProvider(null));
        return Stack(
          children: [
            MapThumbnail(
              // Fill the Places header and the Library card. MapThumbnail's
              // generic 100x100 defaults left most of the preview blank.
              width: double.infinity,
              height: double.infinity,
              // A preview's calculated camera is not an intentional location
              // override: the full map must fit its own, larger viewport.
              onTap: onTap == null ? null : (_, _) => onTap!(initialLocation),
              viewport: extent,
              photoMarkers: markers?.valueOrNull,
              zoom: initialLocation == null ? 0 : 8,
              centre: initialLocation ?? const LatLng(0, 0),
              showAttribution: false,
            ),
            if (viewport.hasError || markers?.hasError == true)
              Positioned(
                right: 0,
                bottom: 0,
                child: IconButton(
                  tooltip: context.t.retry,
                  onPressed: () {
                    ref.invalidate(initialMapViewportProvider);
                    ref.invalidate(mapMarkerProvider(null));
                  },
                  icon: const Icon(Icons.refresh),
                ),
              ),
          ],
        );
      },
    );
  }
}
