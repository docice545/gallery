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
    this.isCurrentSession,
    this.onRetryInitialization,
    DateTime Function()? now,
    this.maxCacheEntries = 256,
    this.requestInterval = const Duration(milliseconds: 500),
  }) : _now = now ?? DateTime.now;

  static const _channel = MethodChannel('de.opennoodle.gallery/place_names');
  static final _logger = Logger('PlaceNameService');
  static const _positiveLifetime = Duration(days: 30);
  static const _negativeLifetime = Duration(hours: 1);
  static const _transientLifetime = Duration(seconds: 15);
  // Version 3 also trusts the native candidate policy, not only the label's
  // spelling. Earlier positive results may have belonged to a nearby city.
  static const _cacheVersion = 3;
  static final _controls = RegExp(r'[\x00-\x1f\x7f-\x9f]');
  static final _cyrillic = RegExp(r'[А-Яа-яЁё]');

  final Future<String> Function() namespace;
  final Future<String?> Function() readCache;
  final Future<void> Function(String value) writeCache;
  final PlaceNameLookup lookup;
  final bool Function()? isCurrentSession;
  final void Function()? onRetryInitialization;
  final DateTime Function() _now;
  final int maxCacheEntries;
  final Duration requestInterval;
  final _cache = <String, ({String? label, DateTime expiresAt, bool persist})>{};
  final _pending = <String, ({Completer<String> completer, String source, List<bool Function()> wanted})>{};
  Future<void>? _initialization;
  Future<void>? _readiness;
  Future<void> _queue = Future.value();
  final _retired = Completer<void>();
  String _scope = '';
  DateTime? _lastRequestAt;
  bool _disposed = false;

  bool get _active => !_disposed && (isCurrentSession?.call() ?? true);

  static String normalizeLanguageTag(String languageTag) {
    final parts = languageTag.trim().replaceAll('_', '-').split('-');
    return [
      for (var i = 0; i < parts.length; i++)
        if (i == 0)
          parts[i].toLowerCase()
        else if (parts[i].length == 4)
          '${parts[i][0].toUpperCase()}${parts[i].substring(1).toLowerCase()}'
        else if (parts[i].length == 2 || parts[i].length == 3)
          parts[i].toUpperCase()
        else
          parts[i].toLowerCase(),
    ].join('-');
  }

  static String key(Place place, String languageTag) => jsonEncode([
    normalizeLanguageTag(languageTag),
    place.name,
    place.state,
    place.country,
    place.latitude?.toString(),
    place.longitude?.toString(),
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
    await _ready();
    if (!_active) {
      return const {};
    }
    return {
      for (final entry in _cache.entries)
        if (entry.value.label != null && entry.value.expiresAt.isAfter(_now())) entry.key: entry.value.label!,
    };
  }

  Future<void> _ready() => _readiness ??= Future.any([_initialization ??= _initialize(), _retired.future]);

  Future<void> _initialize() async {
    try {
      if (!_active) {
        return;
      }
      final scope = await namespace();
      if (!_active || scope.isEmpty) {
        return;
      }
      _scope = scope;
      final serialized = await readCache();
      if (!_active || serialized == null) {
        return;
      }
      final decoded = jsonDecode(serialized);
      if (decoded is! Map ||
          decoded['version'] != _cacheVersion ||
          decoded['scope'] != _scope ||
          decoded['entries'] is! List) {
        return;
      }
      for (final entry in decoded['entries'] as List) {
        if (entry is! Map || entry['key'] is! String || entry['expiresAt'] is! int) {
          continue;
        }
        final cacheKey = entry['key'] as String;
        final language = _keyLanguage(cacheKey);
        if (language == null) {
          continue;
        }
        final label = entry['label'];
        if (label != null && label is! String) {
          continue;
        }
        final validated = _validatedLabel(label as String?, language);
        if (label != null && validated == null) {
          continue;
        }
        final expiry = DateTime.fromMillisecondsSinceEpoch(entry['expiresAt'] as int);
        if (expiry.isAfter(_now())) {
          _cache[cacheKey] = (label: validated, expiresAt: expiry, persist: true);
        }
      }
      _trimCache();
    } on FormatException {
      _logger.warning('Invalid localized-place cache; source names remain available');
    } catch (_) {
      _logger.warning('Localized-place cache unavailable; source names remain available');
    }
  }

  Future<String> resolve(Place place, String languageTag, {required bool Function() isWanted}) async {
    final source = place.name.trim();
    final language = normalizeLanguageTag(languageTag);
    if (!_active || !place.hasCoordinates || source.isEmpty) {
      return source;
    }
    // A Russian source label already is authoritative. Do not spend a network
    // geocoder request just to obtain another spelling of the same name.
    if (language.split('-').first == 'ru' && _cyrillic.hasMatch(source)) {
      return source;
    }
    await _ready();
    if (!_active || _scope.isEmpty) {
      return source;
    }
    final cacheKey = key(place, language);
    final cached = _cache.remove(cacheKey);
    if (cached != null && cached.expiresAt.isAfter(_now())) {
      _cache[cacheKey] = cached;
      return cached.label ?? source;
    }
    final existing = _pending[cacheKey];
    if (existing != null) {
      existing.wanted.add(isWanted);
      return existing.completer.future;
    }
    // A fast fling can dispose many rows before a slow OS request returns.
    // Bound queued work as well as persisted labels; source names stay usable.
    if (_pending.length >= maxCacheEntries) {
      return source;
    }

    final completer = Completer<String>();
    final interested = [isWanted];
    _pending[cacheKey] = (completer: completer, source: source, wanted: interested);
    void complete(String value) {
      if (!completer.isCompleted) {
        completer.complete(value);
      }
    }

    _queue = _queue.then((_) async {
      try {
        if (!_active || !interested.any((wanted) => wanted())) {
          complete(source);
          return;
        }
        final previous = _lastRequestAt;
        if (previous != null) {
          final remaining = requestInterval - _now().difference(previous);
          if (remaining > Duration.zero) {
            await Future<void>.delayed(remaining);
          }
        }
        if (!_active || !interested.any((wanted) => wanted())) {
          complete(source);
          return;
        }
        _lastRequestAt = _now();
        String? label;
        var persistFailure = true;
        try {
          label = _validatedLabel(await lookup(place, language).timeout(const Duration(seconds: 5)), language);
        } on MissingPluginException {
          _logger.info('Localized place names are unavailable on this platform');
        } on PlatformException catch (error) {
          // Native codes are diagnostics. Never print the geocoder query,
          // coordinates or platform exception message containing user data.
          persistFailure = error.code == 'GEOCODER_UNAVAILABLE' || error.code == 'GEOCODER_NO_MATCH';
          _logger.warning(
            'Localized place lookup failed (${error.code}); '
            '${persistFailure ? 'source fallback' : 'transient retry permitted'}',
          );
        } on TimeoutException {
          persistFailure = false;
          _logger.warning('Localized place lookup timed out');
        } on Exception {
          persistFailure = false;
          _logger.warning('Localized place lookup failed; retaining the source name');
        }
        if (!_active) {
          complete(source);
          return;
        }
        final lifetime = label != null
            ? _positiveLifetime
            : persistFailure
            ? _negativeLifetime
            : _transientLifetime;
        _cache[cacheKey] = (label: label, expiresAt: _now().add(lifetime), persist: label != null || persistFailure);
        _trimCache();
        await _persist();
        complete(_active ? label ?? source : source);
      } catch (error, stack) {
        _logger.severe('Unexpected localized-place queue failure (${error.runtimeType})', null, stack);
        complete(source);
      } finally {
        _pending.remove(cacheKey);
      }
    });
    return completer.future;
  }

  /// Explicit foreground retry. It does not mutate place/asset metadata or
  /// clear successful translations; no background polling is introduced.
  Future<void> retryFailures() async {
    if (!_active) {
      return;
    }
    if (_scope.isEmpty) {
      onRetryInitialization?.call();
      _initialization = null;
      _readiness = null;
    }
    await _ready();
    if (!_active) {
      return;
    }
    _cache.removeWhere((_, entry) => entry.label == null);
    await _persist();
  }

  void _trimCache() {
    while (_cache.length > maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  /// Retire this owner/endpoint session. Android cannot cancel an already
  /// submitted Geocoder request, but its result must not reach another session.
  void dispose() {
    _disposed = true;
    if (!_retired.isCompleted) {
      _retired.complete();
    }
    _cache.clear();
    for (final request in _pending.values) {
      if (!request.completer.isCompleted) {
        request.completer.complete(request.source);
      }
    }
  }

  static String? _validatedLabel(String? value, String languageTag) {
    if (value == null || _controls.hasMatch(value)) {
      return null;
    }
    final label = value.trim();
    if (label.isEmpty || label.length > 200 || (languageTag.split('-').first == 'ru' && !_cyrillic.hasMatch(label))) {
      return null;
    }
    return label;
  }

  static String? _keyLanguage(String key) {
    try {
      final fields = jsonDecode(key);
      if (fields is! List ||
          fields.length != 6 ||
          fields[0] is! String ||
          fields[1] is! String ||
          fields.skip(2).any((value) => value != null && value is! String)) {
        return null;
      }
      final language = fields[0] as String;
      if (language.isEmpty || normalizeLanguageTag(language) != language || _controls.hasMatch(language)) {
        return null;
      }
      return language;
    } on FormatException {
      return null;
    }
  }

  Future<void> _persist() async {
    if (!_active || _scope.isEmpty) {
      return;
    }
    try {
      await writeCache(
        jsonEncode({
          'version': _cacheVersion,
          'scope': _scope,
          'entries': [
            for (final entry in _cache.entries)
              if (entry.value.persist)
                {
                  'key': entry.key,
                  'label': entry.value.label,
                  'expiresAt': entry.value.expiresAt.millisecondsSinceEpoch,
                },
          ],
        }),
      );
    } on Exception {
      _logger.warning('Could not persist localized-place cache; source names remain available');
    }
  }
}
