import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:immich_mobile/data/db/sqlite_one_tap_recovery.dart';
import 'package:immich_mobile/data/db/sqlite_recovery_server.dart';

final class RecoveryServerPhoto {
  final String id;
  final bool isImage;
  const RecoveryServerPhoto(this.id, this.isImage);
}

/// Deliberately separate from ApiService, Store, sync, download queues, caching
/// and the application router. Only four existing GET routes are reachable.
final class RecoveryServerClient {
  final RecoveryServerCredentials _credentials;
  final http.Client _client;
  final Set<String> _visible = {};
  bool _authorized = false;
  bool _closed = false;
  String accountName = '';
  RecoveryServerClient(this._credentials, {http.Client? client})
    : _client = client ?? IOClient(HttpClient()..connectionTimeout = const Duration(seconds: 20));

  Uri _uri(String route, Map<String, String> query) {
    final base = _credentials.endpoint;
    final path = '${base.path.replaceFirst(RegExp(r'/+$'), '')}/$route';
    return base.replace(path: path, queryParameters: query.isEmpty ? null : query);
  }

  Future<Uint8List> _get(String route, {Map<String, String> query = const {}, int maxBytes = 16 * 1024 * 1024}) async {
    if (_closed) {
      throw const RecoveryRefused('server_view_closed');
    }
    // Never follow a redirect with a saved bearer token, or call a write route.
    if (!(route == 'users/me' ||
        route == 'timeline/buckets' ||
        route == 'timeline/bucket' ||
        RegExp(r'^assets/[0-9a-fA-F-]{36}/thumbnail$').hasMatch(route))) {
      throw const RecoveryRefused('server_response_invalid');
    }
    try {
      final request = http.Request('GET', _uri(route, query))
        ..followRedirects = false
        ..headers['Authorization'] = 'Bearer ${_credentials.token}';
      final response = await _client.send(request).timeout(const Duration(seconds: 25));
      if (response.statusCode != 200) {
        await response.stream.listen((_) {}).cancel();
        throw RecoveryRefused(
          [401, 403].contains(response.statusCode) ? 'server_auth_failed' : 'server_network_unavailable',
        );
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream.timeout(const Duration(seconds: 25))) {
        if (bytes.length + chunk.length > maxBytes) {
          throw const RecoveryRefused('server_response_invalid');
        }
        bytes.add(chunk);
      }
      return bytes.takeBytes();
    } on RecoveryRefused {
      rethrow;
    } catch (_) {
      // Socket/HTTP exceptions can contain the private endpoint; expose no raw text.
      throw const RecoveryRefused('server_network_unavailable');
    }
  }

  Future<Object?> _json(String route, {Map<String, String> query = const {}}) async {
    try {
      return jsonDecode(utf8.decode(await _get(route, query: query)));
    } on RecoveryRefused {
      rethrow;
    } catch (_) {
      throw const RecoveryRefused('server_response_invalid');
    }
  }

  Map<String, String> get _scope => {
    'userId': _credentials.ownerId,
    'isTrashed': 'false',
    'visibility': 'timeline',
    'withPartners': 'false',
    'bucketSize': 'month',
    'order': 'desc',
  };

  Future<List<String>> buckets() async {
    await account();
    final value = await _json('timeline/buckets', query: _scope);
    if (value is! List || value.any((v) => v is! Map || v['timeBucket'] is! String)) {
      throw const RecoveryRefused('server_response_invalid');
    }
    return [for (final item in value) item['timeBucket'] as String];
  }

  /// Fresh-start may transfer a saved session only after this owner check.
  Future<Map<String, dynamic>> account() async {
    _authorized = false;
    final user = await _json('users/me');
    if (user is! Map<String, dynamic> || user['id'] != _credentials.ownerId) {
      throw const RecoveryRefused('server_owner_mismatch');
    }
    accountName = user['name'] is String ? user['name'] as String : '';
    _authorized = true;
    return user;
  }

  Future<List<RecoveryServerPhoto>> photos(String bucket) async {
    if (!_authorized) {
      throw const RecoveryRefused('server_auth_failed');
    }
    final value = await _json('timeline/bucket', query: {..._scope, 'timeBucket': bucket});
    if (value is! Map ||
        value['id'] is! List ||
        value['ownerId'] is! List ||
        value['isImage'] is! List ||
        (value['id'] as List).length != (value['ownerId'] as List).length ||
        (value['id'] as List).length != (value['isImage'] as List).length) {
      throw const RecoveryRefused('server_response_invalid');
    }
    final photos = <RecoveryServerPhoto>[];
    for (var i = 0; i < (value['id'] as List).length; i++) {
      final id = value['id'][i];
      if (value['ownerId'][i] != _credentials.ownerId) {
        continue;
      }
      if (id is! String ||
          !RegExp(r'^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$').hasMatch(id) ||
          value['isImage'][i] is! bool) {
        throw const RecoveryRefused('server_response_invalid');
      }
      _visible.add(id);
      photos.add(RecoveryServerPhoto(id, value['isImage'][i] as bool));
    }
    return photos;
  }

  Future<Uint8List> image(RecoveryServerPhoto photo, {bool preview = false}) async {
    if (!_authorized || !_visible.contains(photo.id)) {
      throw const RecoveryRefused('server_owner_mismatch');
    }
    return _get(
      'assets/${photo.id}/thumbnail',
      query: {'size': preview ? 'preview' : 'thumbnail'},
      maxBytes: 32 * 1024 * 1024,
    );
  }

  void close() {
    _closed = true;
    _authorized = false;
    _visible.clear();
    _client.close();
  }
}
