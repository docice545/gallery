import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

/// Presentation changes only: the configured tile source, coordinates and native
/// MapLibre HTTP/disk cache remain responsible for map data.
class MapStylePresentation {
  const MapStylePresentation._();

  /// The upstream defaults are deliberately monochrome. Use the same public,
  /// key-free provider's full-colour style, while respecting custom map servers.
  static String colorfulStyle(String style) {
    final uri = Uri.tryParse(style);
    if (uri?.scheme == 'https' &&
        uri?.host == 'tiles.openfreemap.org' &&
        {'/styles/positron', '/styles/dark'}.contains(uri?.path)) {
      // Fiord is the provider's full-colour dark style; Liberty is light.
      return uri!.replace(path: uri.path == '/styles/dark' ? '/styles/fiord' : '/styles/liberty').toString();
    }
    return style;
  }

  static bool _isNameProperty(Object? value) => value is String && RegExp(r'^name(?::.+|_.+)?$').hasMatch(value);

  static Object _nonEmptyName(String property) => [
    'case',
    [
      '==',
      ['get', property],
      '',
    ],
    null,
    ['get', property],
  ];

  // text-field expressions must have a consistent string output type. A case
  // returning null first makes MapLibre infer null and reject its string arm.
  static Object _nameValue(String property) => [
    'to-string',
    [
      'coalesce',
      ['get', property],
      '',
    ],
  ];

  static Object _preferredName(String language) => [
    'case',
    for (final property in ['name:$language', 'name_$language', 'name']) ...[
      ['!=', _nameValue(property), ''],
      _nameValue(property),
    ],
    '',
  ];

  static bool _same(Object? left, Object? right) => jsonEncode(left) == jsonEncode(right);

  // Native getStyle() includes earlier patches. Recognize only our exact
  // wrapper, including its rewritten output, before changing language again.
  static Object _authoredNameField(Object field) {
    var original = field;
    while (original is List) {
      final List wrapper = original;
      if (wrapper.length == 4 && wrapper.first == 'case') {
        final condition = wrapper[1];
        if (condition is List && condition.length == 3 && condition.first == '!=' && condition.last == '') {
          for (final language in _wrapperLanguages(condition[1])) {
            final preferred = _preferredName(language);
            final authored = wrapper.last;
            if (authored != null &&
                _same(condition[1], preferred) &&
                _same(wrapper[2], _rewriteNames(authored, preferred))) {
              original = authored;
              break;
            }
          }
          if (!identical(original, wrapper)) {
            // There is normally one wrapper. Continue for styles patched by
            // an earlier application version as well.
            continue;
          }
        }
      }
      // Compatibility with the former whole-label coalesce wrapper.
      if (wrapper.length == 5 && wrapper.first == 'coalesce') {
        final candidate = wrapper[1];
        final language = _nonEmptyNameLanguage(candidate);
        if (language != null &&
            _same(wrapper[2], _nonEmptyName('name_$language')) &&
            _same(wrapper[3], _nonEmptyName('name')) &&
            wrapper.last != null) {
          original = wrapper.last as Object;
          continue;
        }
      }
      break;
    }
    return original;
  }

  static String? _nonEmptyNameLanguage(Object? candidate) {
    if (candidate is! List || candidate.length != 4) {
      return null;
    }
    final get = candidate.last;
    if (get is! List || get.length != 2 || get.first != 'get' || get.last is! String) {
      return null;
    }
    final property = get.last as String;
    if (!RegExp(r'^name:[a-z]{2,3}$').hasMatch(property) || !_same(candidate, _nonEmptyName(property))) {
      return null;
    }
    return property.substring('name:'.length);
  }

  static Iterable<String> _wrapperLanguages(Object? preferred) sync* {
    if (preferred is! List || preferred.length != 8 || preferred.first != 'case') {
      return;
    }
    final condition = preferred[1];
    if (condition is! List || condition.length != 3 || condition.first != '!=' || condition.last != '') {
      return;
    }
    final value = condition[1];
    if (value is! List || value.length != 2 || value.first != 'to-string') {
      return;
    }
    final coalesce = value.last;
    if (coalesce is! List || coalesce.length != 3 || coalesce.first != 'coalesce' || coalesce.last != '') {
      return;
    }
    final get = coalesce[1];
    if (get is! List || get.length != 2 || get.first != 'get' || get.last is! String) {
      return;
    }
    final property = get.last as String;
    if (RegExp(r'^name:[a-z]{2,3}$').hasMatch(property)) {
      final language = property.substring('name:'.length);
      if (_same(preferred, _preferredName(language))) {
        yield language;
      }
    }
  }

