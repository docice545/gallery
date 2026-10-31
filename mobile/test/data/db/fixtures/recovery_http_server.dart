import 'dart:convert';
import 'dart:io';

/// Real loopback HTTP server; no production endpoints or credentials.
class RecoveryHttpServer {
  final HttpServer server;
  final requests = <({String method, Uri uri, bool authenticated})>[];
  String mode = 'normal';
  bool fullFoto = false;
  int fullDownloadResets = 0;
  int syncStreams = 0;
  final acknowledged = <String>[];
  static const photoId = '11111111-1111-4111-8111-111111111111';
  static const otherId = '22222222-2222-4222-8222-222222222222';
  static const albumId = '33333333-3333-4333-8333-333333333333';
  static const stamp = '2026-10-31T00:00:00Z';
  static final profile = <String, Object?>{
    'id': 'existing-owner',
    'name': 'Existing owner',
    'email': 'owner@example.test',
    'profileChangedAt': stamp,
    'avatarColor': 'primary',
    'clusterGroupId': null,
    'createdAt': stamp,
    'deletedAt': null,
    'isAdmin': false,
    'license': null,
    'oauthId': '',
    'profileImagePath': '',
    'hasProfileImage': false,
    'quotaSizeInBytes': null,
    'quotaUsageInBytes': 0,
    'shouldChangePassword': false,
    'status': 'active',
    'storageLabel': null,
    'updatedAt': stamp,
    'pinCode': null,
  };

  static String get libraryStream {
    final events = <String, Map<String, Object?>>{
      'AuthUserV1': profile,
      'UserV1': profile,
      'AssetV2': {
        'id': photoId,
        'ownerId': 'existing-owner',
        'checksum': base64Encode(List.filled(20, 1)),
        'createdAt': stamp,
        'deletedAt': null,
        'duration': null,
        'fileCreatedAt': stamp,
        'fileModifiedAt': stamp,
        'height': 1,
        'width': 1,
        'isEdited': false,
        'isFavorite': false,
        'isTrashed': false,
        'libraryId': null,
        'livePhotoVideoId': null,
        'localDateTime': stamp,
        'originalFileName': 'server-photo.png',
        'stackId': null,
        'thumbhash': null,
        'type': 'IMAGE',
        'visibility': 'timeline',
      },
      'AlbumV2': {
        'id': albumId,
        'name': 'Existing server album',
        'description': '',
        'createdAt': stamp,
        'updatedAt': stamp,
        'isActivityEnabled': true,
        'order': 'desc',
        'thumbnailAssetId': photoId,
      },
      'AlbumUserV1': {'albumId': albumId, 'userId': 'existing-owner', 'role': 'owner'},
      'AlbumToAssetV1': {'albumId': albumId, 'assetId': photoId},
    };
    return events.entries
        .map((e) => '${jsonEncode({'type': e.key, 'data': e.value, 'ack': 'fresh-${e.key}'})}\n')
        .join();
  }

  String get endpoint => 'http://127.0.0.1:${server.port}/api';
  RecoveryHttpServer._(this.server) {
    server.listen((request) async {
      requests.add((
        method: request.method,
        uri: request.uri,
        authenticated:
            request.headers.value('authorization') == 'Bearer synthetic-token-stays-private' ||
            request.cookies.any((c) => c.name == 'immich_access_token' && c.value == 'synthetic-token-stays-private'),
      ));
      final response = request.response;
      if (mode == 'unauthorized') {
        response.statusCode = 401;
      } else if (mode == 'redirect') {
        response.statusCode = 302;
        response.headers.set('location', '$endpoint/forbidden');
      } else if (request.uri.path == '/api/users/me') {
        response.write(jsonEncode({...profile, 'id': mode == 'wrong_owner' ? 'other-owner' : 'existing-owner'}));
      } else if (fullFoto && request.uri.path == '/api/server/version') {
        response.write(jsonEncode({'major': 5, 'minor': 7, 'patch': 3, 'prerelease': null}));
      } else if (fullFoto && request.uri.path == '/api/server/features') {
        response.write(
          jsonEncode({
            for (final key in [
              'configFile',
              'duplicateDetection',
              'email',
              'facialRecognition',
              'importFaces',
              'map',
              'oauth',
              'oauthAutoLaunch',
              'ocr',
              'peopleStatistics',
              'realtimeTranscoding',
              'reverseGeocoding',
              'search',
              'sidecar',
              'smartSearch',
              'smartSearchHasCutoff',
              'trash',
              'authorizedDeletion',
              'ownerStorageDeletion',
            ])
              key: false,
            'passwordLogin': true,
            'syncRequestTypes': ['AuthUsersV1', 'UsersV1', 'AssetsV2', 'AlbumsV2', 'AlbumUsersV1', 'AlbumToAssetsV1'],
          }),
        );
      } else if (fullFoto && request.uri.path == '/api/server/ping') {
        response.write('{"res":"pong"}');
      } else if (fullFoto && request.uri.path == '/api/server/config') {
        response.write(
          jsonEncode({
            'externalDomain': '',
            'isInitialized': true,
            'isOnboarded': true,
            'loginPageMessage': '',
            'maintenanceMode': false,
            'mapDarkStyleUrl': '',
            'mapLightStyleUrl': '',
            'minFaces': 1,
            'oauthButtonText': '',
            'publicUsers': false,
            'trashDays': 30,
            'userDeleteDelay': 7,
          }),
        );
      } else if (fullFoto && request.uri.path == '/api/server/storage') {
        response.write(
          jsonEncode({
            'diskAvailable': '1 GiB',
            'diskAvailableRaw': 1073741824,
            'diskSize': '2 GiB',
            'diskSizeRaw': 2147483648,
            'diskUsagePercentage': 50,
            'diskUse': '1 GiB',
            'diskUseRaw': 1073741824,
          }),
        );
      } else if (fullFoto && request.uri.path == '/api/sync/ack' && request.method == 'DELETE') {
        final data = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        if (!data.containsKey('types')) {
          fullDownloadResets++;
        }
        response.statusCode = 204;
      } else if (fullFoto && request.uri.path == '/api/sync/ack' && request.method == 'POST') {
        final data = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        acknowledged.addAll((data['acks'] as List).cast<String>());
        response.statusCode = 204;
      } else if (fullFoto && request.uri.path == '/api/sync/stream' && request.method == 'POST') {
        await request.drain<void>();
        syncStreams++;
        response.headers.contentType = ContentType('application', 'jsonlines+json');
        if (fullDownloadResets == 0) {
          response.statusCode = 409;
        } else {
          response.write(libraryStream);
        }
      } else if (fullFoto &&
          request.method == 'GET' &&
          [
            '/api/memories',
            '/api/memories/lanes',
            '/api/albums',
            '/api/shared-spaces',
            '/api/views',
          ].contains(request.uri.path)) {
        response.write('[]');
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
