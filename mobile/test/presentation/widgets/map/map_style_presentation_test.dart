import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/widgets/map/map_style_presentation.dart';
import 'package:logging/logging.dart';
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
        'layout': <String, Object?>{
          'text-field': ['get', 'name:latin'],
          'text-font': ['Noto Sans Regular'],
        },
      },
      {
        'id': 'country',
        'type': 'symbol',
        'layout': <String, Object?>{'text-field': '{name}'},
      },
      {
        'id': 'road-ref',
        'type': 'symbol',
        'layout': <String, Object?>{
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

  test('repeated locale changes keep one wrapper and the authored fallback', () {
    final original = style();
    final patched = style();
    final originalField = (original['layers'] as List).first['layout']['text-field'];
    for (var index = 0; index < 100; index++) {
      final language = index.isEven ? 'ru' : 'en';
      final fields = MapStylePresentation.localizedNameLayers(patched, language);
      for (final layer in (patched['layers'] as List).whereType<Map>()) {
        if (fields.containsKey(layer['id'])) {
          (layer['layout'] as Map)['text-field'] = fields[layer['id']];
        }
      }
      final field = fields['place']! as List;
      expect(field.last, originalField);
      expect(jsonEncode(field), jsonEncode(MapStylePresentation.localizedNameLayers(original, language)['place']));
    }
  });

  test('authored coalesce expressions are preserved rather than stripped', () {
    final authored = [
      'coalesce',
      ['get', 'name:ru'],
      ['get', 'name'],
    ];
    final custom = style();
    (custom['layers'] as List).first['layout']['text-field'] = authored;
    final field = MapStylePresentation.localizedNameLayers(custom, 'en')['place']! as List;
    expect(field.last, authored);
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

  test('one unsupported layer is diagnosed and does not prevent subsequent labels', () async {
    final controller = _Controller();
    when(controller.getStyle).thenAnswer((_) async => jsonEncode(style()));
    when(() => controller.setLayerProperties(any(), any())).thenAnswer((_) async {});
    final failure = StateError('synthetic unsupported expression');
    when(() => controller.setLayerProperties('place', any())).thenThrow(failure);
    final records = <LogRecord>[];
    final previousLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    addTearDown(() => Logger.root.level = previousLevel);
    final subscription = Logger('MapStylePresentation').onRecord.listen(records.add);
    addTearDown(subscription.cancel);

    await MapStylePresentation.applyLanguage(controller, 'ru');

    verify(() => controller.setLayerProperties('country', any())).called(1);
    expect(records, hasLength(1));
    expect(records.single.message, contains('layer place'));
    expect(records.single.error, same(failure));
  });

  test('superseded locale stops after its in-flight platform call completes', () async {
    final controller = _Controller();
    when(controller.getStyle).thenAnswer((_) async => jsonEncode(style()));
    final entered = Completer<void>();
    final firstLayer = Completer<void>();
    when(() => controller.setLayerProperties('place', any())).thenAnswer((_) {
      entered.complete();
      return firstLayer.future;
    });
    var current = true;
    final pending = MapStylePresentation.applyLanguage(controller, 'ru', isCurrent: () => current);
    await entered.future;
    current = false;
    firstLayer.complete();
    await pending;

    verifyNever(() => controller.setLayerProperties('country', any()));
  });

  test('superseded style is discarded after asynchronous style retrieval', () async {
    final controller = _Controller();
    final styleResult = Completer<String?>();
    when(controller.getStyle).thenAnswer((_) => styleResult.future);
    var current = true;
    final pending = MapStylePresentation.applyLanguage(controller, 'ru', isCurrent: () => current);
    current = false;
    styleResult.complete(jsonEncode(style()));
    await pending;
    verifyNever(() => controller.setLayerProperties(any(), any()));
  });
}