  // Token substitution applies only to the authored legacy string text-field.
  // Once inside an expression, strings are literal. Convert every token,
  // including {ref}, so the expression fallback cannot print raw braces.
  static Object _templateField(Object field) {
    if (field is! String) {
      return field;
    }
    final tokens = RegExp(r'\{([^{}]+)\}').allMatches(field).toList();
    if (tokens.isEmpty) {
      return field;
    }
    final parts = <Object>[];
    var offset = 0;
    for (final token in tokens) {
      if (token.start > offset) {
        parts.add(field.substring(offset, token.start));
      }
      parts.add([
        'to-string',
        ['get', token.group(1)!],
      ]);
      offset = token.end;
    }
    if (offset < field.length) {
      parts.add(field.substring(offset));
    }
    return parts.length == 1 ? parts.single : ['concat', ...parts];
  }

  // A name-only output contains no ref, unit, prefix or other authored data.
  // Recognize both direct and conditional bilingual labels; do not inspect
  // conditions, literal data, nested-object getters or format option maps.
  static Set<String>? _nameScripts(Object? expression) {
    if (expression is String) {
      return expression.trim().isEmpty ? <String>{} : null;
    }
    if (expression is! List || expression.isEmpty) {
      return null;
    }
    if (expression.length == 2 && expression.first == 'get' && _isNameProperty(expression[1])) {
      return {expression[1] as String};
    }
    final outputs = _outputIndexes(expression);
    if (outputs.isEmpty) {
      return null;
    }
    final scripts = <String>{};
    for (final index in outputs) {
      final part = _nameScripts(expression[index]);
      if (part == null) {
        return null;
      }
      scripts.addAll(part);
    }
    return scripts;
  }

  static Iterable<int> _outputIndexes(List expression) sync* {
    switch (expression.first) {
      case 'concat':
      case 'coalesce':
        yield* Iterable.generate(expression.length - 1, (index) => index + 1);
      case 'to-string':
      case 'upcase':
      case 'downcase':
      case 'slice':
        if (expression.length > 1) {
          yield 1;
        }
      case 'case':
        for (var index = 2; index < expression.length - 1; index += 2) {
          yield index;
        }
        yield expression.length - 1;
      case 'match':
        for (var index = 3; index < expression.length - 1; index += 2) {
          yield index;
        }
        yield expression.length - 1;
    }
  }

  static bool _isBilingual(Set<String>? scripts) =>
      scripts != null && scripts.contains('name:latin') && scripts.contains('name:nonlatin');

  // A localized sibling may be dropped only when the first rendered name is
  // guaranteed to be present. Conditional first labels can be empty; preserving
  // that uncommon custom run is safer than erasing its only visible name.
  static bool _guaranteedNameOutput(Object? expression) {
    if (expression is! List || expression.isEmpty) {
      return false;
    }
    if (expression.first == 'get') {
      return expression.length == 2 && _isNameProperty(expression[1]);
    }
    final outputs = _outputIndexes(expression).toList();
    if (outputs.isEmpty) {
      return false;
    }
    switch (expression.first) {
      case 'case':
      case 'match':
        return outputs.every((index) => _guaranteedNameOutput(expression[index]));
      case 'concat':
        return outputs.any((index) => _guaranteedNameOutput(expression[index]));
      case 'coalesce':
      case 'to-string':
      case 'upcase':
      case 'downcase':
        return _guaranteedNameOutput(expression[outputs.first]);
      default:
        return false;
    }
  }

  static Map<int, int> _bilingualRuns(List<Object?> contents) {
    final runs = <int, int>{};
    for (var start = 0; start < contents.length; start++) {
      final first = _nameScripts(contents[start]);
      if (first == null || first.isEmpty) {
        continue;
      }
      final scripts = {...first};
      var lastName = start;
      var end = start + 1;
      for (; end < contents.length; end++) {
        final next = _nameScripts(contents[end]);
        if (next == null) {
          break;
        }
        scripts.addAll(next);
        if (next.isNotEmpty) {
          lastName = end;
        }
      }
      if (lastName > start && _isBilingual(scripts)) {
        runs[start] = lastName;
        start = lastName;
      }
    }
    return runs;
  }

