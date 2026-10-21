import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset_edit.model.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/presentation/pages/edit/editor.provider.dart';
import 'package:immich_mobile/utils/editor.utils.dart';
import 'package:openapi/api.dart' show MirrorAxis, MirrorParameters, RotateParameters;

void main() {
  group('EditorProvider', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer();
    });

    tearDown(() {
      container.dispose();
    });

    test('initial state has default values', () {
      final state = container.read(editorStateProvider);
      expect(state.rotationAngle, 0);
      expect(state.flipHorizontal, false);
      expect(state.flipVertical, false);
      expect(state.crop, const Rect.fromLTRB(0, 0, 1, 1));
      expect(state.adjustments, isEmpty);
      expect(state.selectedFilterIndex, 0);
      expect(state.filterIntensity, 1.0);
      expect(state.hasUnsavedEdits, false);
    });

    test('setAdjustment adds adjustment to state', () {
      container.read(editorStateProvider.notifier).setAdjustment('brightness', 0.5);
      
      final state = container.read(editorStateProvider);
      expect(state.adjustments['brightness'], 0.5);
      expect(state.hasUnsavedEdits, true);
    });

    test('setAdjustment clamps value to [-1, 1]', () {
      container.read(editorStateProvider.notifier).setAdjustment('contrast', 2.0);
      
      final state = container.read(editorStateProvider);
      expect(state.adjustments['contrast'], 1.0);
    });

    test('setAdjustment removes key when value is 0', () {
      container.read(editorStateProvider.notifier).setAdjustment('saturation', 0.5);
      container.read(editorStateProvider.notifier).setAdjustment('saturation', 0.0);
      
      final state = container.read(editorStateProvider);
      expect(state.adjustments.containsKey('saturation'), false);
    });

    test('setFilter updates filter index and intensity', () {
      container.read(editorStateProvider.notifier).setFilter(5, intensity: 0.7);
      
      final state = container.read(editorStateProvider);
      expect(state.selectedFilterIndex, 5);
      expect(state.filterIntensity, 0.7);
      expect(state.hasUnsavedEdits, true);
    });

    test('setFilter clamps index to valid range', () {
      container.read(editorStateProvider.notifier).setFilter(100);
      
      final state = container.read(editorStateProvider);
      expect(state.selectedFilterIndex, 31); // Max filter index
    });

    test('setFilter clamps intensity to [0, 1]', () {
      container.read(editorStateProvider.notifier).setFilter(1, intensity: 1.5);
      
      final state = container.read(editorStateProvider);
      expect(state.filterIntensity, 1.0);
    });

    test('resetEdits resets adjustments and filter', () {
      container.read(editorStateProvider.notifier).setAdjustment('brightness', 0.5);
      container.read(editorStateProvider.notifier).setFilter(3, intensity: 0.5);
      container.read(editorStateProvider.notifier).resetEdits();
      
      final state = container.read(editorStateProvider);
      expect(state.adjustments, isEmpty);
      expect(state.selectedFilterIndex, 0);
      expect(state.filterIntensity, 1.0);
    });

    test('hasUnsavedEdits reflects adjustment changes', () {
      expect(container.read(editorStateProvider).hasUnsavedEdits, false);
      
      container.read(editorStateProvider.notifier).setAdjustment('brightness', 0.1);
      expect(container.read(editorStateProvider).hasUnsavedEdits, true);
      
      container.read(editorStateProvider.notifier).setAdjustment('brightness', 0.0);
      expect(container.read(editorStateProvider).hasUnsavedEdits, false);
    });

    test('hasUnsavedEdits reflects filter changes', () {
      expect(container.read(editorStateProvider).hasUnsavedEdits, false);
      
      container.read(editorStateProvider.notifier).setFilter(1);
      expect(container.read(editorStateProvider).hasUnsavedEdits, true);
      
      container.read(editorStateProvider.notifier).setFilter(0);
      expect(container.read(editorStateProvider).hasUnsavedEdits, false);
    });

    test('init loads baseline adjustments from edits', () {
      // Create mock edits with crop and rotation
      final edits = <AssetEdit>[
        CropEdit(CropParameters(x: 100, y: 100, width: 800, height: 600)),
        RotateEdit(RotateParameters(angle: 90)),
      ];
      
      final exif = ExifInfo(
        width: 1000,
        height: 800,
        isFlipped: false,
      );
      
      container.read(editorStateProvider.notifier).init(edits, exif);
      
      final state = container.read(editorStateProvider);
      expect(state.rotationAngle, 90);
      expect(state.originalWidth, 1000);
      expect(state.originalHeight, 800);
    });
  });
}
