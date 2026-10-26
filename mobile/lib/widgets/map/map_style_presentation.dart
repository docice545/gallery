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
      return uri!.replace(path: '/styles/liberty').toString();
    }
    return style;
  }

  static bool _containsName(Object? expression) {
    if (expression is String) {
      return RegExp(r'\{name(?::[^}]+|_[^}]+)?\}').hasMatch(expression);
    }
    if (expression is! List) {
      return false;
    }
    if (expression.length >= 2 && expression.first == 'get' && expression[1] is String) {
      return RegExp(r'^name(?::.+|_.+)?$').hasMatch(expression[1] as String);
    }
    return expression.any(_containsName);
  }

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

  // getStyle() returns the current native style, including our last patch.
  // Strip only our exact wrapper so repeated locale changes retain the authored
  // fallback without nesting a new copy of every previous language expression.
  static Object _authoredNameField(Object field) {
    var original = field;
    while (original is List && original.length == 5 && original.first == 'coalesce') {
      final localized = original[1];
      if (localized is! List || localized.length != 4) {
        break;
      }
      final get = localized.last;
      if (get is! List || get.length != 2 || get.first != 'get' || get.last is! String) {
        break;
      }
      final property = get.last as String;
      if (!RegExp(r'^name:[a-z]{2,3}$').hasMatch(property)) {
        break;
      }
      final language = property.substring('name:'.length);
      if (jsonEncode(localized) != jsonEncode(_nonEmptyName(property)) ||
          jsonEncode(original[2]) != jsonEncode(_nonEmptyName('name_$language')) ||
          jsonEncode(original[3]) != jsonEncode(_nonEmptyName('name')) ||
          original.last == null) {
        break;
      }
      original = original.last as Object;
    }
    return original;
  }

  /// Localize geographic names only; route refs, house numbers and authored
  /// labels keep their original expressions. A missing/empty translation falls
  /// back to the source's native name and then its original label expression.
  /// Raster labels are baked into tiles and cannot be translated by the SDK.
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
    for (final layer in layers.whereType<Map>()) {
      final layout = layer['layout'];
      final field = layout is Map ? layout['text-field'] : null;
      final id = layer['id'];
      if (layer['type'] != 'symbol' || id is! String || !_containsName(field)) {
        continue;
      }
      result[id] = [
        'coalesce',
        _nonEmptyName('name:$language'),
        _nonEmptyName('name_$language'),
        _nonEmptyName('name'),
        _authoredNameField(field as Object),
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