  static Object _rewriteNames(Object field, Object preferred) {
    if (field is! List || field.isEmpty) {
      return field;
    }
    if (field.first == 'get') {
      return field.length == 2 && _isNameProperty(field[1]) ? preferred : field;
    }
    if (field.first == 'literal') {
      return field;
    }
    final result = List<Object?>.from(field);
    if (field.first == 'format' || field.first == 'concat') {
      final formatted = field.first == 'format';
      final stride = formatted ? 2 : 1;
      final contents = <Object?>[for (var index = 1; index < field.length; index += stride) field[index]];
      final runs = _bilingualRuns(contents);
      final output = <Object?>[field.first];
      for (var index = 0; index < contents.length; index++) {
        final last = runs[index];
        final content = contents[index];
        if (last != null && !_guaranteedNameOutput(content)) {
          // Preserve unsupported custom optional-first bilingual output exactly.
          for (var retained = index; retained <= last; retained++) {
            output.add(contents[retained]);
            if (formatted) {
              output.add(field[retained * 2 + 2]);
            }
          }
          index = last;
          continue;
        }
        output.add(content == null ? null : _rewriteNames(content, preferred));
        if (formatted) {
          output.add(field[index * 2 + 2]);
        }
        if (last != null) {
          index = last;
        }
      }
      return output;
    }
    for (final index in _outputIndexes(field)) {
      final value = field[index];
      if (value != null) {
        result[index] = _rewriteNames(value, preferred);
      }
    }
    return result;
  }

  /// Translate only display-name outputs, keeping authored formatting, route
  /// refs and control branches. If the source has no usable translated/native
  /// name, its original expression remains the fallback. Raster labels cannot
  /// be translated because they are baked into tile images.
  static Map<String, Object> localizedNameLayers(Map<String, dynamic> style, String languageCode) {
    final language = languageCode.toLowerCase().split(RegExp('[-_]')).first;
    if (!RegExp(r'^[a-z]{2,3}$').hasMatch(language)) {
      return {};
    }
    final layers = style['layers'];
    if (layers is! List) {
      return {};
    }
    final result = <String, Object>{};
    final preferred = _preferredName(language);
    for (final layer in layers.whereType<Map>()) {
      final layout = layer['layout'];
      final field = layout is Map ? layout['text-field'] : null;
      final id = layer['id'];
      if (layer['type'] != 'symbol' || id is! String || field == null) {
        continue;
      }
      final authored = _templateField(_authoredNameField(field as Object));
      final rewritten = _rewriteNames(authored, preferred);
      if (_same(authored, rewritten)) {
        continue;
      }
      result[id] = [
        'case',
        ['!=', preferred, ''],
        rewritten,
        authored,
      ];
    }
    return result;
  }

  static Future<void> applyLanguage(
    MapLibreMapController controller,
    String languageCode, {
    bool Function()? isCurrent,
  }) async {
    bool current() => isCurrent?.call() ?? true;
    try {
      final rawStyle = await controller.getStyle();
      if (rawStyle == null || !current()) {
        return;
      }
      final style = jsonDecode(rawStyle) as Map<String, dynamic>;
      for (final entry in localizedNameLayers(style, languageCode).entries) {
        if (!current()) {
          return;
        }
        try {
          // Pass only text-field: SymbolLayerProperties would reset every null
          // font/collision/halo property when used with setLayerProperties.
          await controller.setLayerProperties(entry.key, _NameLayerProperties(entry.value));
        } catch (error, stack) {
          if (current()) {
            // Custom styles can contain a layer whose expression is unsupported
            // by this SDK. Diagnose it without preventing other labels updating.
            Logger(
              'MapStylePresentation',
            ).warning('Cannot apply map label locale $languageCode to layer ${entry.key}', error, stack);
          }
        }
      }
    } catch (error, stack) {
      if (current()) {
        Logger('MapStylePresentation').warning('Cannot apply map label locale $languageCode', error, stack);
      }
    }
  }
}

class _NameLayerProperties implements LayerProperties {
  final Object expression;
  const _NameLayerProperties(this.expression);

  @override
  Map<String, dynamic> toJson({bool skipNulls = true}) => {'text-field': expression};
}
