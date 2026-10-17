import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/models/server_info/server_features.model.dart';
import 'package:openapi/api.dart';

void main() {
  ServerFeaturesDto features({bool? authorizedDeletion, bool? ownerStorageDeletion}) => ServerFeaturesDto.fromJson({
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
      'passwordLogin',
      'peopleStatistics',
      'realtimeTranscoding',
      'reverseGeocoding',
      'search',
      'sidecar',
      'smartSearch',
      'smartSearchHasCutoff',
      'trash',
    ])
      key: true,
    'authorizedDeletion': ?authorizedDeletion,
    'ownerStorageDeletion': ?ownerStorageDeletion,
  })!;

  test('upstream server without fork capabilities keeps ordinary trash behavior', () {
    final result = ServerFeatures.fromDto(features());
    expect(result.trash, isTrue);
    expect(result.authorizedDeletion, isFalse);
    expect(result.ownerStorageDeletion, isFalse);
  });

  test('Build 10 guarded deletion does not advertise ordinary automatic expiration', () {
    final result = ServerFeatures.fromDto(features(authorizedDeletion: true));
    expect(result.authorizedDeletion, isTrue);
    expect(result.ownerStorageDeletion, isFalse);
  });

  test('Build 11 owner storage mode is distinguished from legacy guarded deletion', () {
    final result = ServerFeatures.fromDto(features(authorizedDeletion: true, ownerStorageDeletion: true));
    expect(result.authorizedDeletion, isTrue);
    expect(result.ownerStorageDeletion, isTrue);
  });
}
