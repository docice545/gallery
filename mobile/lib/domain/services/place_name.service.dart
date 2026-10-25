import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/models/place.model.dart';
import 'package:logging/logging.dart';

typedef PlaceNameLookup = Future<String?> Function(Place place, String languageTag);

/// Optional display-name enrichment. Never changes the source city, asset
/// membership, coordinates or EXIF. Only mounted rows request names. The queue
/// is serial and skips rows that were disposed before their turn.
class PlaceNameService {
  PlaceNameService({
    required this.namespace,
    required this.readCache,
    required this.writeCache,
    this.lookup = nativeLookup,
    DateTime Function()? now,
    this.maxCacheEntries = 256,
    this.requestInterval = const Duration(milliseconds: 500),
  }) : _now = now ?? DateTime.now;

  static const _channel = MethodChannel('de.opennoodle.gallery/place_names');
  static final _logger = Logger('PlaceNameService');
  static const _positiveLifetime = Duration(days: 30);
  static const _negativeLifetime = Duration(hours: 1);

  final Future<String> Function() namespace;
  final Future<String?> Function() readCache;
  final Future<void> Function(String value) writeCache;
  final PlaceNameLookup lookup;
  final DateTime Function() _now;
  final int maxCacheEntries;
  final Duration requestInterval;
  final _cache = <String, ({String? label, DateTime expiresAt})>{};
  final _pending = <String, ({Future<String> result, List<bool Function()> wanted})>{};
  Future<void>? _initialization;
  Future<void> _queue = Future.value();
  String _scope = '';
  DateTime? _lastRequestAt;

  static String key(Place place, String languageTag) => jsonEncode([
    languageTag,
    place.name,
    place.state,
    place.country,
    place.latitude?.toStringAsFixed(3),
    place.longitude?.toStringAsFixed(3),
  ]);

  static Future<String?> nativeLookup(Place place, String languageTag) =>
      _channel.invokeMethod<String>('localizePlace', {
        'city': place.name,
        'state': place.state,
        'country': place.country,
        'latitude': place.latitude,
        'longitude': place.longitude,
        'languageTag': languageTag,
      });

  Future<Map<String, String>> cachedLabels() async {
    await (_initialization ??= _initialize());
    return {
      for (final entry in _cache.entries)
        if (entry.value.label != null && entry.value.expiresAt.isAfter(_now())) entry.key: entry.value.label!,
    };
  }

  Future<void> _initialize() async {
    try {
      _scope = await namespace();
      final serialized = await readCache();
      if (serialized == null) {
        return;
      }
      final decoded = jsonDecode(serialized);
      if (decoded is! Map || decoded['version'] != 1 || decoded['scope'] != _scope || decoded['entries'] is! List) {
        return;
      }
      for (final entry in decoded['entries'] as List) {
        if (entry is! Map || entry['key'] is! String || entry['expiresAt'] is! int) {
          continue;
        }
        final label = entry['label'];
        if (label != null && label is! String) {
          continue;
        }
        final expiry = DateTime.fromMillisecondsSinceEpoch(entry['expiresAt'] as int);
        if (expiry.isAfter(_now())) {
          _cache[entry['key'] as String] = (label: label as String?, expiresAt: expiry);
        }
      }
      _trimCache();
    } on FormatException {
      _logger.warning('Invalid localized-place cache; source names remain available');
    } on Exception {
      _logger.warning('Localized-place cache unavailable; source names remain available');
    }
  }

  Future<String> resolve(Place place, String languageTag, {required bool Function() isWanted}) async {
    final source = place.name.trim();
    if (!place.hasCoordinates || source.isEmpty) {
      return source;
    }
    // A Russian source label already is authoritative. Do not spend a network
    // geocoder request just to obtain another spelling of the same name.
    if (languageTag.toLowerCase().startsWith('ru') && RegExp(r'[А-Яа-яЁё]').hasMatch(source)) {
      return source;
    }
    await (_initialization ??= _initialize());
    final cacheKey = key(place, languageTag);
    final cached = _cache.remove(cacheKey);
    if (cached != null && cached.expiresAt.isAfter(_now())) {
      _cache[cacheKey] = cached;
      return cached.label ?? source;
    }
    final existing = _pending[cacheKey];
    if (existing != null) {
      existing.wanted.add(isWanted);
      return existing.result;
    }
    // A fast fling can dispose many rows before a slow OS request returns.
    // Bound queued work as well as persisted labels; source names stay usable.
    if (_pending.length >= maxCacheEntries) {
      return source;
    }

    final completer = Completer<String>();
    final interested = [isWanted];
    _pending[cacheKey] = (result: completer.future, wanted: interested);
    _queue = _queue.then((_) async {
      try {
        if (!interested.any((wanted) => wanted())) {
          completer.complete(source);
          return;
        }
        final previous = _lastRequestAt;
        if (previous != null) {
          final remaining = requestInterval - _now().difference(previous);
          if (remaining > Duration.zero) {
            await Future<void>.delayed(remaining);
          }
        }
        if (!interested.any((wanted) => wanted())) {
          completer.complete(source);
          return;
        }
        _lastRequestAt = _now();
        String? label;
        try {
          label = (await lookup(place, languageTag).timeout(const Duration(seconds: 5)))?.trim();
          if (label != null &&
              (label.isEmpty ||
                  label.length > 200 ||
                  label.contains('\n') ||
                  (languageTag.toLowerCase().startsWith('ru') && !RegExp(r'[А-Яа-яЁё]').hasMatch(label)))) {
            // Some Android geocoder implementations ignore the requested
            // locale. Retain the original source spelling in that case.
            label = null;
          }
        } on MissingPluginException {
          _logger.info('Localized place names are unavailable on this platform');
        } on PlatformException catch (error) {
          // Native codes are diagnostics. Never print the geocoder query,
          // coordinates or platform exception message containing user data.
          _logger.warning('Localized place lookup failed (${error.code})');
        } on TimeoutException {
          _logger.warning('Localized place lookup timed out');
        } on Exception {
          _logger.warning('Localized place lookup failed; retaining the source name');
        }
        _cache[cacheKey] = (label: label, expiresAt: _now().add(label == null ? _negativeLifetime : _positiveLifetime));
        _trimCache();
        await _persist();
        completer.complete(label ?? source);
      } catch (error, stack) {
        _logger.severe('Unexpected localized-place queue failure (${error.runtimeType})', null, stack);
        if (!completer.isCompleted) {
          completer.complete(source);
        }
      } finally {
        _pending.remove(cacheKey);
      }
    });
    return completer.future;
  }

  void _trimCache() {
    while (_cache.length > maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  Future<void> _persist() async {
    if (_scope.isEmpty) {
      return;
    }
    try {
      await writeCache(
        jsonEncode({
          'version': 1,
          'scope': _scope,
          'entries': [
            for (final entry in _cache.entries)
              {'key': entry.key, 'label': entry.value.label, 'expiresAt': entry.value.expiresAt.millisecondsSinceEpoch},
          ],
        }),
      );
    } on Exception {
      _logger.warning('Could not persist localized-place cache; source names remain available');
    }
  }
}
