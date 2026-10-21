import 'package:crop_image/crop_image.dart';
import 'package:flutter/material.dart';
import 'package:immich_mobile/constants/filters.dart';
import 'package:immich_mobile/presentation/pages/edit/editor.provider.dart';
import 'package:immich_mobile/presentation/pages/edit/editor_mode.dart';
import 'package:immich_mobile/utils/color_adjustment.dart';

/// A widget that builds a CropImage with adjustments and filters applied.
/// Used to avoid duplicating the filter logic across multiple editor components.
class FilteredImage extends StatelessWidget {
  const FilteredImage({
    super.key,
    required this.editorState,
    required this.image,
    required this.cropController,
    required this.mode,
  });

  final EditorState editorState;
  final Image image;
  final CropController cropController;
  final EditorMode mode;

  @override
  Widget build(BuildContext context) {
    // Build color filter from adjustments using shared utility
    ColorFilter? colorFilter = ColorAdjustment.buildFilter(editorState.adjustments);
    
    // Apply selected filter with proper intensity blending
    if (editorState.selectedFilterIndex > 0 && editorState.selectedFilterIndex < filters.length) {
      final filter = applyFilterIntensity(editorState.selectedFilterIndex, editorState.filterIntensity);
      colorFilter = colorFilter == null 
          ? filter 
          : ColorFilter.compose(filter, colorFilter);
    }
    
    final child = CropImage(
      key: ObjectKey(image.image),
      controller: cropController,
      image: image,
      gridColor: mode == EditorMode.crop ? Colors.white : Colors.transparent,
      gridInnerColor: mode == EditorMode.crop ? Colors.white : Colors.transparent,
      gridCornerColor: mode == EditorMode.crop ? Colors.white : Colors.transparent,
      showCorners: mode == EditorMode.crop,
      scrimColor: mode == EditorMode.crop ? Colors.black54 : Colors.transparent,
    );
    
    if (colorFilter != null) {
      return ColorFiltered(
        colorFilter: colorFilter,
        child: child,
      );
    }
    return child;
  }
}
