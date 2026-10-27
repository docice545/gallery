import 'package:crop_image/crop_image.dart';
import 'package:flutter/material.dart';
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
    this.showCropHandles = true,
  });

  final EditorState editorState;
  final Image image;
  final CropController cropController;
  final EditorMode mode;
  final bool showCropHandles;

  @override
  Widget build(BuildContext context) {
    final colorFilter = ColorAdjustment.combinedFilter(
      editorState.adjustments,
      editorState.selectedFilterIndex,
      editorState.filterIntensity,
    );
    final child = CropImage(
      key: ObjectKey(image.image),
      controller: cropController,
      image: image,
      gridColor: showCropHandles && mode == EditorMode.crop ? Colors.white : Colors.transparent,
      gridInnerColor: showCropHandles && mode == EditorMode.crop ? Colors.white : Colors.transparent,
      gridCornerColor: showCropHandles && mode == EditorMode.crop ? Colors.white : Colors.transparent,
      showCorners: showCropHandles && mode == EditorMode.crop,
      scrimColor: showCropHandles && mode == EditorMode.crop ? Colors.black54 : Colors.transparent,
    );

    return ColorFiltered(colorFilter: colorFilter, child: child);
  }
}
