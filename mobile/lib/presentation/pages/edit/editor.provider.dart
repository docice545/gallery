import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/aspect_ratios.dart';
import 'package:immich_mobile/constants/filters.dart';
import 'package:immich_mobile/domain/models/annotation.model.dart';
import 'package:immich_mobile/domain/models/asset_edit.model.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/utils/color_adjustment.dart';
import 'package:immich_mobile/utils/editor.utils.dart';

part 'editor.provider.freezed.dart';

final editorStateProvider = NotifierProvider<EditorProvider, EditorState>(EditorProvider.new);

/// One bounded document history across geometry, color and markup. A slider or
/// crop gesture commits one step, rather than retaining a snapshot per frame.
class EditorProvider extends Notifier<EditorState> {
  EditorState _baseline = const EditorState();
  final List<EditorState> _undo = [];
  final List<EditorState> _redo = [];
  EditorState? _gestureStart;
  bool _legacyAnnotationsDirty = false;
  static const historyLimit = 100;

  @override
  EditorState build() => const EditorState();

  void clear() {
    _undo.clear();
    _redo.clear();
    _gestureStart = null;
    _legacyAnnotationsDirty = false;
    _baseline = const EditorState();
    state = _baseline;
  }

  void init(List<AssetEdit> edits, ExifInfo exifInfo) {
    clear();
    final crop = edits.whereType<CropEdit>().firstOrNull;
    final width = exifInfo.isFlipped ? exifInfo.height : exifInfo.width;
    final height = exifInfo.isFlipped ? exifInfo.width : exifInfo.height;
    final transform = normalizeTransformEdits(edits);
    // Adjustments/markup are baked into a new copy, never invented as unsupported
    // AssetEdit API fields. Existing server crop/rotation metadata stays intact.
    _baseline = EditorState(
      originalWidth: width ?? 0,
      originalHeight: height ?? 0,
      crop: crop != null && width != null && height != null
          ? convertCropParametersToRect(crop.parameters, width, height)
          : const Rect.fromLTRB(0, 0, 1, 1),
      rotationAngle: transform.rotation,
      flipHorizontal: transform.mirrorHorizontal,
      flipVertical: transform.mirrorVertical,
    );
    state = _baseline;
  }

  bool _sameDocument(EditorState a, EditorState b) =>
      a.crop == b.crop &&
      a.rotationAngle % 360 == b.rotationAngle % 360 &&
      a.flipHorizontal == b.flipHorizontal &&
      a.flipVertical == b.flipVertical &&
      a.aspectRatio == b.aspectRatio &&
      mapEquals(a.adjustments, b.adjustments) &&
      a.selectedFilterIndex == b.selectedFilterIndex &&
      a.filterIntensity == b.filterIntensity &&
      listEquals(a.annotations, b.annotations);

  bool _dirty(EditorState value) =>
      !_sameDocument(
        value.copyWith(
          selectedFilterIndex: value.filterIntensity == 0 ? 0 : value.selectedFilterIndex,
          filterIntensity: value.selectedFilterIndex == 0 || value.filterIntensity == 0 ? 1 : value.filterIntensity,
        ),
        _baseline,
      ) ||
      _legacyAnnotationsDirty;

  void _publish(EditorState next) {
    state = next.copyWith(hasUnsavedEdits: _dirty(next), canUndo: _undo.isNotEmpty, canRedo: _redo.isNotEmpty);
  }

  void _remember(EditorState value) {
    _undo.add(value);
    if (_undo.length > historyLimit) {
      _undo.removeAt(0);
    }
    _redo.clear();
  }

  void _commit(EditorState next) {
    if (state.isApplyingEdits || _sameDocument(state, next)) {
      return;
    }
    if (_gestureStart == null) {
      _remember(state);
    }
    _publish(next);
  }

  void beginGesture() {
    if (!state.isApplyingEdits) {
      _gestureStart ??= state;
    }
  }

  void endGesture() {
    final start = _gestureStart;
    _gestureStart = null;
    if (start != null && !_sameDocument(start, state)) {
      _remember(start);
      _publish(state);
    }
  }

