import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/map_bottom_sheet.widget.dart';

/// Keeps the location control above the measured map panel, including on the
/// first frame, in landscape and after a text scale or safe-area change.
class MapMyLocationButton extends StatelessWidget {
  const MapMyLocationButton({super.key, required this.onZoomToLocation, required this.bottomSheetOffset});

  final VoidCallback onZoomToLocation;
  final ValueNotifier<double> bottomSheetOffset;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => Stack(
        fit: StackFit.expand,
        children: [
          ValueListenableBuilder<double>(
            valueListenable: bottomSheetOffset,
            builder: (context, offset, child) {
              final collapsedHeight = MapBottomSheet.collapsedPanelHeight(
                context,
                availableHeight: constraints.maxHeight,
              );
              final panelHeight = math.max(constraints.maxHeight * offset, collapsedHeight);
              return Positioned(
                right: 12 + context.padding.right,
                bottom: panelHeight + 8,
                child: IgnorePointer(
                  ignoring: offset >= 0.8,
                  child: AnimatedOpacity(
                    opacity: offset < 0.8 ? 1 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: SizedBox.square(
                      dimension: 48,
                      child: IconButton.filledTonal(
                        key: const Key('map-my-location-button'),
                        tooltip: context.t.map_location_picker_page_use_location,
                        onPressed: onZoomToLocation,
                        icon: const Icon(Icons.my_location, size: 22),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
