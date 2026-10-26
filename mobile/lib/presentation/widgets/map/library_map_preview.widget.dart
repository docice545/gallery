import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/place_names.provider.dart';
import 'package:immich_mobile/widgets/map/map_thumbnail.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

/// Library and Places share the same real-photo anchor. Wait for the initial
/// read before constructing the native map: initialCameraPosition is not a
/// reactive property. A library without GPS uses the neutral world viewport.
class LibraryMapPreview extends ConsumerWidget {
  const LibraryMapPreview({super.key, this.initialLocation, this.onTap});

  final LatLng? initialLocation;
  final ValueChanged<LatLng?>? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = initialLocation == null ? ref.watch(libraryMapLocationProvider) : AsyncData(initialLocation);
    return location.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => IconButton(
        tooltip: context.t.retry,
        onPressed: () => ref.invalidate(libraryMapLocationProvider),
        icon: const Icon(Icons.refresh),
      ),
      data: (centre) => MapThumbnail(
        onTap: onTap == null ? null : (_, _) => onTap!(centre),
        zoom: centre == null ? 0 : 8,
        centre: centre ?? const LatLng(0, 0),
        showAttribution: false,
        themeMode: context.isDarkTheme ? ThemeMode.dark : ThemeMode.light,
      ),
    );
  }
}
