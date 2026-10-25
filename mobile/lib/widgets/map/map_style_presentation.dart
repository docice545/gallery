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
        [
          'case',
          [
            '==',
            ['get', 'name:$language'],
            '',
          ],
          null,
          ['get', 'name:$language'],
        ],
        [
          'case',
          [
            '==',
            ['get', 'name_$language'],
            '',
          ],
          null,
          ['get', 'name_$language'],
        ],
        [
          'case',
          [
            '==',
            ['get', 'name'],
            '',
          ],
          null,
          ['get', 'name'],
        ],
        field,
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
        // Pass only text-field: SymbolLayerProperties would reset every null
        // font/collision/halo property when used with setLayerProperties.
        await controller.setLayerProperties(entry.key, _NameLayerProperties(entry.value));
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
