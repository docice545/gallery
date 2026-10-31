import 'dart:convert';
import 'dart:io';

/// Real loopback HTTP server; no production endpoints or credentials.
class RecoveryHttpServer {
  final HttpServer server;
  final requests = <({String method, Uri uri, bool authenticated})>[];
  String mode = 'normal';
  static const photoId = '11111111-1111-4111-8111-111111111111';
  static const otherId = '22222222-2222-4222-8222-222222222222';
  String get endpoint => 'http://127.0.0.1:${server.port}/api';
  RecoveryHttpServer._(this.server) {
    server.listen((request) async {
      requests.add((
        method: request.method,
        uri: request.uri,
        authenticated: request.headers.value('authorization') == 'Bearer synthetic-token-stays-private',
      ));
      final response = request.response;
      if (mode == 'unauthorized') {
        response.statusCode = 401;
      } else if (mode == 'redirect') {
        response.statusCode = 302;
        response.headers.set('location', '$endpoint/forbidden');
      } else if (request.uri.path == '/api/users/me') {
        response.write(
          jsonEncode({'id': mode == 'wrong_owner' ? 'other-owner' : 'existing-owner', 'name': 'Existing owner'}),
        );
      } else if (request.uri.path == '/api/timeline/buckets') {
        response.write(
          jsonEncode([
            {'timeBucket': '2026-10-01', 'count': 2},
          ]),
        );
      } else if (request.uri.path == '/api/timeline/bucket') {
        response.write(
          jsonEncode({
            'id': [photoId, otherId],
            'ownerId': ['existing-owner', 'other-owner'],
            'isImage': [true, true],
          }),
        );
      } else if (request.uri.path == '/api/assets/$photoId/thumbnail') {
        response.headers.contentType = ContentType('image', 'png');
        response.add(
          base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII='),
        );
      } else {
        response.statusCode = 404;
      }
      await response.close();
    });
  }
  static Future<RecoveryHttpServer> start({int port = 0}) async =>
      RecoveryHttpServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, port));
  Future<void> close() => server.close(force: true);
}
