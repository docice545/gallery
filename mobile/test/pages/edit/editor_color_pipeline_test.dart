import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/filters.dart';
import 'package:immich_mobile/utils/color_adjustment.dart';
import 'package:immich_mobile/utils/edited_image_exporter.dart';

Future<ui.Image> _source() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 16, 16), Paint()..color = const Color(0xff6080a0));
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(16, 16);
  } finally {
    picture.dispose();
  }
}

Future<List<int>> _pixel(ui.Image image) async {
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  return List.generate(4, (i) => bytes.getUint8((8 * image.width + 8) * 4 + i));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('catalog contains original plus 32 effects and validates out-of-range access', () {
    expect(filterMatrices, hasLength(33));
    expect(filters, hasLength(filterNames.length));
    expect(filterMatrixAtIntensity(32, 1), filterMatrices.last);
    expect(filterMatrixAtIntensity(-1, 1), identityMatrix);
    expect(filterMatrixAtIntensity(33, 1), identityMatrix);
    expect(() => filterMatrixAtIntensity(1, double.nan), throwsArgumentError);
  });

  for (final key in ColorAdjustment.keys) {
    test('renders a visible $key correction and preserves original pixels', () async {
      final source = await _source();
      final result = await EditedImageExporter.render(
        source: source,
        crop: const Rect.fromLTWH(0, 0, 1, 1),
        rotationDegrees: 0,
        flipHorizontal: false,
        flipVertical: false,
        annotations: [],
        adjustments: {key: .5},
      );
      try {
        expect(await _pixel(result), isNot([96, 128, 160, 255]));
        expect(await _pixel(source), [96, 128, 160, 255]);
      } finally {
        result.dispose();
        source.dispose();
      }
    });
  }

  for (var index = 1; index < filterMatrices.length; index++) {
    testWidgets('preview and exported pixels agree for filter $index at partial intensity', (tester) async {
      const adjustments = {'brightness': -.05, 'contrast': .2, 'saturation': -.3, 'hue': .1};
      final source = await tester.runAsync(_source);
      ui.Image? preview;
      ui.Image? output;
      final key = GlobalKey();
      try {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: RepaintBoundary(
                key: key,
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: ColorFiltered(
                    colorFilter: ColorAdjustment.combinedFilter(adjustments, index, .45),
                    child: RawImage(image: source),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        preview = await tester.runAsync(
          () => (key.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage(),
        );
        output = await tester.runAsync(
          () => EditedImageExporter.render(
            source: source!,
            crop: const Rect.fromLTWH(0, 0, 1, 1),
            rotationDegrees: 0,
            flipHorizontal: false,
            flipVertical: false,
            annotations: [],
            adjustments: adjustments,
            selectedFilterIndex: index,
            filterIntensity: .45,
          ),
        );
        final a = await tester.runAsync(() => _pixel(preview!));
        final b = await tester.runAsync(() => _pixel(output!));
        for (var channel = 0; channel < 4; channel++) {
          expect(a![channel], closeTo(b![channel], 1));
        }
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        source?.dispose();
        preview?.dispose();
        output?.dispose();
      }
    });
  }
}
