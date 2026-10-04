import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/utils/semver.dart';
import 'package:immich_mobile/utils/version_compatibility.dart';

void main() {
  group('custom Gallery release metadata', () {
    test('accepts the corrected 5.7.1 server version', () {
      expect(
        getVersionCompatibilityMessage(
          serverVersion: const SemVer(major: 5, minor: 7, patch: 1),
          appVersion: const SemVer(major: 5, minor: 7, patch: 1),
        ),
        isNull,
      );
    });

    test('accepts the client-only 5.7.2 patch against the 5.7.1 server', () {
      expect(
        getVersionCompatibilityMessage(
          serverVersion: const SemVer(major: 5, minor: 7, patch: 1),
          appVersion: const SemVer(major: 5, minor: 7, patch: 2),
        ),
        isNull,
      );
    });

    test('still rejects the unstamped 3.2.0 development version', () {
      expect(
        getVersionCompatibilityMessage(
          serverVersion: const SemVer(major: 3, minor: 2, patch: 0),
          appVersion: const SemVer(major: 5, minor: 7, patch: 1),
        ),
        isNotNull,
      );
    });
  });

  group('app major version behind server', () {
    const message =
        'Your mobile app version is not compatible with the server! Please update your mobile app to the latest version.';

    test('returns message when app major is behind server major', () {
      final result = getVersionCompatibilityMessage(
        serverVersion: const SemVer(major: 2, minor: 0, patch: 0),
        appVersion: const SemVer(major: 1, minor: 200, patch: 0),
      );
      expect(result, message);
    });

    test('returns null when app major matches server major', () {
      final result = getVersionCompatibilityMessage(
        serverVersion: const SemVer(major: 2, minor: 0, patch: 0),
        appVersion: const SemVer(major: 2, minor: 0, patch: 0),
      );
      expect(result, null);
    });
  });

  group('app major version too far ahead of server', () {
    const message =
        'Your server version is not compatible with the mobile app! Please update your server to the latest version.';

    test('returns message when app major is more than one ahead of server', () {
      final result = getVersionCompatibilityMessage(
        serverVersion: const SemVer(major: 1, minor: 200, patch: 0),
        appVersion: const SemVer(major: 3, minor: 0, patch: 0),
      );
      expect(result, message);
    });

    test('returns null when app major is exactly one ahead of server', () {
      final result = getVersionCompatibilityMessage(
        serverVersion: const SemVer(major: 1, minor: 200, patch: 0),
        appVersion: const SemVer(major: 2, minor: 0, patch: 0),
      );
      expect(result, null);
    });
  });
}
