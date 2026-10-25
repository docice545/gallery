import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/map/map.widget.dart';
import 'package:immich_mobile/presentation/widgets/map/map_settings_sheet.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

@RoutePage()
class MapPage extends StatelessWidget {
  final LatLng? initialLocation;

  const MapPage({super.key, this.initialLocation});

  Future<void> onSettingsPressed(BuildContext context) {
    return showModalBottomSheet(
      elevation: 0.0,
      showDragHandle: true,
      isScrollControlled: true,
      context: context,
      builder: (_) => const MapSettingsSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          MapView(initialLocation: initialLocation),
          Positioned(
            left: 12 + MediaQuery.paddingOf(context).left,
            top: 12 + MediaQuery.paddingOf(context).top,
            child: IconButton.filled(
              color: context.themeData.colorScheme.onPrimaryContainer,
              onPressed: () => ContextHelper(context).pop(),
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
              style: IconButton.styleFrom(
                minimumSize: const Size.square(48),
                padding: const EdgeInsets.all(12),
                backgroundColor: context.themeData.colorScheme.primaryContainer,
                shadowColor: Colors.black26,
                elevation: 2,
              ),
            ),
          ),
          Positioned(
            right: 12 + MediaQuery.paddingOf(context).right,
            top: 12 + MediaQuery.paddingOf(context).top,
            child: IconButton.filled(
              color: context.themeData.colorScheme.onPrimaryContainer,
              onPressed: () => onSettingsPressed(context),
              tooltip: context.t.settings,
              icon: const Icon(Icons.more_vert_rounded, size: 20),
              style: IconButton.styleFrom(
                minimumSize: const Size.square(48),
                padding: const EdgeInsets.all(12),
                backgroundColor: context.themeData.colorScheme.primaryContainer,
                shadowColor: Colors.black26,
                elevation: 2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