  void undo() {
    endGesture();
    if (_undo.isEmpty || state.isApplyingEdits) {
      return;
    }
    _redo.add(state);
    _publish(_undo.removeLast().copyWith(isApplyingEdits: false, animationDuration: Duration.zero));
  }

  void redo() {
    if (_redo.isEmpty || state.isApplyingEdits) {
      return;
    }
    _undo.add(state);
    _publish(_redo.removeLast().copyWith(isApplyingEdits: false, animationDuration: Duration.zero));
  }

  void normalizeRotation() {
    state = state.copyWith(rotationAngle: state.rotationAngle % 360, animationDuration: Duration.zero);
  }

  void setIsEditing(bool applying) {
    endGesture();
    state = state.copyWith(isApplyingEdits: applying);
  }

  // Kept for existing callers; the editor uses the full immutable document below.
  void setAnnotationsEdited(bool dirty) {
    _legacyAnnotationsDirty = dirty;
    _publish(state);
  }

  void setAnnotations(List<AnnotationElement> elements) =>
      _commit(state.copyWith(annotations: List.unmodifiable(elements)));

  void setCrop(Rect crop) {
    if (![crop.left, crop.top, crop.right, crop.bottom].every((v) => v.isFinite) ||
        crop.isEmpty ||
        crop.left < 0 ||
        crop.top < 0 ||
        crop.right > 1 ||
        crop.bottom > 1) {
      throw ArgumentError.value(crop, 'crop');
    }
    _commit(state.copyWith(crop: crop));
  }

  double _shiftIntoBounds(double start, double end) => start < 0 ? -start : (end > 1 ? 1 - end : 0);

  void setAspectRatio(CropAspectRatio preset) {
    if (preset == state.aspectRatio) {
      return;
    }
    final ownGesture = _gestureStart == null;
    beginGesture();
    try {
      final square = Rect.fromCenter(
        center: state.crop.center,
        width: state.crop.longestSide,
        height: state.crop.longestSide,
      );
      _commit(
        state.copyWith(
          aspectRatio: preset,
          crop: square.shift(
            Offset(_shiftIntoBounds(square.left, square.right), _shiftIntoBounds(square.top, square.bottom)),
          ),
        ),
      );
    } finally {
      if (ownGesture) {
        endGesture();
      }
    }
  }

  void resetEdits() {
    endGesture();
    _legacyAnnotationsDirty = false;
    _commit(_baseline);
  }

  void rotateCCW() => _rotate(-90);
  void rotateCW() => _rotate(90);
  void _rotate(int angle) => _commit(
    state.copyWith(
      rotationAngle: state.rotationAngle + angle,
      aspectRatio: state.aspectRatio.flipped,
      animationDuration: const Duration(milliseconds: 300),
    ),
  );

  void flipHorizontally() => state.rotationAngle % 180 != 0
      ? _commit(state.copyWith(flipVertical: !state.flipVertical))
      : _commit(state.copyWith(flipHorizontal: !state.flipHorizontal));

  void flipVertically() => state.rotationAngle % 180 != 0
      ? _commit(state.copyWith(flipHorizontal: !state.flipHorizontal))
      : _commit(state.copyWith(flipVertical: !state.flipVertical));

  void setAdjustment(String key, double value) {
    if (!ColorAdjustment.keys.contains(key) || !value.isFinite) {
      throw ArgumentError.value(value, key);
    }
    final adjustments = Map<String, double>.from(state.adjustments);
    final clamped = value.clamp(-1.0, 1.0);
    if (clamped == 0) {
      adjustments.remove(key);
    } else {
      adjustments[key] = clamped;
    }
    _commit(state.copyWith(adjustments: adjustments));
  }

  void setFilter(int index, {double intensity = 1}) {
    if (!intensity.isFinite) {
      throw ArgumentError.value(intensity, 'intensity');
    }
    _commit(
      state.copyWith(
        selectedFilterIndex: index.clamp(0, filters.length - 1),
        filterIntensity: intensity.clamp(0.0, 1.0),
      ),
    );
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
    @Default([]) List<AnnotationElement> annotations,
    @Default(false) bool canUndo,
    @Default(false) bool canRedo,
  }) = _EditorState;
  bool get hasEdits => hasUnsavedEdits;
}
