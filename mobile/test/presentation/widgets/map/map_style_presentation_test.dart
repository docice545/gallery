import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/widgets/map/map_style_presentation.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:mocktail/mocktail.dart';

class _Controller extends Mock implements MapLibreMapController {}

class _Properties extends Fake implements LayerProperties {}

void main() {
  setUpAll(() => registerFallbackValue(_Properties()));

  Map<String, dynamic> style() => {
    'version': 8,
    'layers': [
      {
        'id': 'place',
        'type': 'symbol',
        'layout': {
          'text-field': ['get', 'name:latin'],
          'text-font': ['Noto Sans Regular'],
        },
      },
      {
        'id': 'country',
        'type': 'symbol',
        'layout': {'text-field': '{name}'},
      },
      {
        'id': 'road-ref',
        'type': 'symbol',
        'layout': {
          'text-field': ['get', 'ref'],
        },
      },
      {
        'id': 'water',
        'type': 'fill',
        'paint': {'fill-color': '#b0d9ff'},
      },
    ],
  };

  test('only monochrome upstream defaults switch to same-provider colour style', () {
    for (final name in ['positron', 'dark']) {
      expect(
        MapStylePresentation.colorfulStyle('https://tiles.openfreemap.org/styles/$name'),
        'https://tiles.openfreemap.org/styles/liberty',
      );
    }
    for (final custom in [
      'https://maps.example.test/positron.json',
      'https://tiles.openfreemap.org/styles/bright',
      '{"version":8}',
    ]) {
      expect(MapStylePresentation.colorfulStyle(custom), custom);
    }
  });

  test('Russian labels prefer source translations and retain native/original fallback', () {
    final fields = MapStylePresentation.localizedNameLayers(style(), 'ru-RU');
    expect(fields.keys, ['place', 'country']);
    final encoded = jsonEncode(fields['place']);
    expect(encoded, contains('name:ru'));
    expect(encoded, contains('name_ru'));
    expect(encoded, contains('"name"'));
    expect((fields['place']! as List).last, ['get', 'name:latin']);
    expect(fields, isNot(contains('road-ref')));
    // No country/city substitution table or transliteration is applied.
    expect(MapStylePresentation.localizedNameLayers({'layers': []}, 'ru'), isEmpty);
  });

  test('native language patch preserves all fonts, colours and collision properties', () async {
    final controller = _Controller();
    when(controller.getStyle).thenAnswer((_) async => jsonEncode(style()));
    when(() => controller.setLayerProperties(any(), any())).thenAnswer((_) async {});
    await MapStylePresentation.applyLanguage(controller, 'ru');
    final properties =
        verify(() => controller.setLayerProperties('place', captureAny())).captured.single as LayerProperties;
    expect(properties.toJson(skipNulls: false).keys, ['text-field']);
    verify(() => controller.setLayerProperties('country', any())).called(1);
    verifyNever(() => controller.setLayerProperties('road-ref', any()));
  });

  test('unmounted map stops locale updates before platform layer calls', () async {
    final controller = _Controller();
    when(controller.getStyle).thenAnswer((_) async => jsonEncode(style()));
    await MapStylePresentation.applyLanguage(controller, 'ru', isCurrent: () => false);
    verifyNever(() => controller.setLayerProperties(any(), any()));
  });
}
