import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/aspect_ratios.dart';
import 'package:immich_mobile/constants/filters.dart';
import 'package:immich_mobile/domain/models/asset_edit.model.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/utils/color_adjustment.dart';
import 'package:immich_mobile/utils/editor.utils.dart';

part 'editor.provider.freezed.dart';

final editorStateProvider = NotifierProvider<EditorProvider, EditorState>(EditorProvider.new);

class EditorProvider extends Notifier<EditorState> {
  Rect _baselineCrop = const Rect.fromLTRB(0, 0, 1, 1);
  int _baselineRotation = 0;
  bool _baselineFlipHorizontal = false;
  bool _baselineFlipVertical = false;
  CropAspectRatio _baselineAspectRatio = CropAspectRatio.free;
  bool _annotationsDirty = false;
  Map<String, double> _baselineAdjustments = {};

  @override
  EditorState build() {
    return const EditorState();
  }

  void clear() {
    _baselineCrop = const Rect.fromLTRB(0, 0, 1, 1);
    _baselineRotation = 0;
    _baselineFlipHorizontal = false;
    _baselineFlipVertical = false;
    _baselineAspectRatio = CropAspectRatio.free;
    _annotationsDirty = false;
    _baselineAdjustments = {};
    state = const EditorState();
  }

  void init(List<AssetEdit> edits, ExifInfo exifInfo) {
    clear();

    final existingCrop = edits.whereType<CropEdit>().firstOrNull;

    final originalWidth = exifInfo.isFlipped ? exifInfo.height : exifInfo.width;
    final originalHeight = exifInfo.isFlipped ? exifInfo.width : exifInfo.height;

    final Rect crop = existingCrop != null && originalWidth != null && originalHeight != null
        ? convertCropParametersToRect(existingCrop.parameters, originalWidth, originalHeight)
        : const Rect.fromLTRB(0, 0, 1, 1);

    final transform = normalizeTransformEdits(edits);

    _baselineCrop = crop;
    _baselineRotation = transform.rotation;
    _baselineFlipHorizontal = transform.mirrorHorizontal;
    _baselineFlipVertical = transform.mirrorVertical;
    _baselineAspectRatio = CropAspectRatio.free;

    // Initialize baseline adjustments from existing edits if any
    _baselineAdjustments = _extractAdjustments(edits);

    state = state.copyWith(
      originalWidth: originalWidth ?? state.originalWidth,
      originalHeight: originalHeight ?? state.originalHeight,
      crop: crop,
      flipHorizontal: transform.mirrorHorizontal,
      flipVertical: transform.mirrorVertical,
      hasUnsavedEdits: false,
      adjustments: _baselineAdjustments,
    );

    _animateRotation(transform.rotation, duration: Duration.zero);
  }

  Map<String, double> _extractAdjustments(List<AssetEdit> edits) {
    // TODO: Extract adjustments from AssetEdit when supported
    return {};
  }

  void _animateRotation(int angle, {Duration duration = const Duration(milliseconds: 300)}) {
    state = state.copyWith(rotationAngle: angle, animationDuration: duration);
  }

  void normalizeRotation() {
    final normalizedAngle = ((state.rotationAngle % 360) + 360) % 360;
    if (normalizedAngle != state.rotationAngle) {
      state = state.copyWith(rotationAngle: normalizedAngle, animationDuration: Duration.zero);
    }
  }

  void setIsEditing(bool isApplyingEdits) {
    state = state.copyWith(isApplyingEdits: isApplyingEdits);
  }

  void setAnnotationsEdited(bool dirty) {
    _annotationsDirty = dirty;
    _updateDirtyState();
  }

  void setCrop(Rect crop) {
    state = state.copyWith(crop: crop);
    _updateDirtyState();
  }

  /// Returns the required shift that has to be done to fit a segment in a given
  /// constraint
  double _shiftIntoBounds(double start, double end, {double min = 0.0, double max = 1.0}) {
    if (start < min) {
      return min - start;
    }
    if (end > max) {
      return max - end;
    }
    return 0.0;
  }

  void setAspectRatio(CropAspectRatio preset) {
    // Expand the initial selection into a square. We have to keep the longest
    // side the same as before when the user changes the aspect ratio. Otherwise
    // the selection might shrink
    Rect startingSquare = Rect.fromCenter(
      center: state.crop.center,
      width: state.crop.longestSide,
      height: state.crop.longestSide,
    );
    // If one side of the square is outside of the image border after the
    // expansion, move it towards the center of the required amount
    final dx = _shiftIntoBounds(startingSquare.left, startingSquare.right);
    final dy = _shiftIntoBounds(startingSquare.top, startingSquare.bottom);
    startingSquare = startingSquare.shift(Offset(dx, dy));
    state = state.copyWith(aspectRatio: preset, crop: startingSquare);
    _updateDirtyState();
  }

