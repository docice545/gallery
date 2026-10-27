import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/widgets/map/map_style_presentation.dart';
import 'package:logging/logging.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:mocktail/mocktail.dart';

class _Controller extends Mock implements MapLibreMapController {}

class _Properties extends Fake implements LayerProperties {}

// Evaluate just the style-spec operations exercised below, using synthetic
// vector-tile properties. This verifies the actual displayed label, not only
// the presence of a name:ru string somewhere in a wrapper.
Object? _evaluate(Object? expression, Map<String, Object?> properties) {
  if (expression is! List) {
    return expression;
  }
  Object? value(int index) => _evaluate(expression[index], properties);
  switch (expression.first) {
    case 'get':
      return properties[expression[1]];
    case 'has':
      return properties.containsKey(expression[1]);
    case '==':
      return value(1) == value(2);
    case '!=':
      return value(1) != value(2);
    case 'case':
      for (var index = 1; index < expression.length - 1; index += 2) {
        if (value(index) == true) {
          return value(index + 1);
        }
      }
      return value(expression.length - 1);
    case 'match':
      for (var index = 2; index < expression.length - 1; index += 2) {
        if (value(1) == expression[index]) {
          return value(index + 1);
        }
      }
      return value(expression.length - 1);
    case 'coalesce':
      for (var index = 1; index < expression.length; index++) {
        final result = value(index);
        if (result != null) {
          return result;
        }
      }
      return null;
    case 'concat':
      return [for (var index = 1; index < expression.length; index++) value(index) ?? ''].join();
    case 'to-string':
      return value(1)?.toString() ?? '';
    case 'upcase':
      return value(1).toString().toUpperCase();
    case 'slice':
      return value(1).toString().substring(expression[2] as int, expression[3] as int);
    case 'format':
      return [for (var index = 1; index < expression.length; index += 2) value(index) ?? ''].join();
    case 'literal':
      return expression[1];
    default:
      throw StateError('Unsupported synthetic fixture expression: $expression');
  }
}

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
    for (final entry in {'positron': 'liberty', 'dark': 'fiord'}.entries) {
      expect(
        MapStylePresentation.colorfulStyle('https://tiles.openfreemap.org/styles/${entry.key}'),
        'https://tiles.openfreemap.org/styles/${entry.value}',
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

  test('preferred name has a string output even when all translations are empty or absent', () {
    final fields = MapStylePresentation.localizedNameLayers(style(), 'ru');
    final preferred = (fields['place']! as List)[1][1];
    for (final properties in <Map<String, Object?>>[
      {},
      {'name:ru': null, 'name_ru': '', 'name': ''},
    ]) {
      expect(_evaluate(preferred, properties), '', reason: 'MapLibre case arms must keep a string output type');
    }
    expect(_evaluate(preferred, {'name:ru': '', 'name_ru': 'Химки', 'name': 'Khimki'}), 'Химки');
    expect(_evaluate(preferred, {'name:ru': '', 'name_ru': '', 'name': 'Химки'}), 'Химки');
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

  Object patch(Object field, [String language = 'ru']) {
    final custom = style();
    (custom['layers'] as List).first['layout']['text-field'] = field;
    return MapStylePresentation.localizedNameLayers(custom, language)['place']!;
  }

  test('provider bilingual labels display one translated name and preserve source fallback', () {
    // OpenFreeMap Liberty/Fiord, pinned style source 006ea5796803ba2df4330888836cb0a8f17473b4.
    for (final separator in [' ', '\n']) {
      final authored = [
        'case',
        ['has', 'name:nonlatin'],
        [
          'concat',
          ['get', 'name:latin'],
          separator,
          ['get', 'name:nonlatin'],
        ],
        [
          'coalesce',
          ['get', 'name_en'],
          ['get', 'name'],
        ],
      ];
      final expression = patch(authored);
      expect(_evaluate(expression, {'name:ru': 'Москва', 'name:latin': 'Moscow', 'name:nonlatin': 'Москва'}), 'Москва');
      expect(_evaluate(expression, {'name:latin': 'Moscow', 'name:nonlatin': 'Москва'}), 'Moscow$separatorМосква');
      expect(_evaluate(expression, {'name:ru': '', 'name': 'Москва', 'name_en': 'Moscow'}), 'Москва');
      expect(_evaluate(expression, {'name_en': 'Moscow'}), 'Moscow');
    }
  });

  test('authored case alternatives and string transformations remain in the output', () {
    final authored = [
      'case',
      ['get', 'isCapital'],
      [
        'upcase',
        ['get', 'name:latin'],
      ],
      ['get', 'name:nonlatin'],
    ];
    expect(_evaluate(patch(authored), {'name:ru': 'Москва', 'isCapital': true}), 'МОСКВА');
    expect(_evaluate(patch(authored), {'name:ru': 'Москва', 'isCapital': false}), 'Москва');
    final transformed = [
      'slice',
      [
        'upcase',
        [
          'concat',
          ['get', 'name:latin'],
          ' ',
          ['get', 'name:nonlatin'],
        ],
      ],
      0,
      3,
    ];
    expect(_evaluate(patch(transformed), {'name:ru': 'Москва'}), 'МОС');
  });

  test('legacy token fields translate names and preserve real route refs in both branches', () {
    final expression = patch('{name:latin} ({ref})');
    expect(_evaluate(expression, {'name:ru': 'Химки', 'name:latin': 'Khimki', 'ref': 'М-11'}), 'Химки (М-11)');
    expect(_evaluate(expression, {'name:latin': 'Khimki', 'ref': 'М-11'}), 'Khimki (М-11)');
    expect(jsonEncode(expression), isNot(contains('{ref}')));
  });

  test('compound expressions preserve ref suffixes and authored branch selectors', () {
    final authored = [
      'case',
      [
        '==',
        ['get', 'name:latin'],
        'Moscow',
      ],
      [
        'concat',
        ['get', 'name:latin'],
        ' / ',
        ['get', 'ref'],
      ],
      [
        'concat',
        ['get', 'name:latin'],
        ' alternate',
      ],
    ];
    final expression = patch(authored);
    expect(_evaluate(expression, {'name:ru': 'Москва', 'name:latin': 'Moscow', 'ref': 'А-1'}), 'Москва / А-1');
    expect((expression as List)[2][1], authored[1]);
  });

  test('format bilingual entries keep primary typography and unrelated ref section', () {
    final primaryOptions = {
      'font-scale': 1.3,
      'text-font': [
        'literal',
        ['Noto Sans Bold'],
      ],
    };
    final secondaryOptions = {'font-scale': 0.8};
    final refOptions = {'font-scale': 0.7};
    final authored = [
      'format',
      ['get', 'name:latin'],
      primaryOptions,
      '\n',
      <String, Object>{},
      ['get', 'name:nonlatin'],
      secondaryOptions,
      ' / ',
      <String, Object>{},
      ['get', 'ref'],
      refOptions,
    ];
    final expression = patch(authored);
    expect(
      _evaluate(expression, {'name:ru': 'Белек', 'name:latin': 'Belek', 'name:nonlatin': 'Belek', 'ref': 'D400'}),
      'Белек / D400',
    );
    final formatted = (expression as List)[2] as List;
    expect(formatted, hasLength(7));
    expect(formatted[2], primaryOptions);
    expect(formatted.last, refOptions);
    expect(expression.last, authored);
  });

  test('nested conditional bilingual output does not repeat the localized name', () {
    final authored = [
      'concat',
      ['get', 'name:latin'],
      [
        'case',
        ['has', 'name:nonlatin'],
        [
          'concat',
          '\n',
          ['get', 'name:nonlatin'],
        ],
        '',
      ],
      ' (',
      ['get', 'ref'],
      ')',
    ];
    expect(
      _evaluate(patch(authored), {
        'name:ru': 'Хотьково',
        'name:latin': "Khot’kovo",
        'name:nonlatin': 'Хотьково',
        'ref': '1',
      }),
      'Хотьково (1)',
    );
  });

  test('optional-first custom bilingual runs retain their authored visible-name fallback', () {
    final authored = [
      'concat',
      [
        'case',
        ['get', 'showLatin'],
        ['get', 'name:latin'],
        '',
      ],
      ' ',
      ['get', 'name:nonlatin'],
      ' / ',
      ['get', 'name'],
    ];
    final expression = patch(authored);
    final properties = {'name:ru': 'Москва', 'name:latin': 'Moscow', 'name:nonlatin': 'Москва', 'name': 'Moscow'};
    expect(_evaluate(expression, {...properties, 'showLatin': false}), ' Москва / Москва');
    expect(_evaluate(expression, {...properties, 'showLatin': true}), 'Moscow Москва / Москва');
  });

  test('literal data, format options and nested-object getters are not rewritten', () {
    final authored = [
      'format',
      ['get', 'name:latin'],
      {
        'text-font': [
          'literal',
          ['name:latin'],
        ],
      },
      ['literal', '{name}'],
      <String, Object>{},
      [
        'get',
        'name',
        ['get', 'metadata'],
      ],
      <String, Object>{},
    ];
    final expression = patch(authored) as List;
    final formatted = expression[2] as List;
    expect(formatted[2], authored[2]);
    expect(formatted[3], authored[3]);
    expect(formatted[5], authored[5]);
  });

  test('formerly patched whole-field expressions are unwrapped before a locale switch', () {
    Object nonEmpty(String key) => [
      'case',
      [
        '==',
        ['get', key],
        '',
      ],
      null,
      ['get', key],
    ];
    final legacy = [
      'coalesce',
      nonEmpty('name:ru'),
      nonEmpty('name_ru'),
      nonEmpty('name'),
      ['get', 'name:latin'],
    ];
    expect(patch(legacy, 'en'), patch(['get', 'name:latin'], 'en'));
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