  void resetEdits() {
    _animateRotation(_baselineRotation);

    state = state.copyWith(
      flipHorizontal: _baselineFlipHorizontal,
      flipVertical: _baselineFlipVertical,
      crop: _baselineCrop,
      aspectRatio: _baselineAspectRatio,
      adjustments: _baselineAdjustments,
      selectedFilterIndex: 0,
      filterIntensity: 1.0,
    );
    _updateDirtyState();
  }

  void rotateCCW() {
    _animateRotation(state.rotationAngle - 90);
    state = state.copyWith(aspectRatio: state.aspectRatio.flipped);
    _updateDirtyState();
  }

  void rotateCW() {
    _animateRotation(state.rotationAngle + 90);
    state = state.copyWith(aspectRatio: state.aspectRatio.flipped);
    _updateDirtyState();
  }

  void flipHorizontally() {
    if (state.rotationAngle % 180 != 0) {
      // When rotated 90 or 270 degrees, flipping horizontally is equivalent to flipping vertically
      state = state.copyWith(flipVertical: !state.flipVertical);
    } else {
      state = state.copyWith(flipHorizontal: !state.flipHorizontal);
    }
    _updateDirtyState();
  }

  void flipVertically() {
    if (state.rotationAngle % 180 != 0) {
      // When rotated 90 or 270 degrees, flipping vertically is equivalent to flipping horizontally
      state = state.copyWith(flipHorizontal: !state.flipHorizontal);
    } else {
      state = state.copyWith(flipVertical: !state.flipVertical);
    }
    _updateDirtyState();
  }

  void setAdjustment(String key, double value) {
    if (!ColorAdjustment.keys.contains(key) || !value.isFinite) {
      throw ArgumentError.value(value, key);
    }
    final clampedValue = value.clamp(-1.0, 1.0);
    final adjustments = Map<String, double>.from(state.adjustments);
    if (clampedValue == 0.0) {
      adjustments.remove(key);
    } else {
      adjustments[key] = clampedValue;
    }
    state = state.copyWith(adjustments: adjustments);
    _updateDirtyState();
  }

  void setFilter(int index, {double intensity = 1.0}) {
    state = state.copyWith(
      selectedFilterIndex: index.clamp(0, filters.length - 1),
      filterIntensity: intensity.clamp(0.0, 1.0),
    );
    _updateDirtyState();
  }

  void _updateDirtyState() {
    final transformDirty =
        state.crop != _baselineCrop ||
        state.rotationAngle != _baselineRotation ||
        state.flipHorizontal != _baselineFlipHorizontal ||
        state.flipVertical != _baselineFlipVertical ||
        state.aspectRatio != _baselineAspectRatio;

    final adjustmentsDirty = !_mapsEqual(state.adjustments, _baselineAdjustments);
    final filterDirty = state.selectedFilterIndex != 0 && state.filterIntensity > 0.0;

    state = state.copyWith(hasUnsavedEdits: transformDirty || _annotationsDirty || adjustmentsDirty || filterDirty);
  }

  bool _mapsEqual(Map<String, double> a, Map<String, double> b) {
    if (a.length != b.length) {
      return false;
    }
    for (final key in a.keys) {
      if (!b.containsKey(key) || (a[key]! - b[key]!).abs() > 1e-10) {
        return false;
      }
    }
    return true;
  }
}

@freezed
abstract class EditorState with _$EditorState {
  const EditorState._();

  const factory EditorState({
    @Default(false) bool isApplyingEdits,
    @Default(0) int rotationAngle,
    @Default(false) bool flipHorizontal,
    @Default(false) bool flipVertical,
    @Default(Rect.fromLTRB(0, 0, 1, 1)) Rect crop,
    @Default(CropAspectRatio.free) CropAspectRatio aspectRatio,
    @Default(0) int originalWidth,
    @Default(0) int originalHeight,
    @Default(Duration.zero) Duration animationDuration,
    @Default(false) bool hasUnsavedEdits,
    @Default({}) Map<String, double> adjustments,
    @Default(0) int selectedFilterIndex,
    @Default(1.0) double filterIntensity,
  }) = _EditorState;

  bool get hasEdits {
    return hasUnsavedEdits;
  }
}
