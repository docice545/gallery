import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/models/server_info/server_info.model.dart';
import 'package:immich_mobile/models/server_info/server_version.model.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/services/server_info.service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart';
import 'package:package_info_plus/package_info_plus.dart';

class _MockServerInfoService extends Mock implements ServerInfoService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const release = ServerVersion(major: 5, minor: 7, patch: 1);
  final admin = UserDto(
    id: 'admin',
    email: 'admin@example.com',
    name: 'Admin',
    isAdmin: true,
    profileChangedAt: DateTime(2026),
  );
  late _MockServerInfoService service;
  late ProviderContainer container;

  void setClientVersion(String version) {
    PackageInfo.setMockInitialValues(
      appName: 'Photos',
      packageName: 'de.opennoodle.gallery',
      version: version,
      buildNumber: '2',
      buildSignature: '',
    );
  }

  setUp(() {
    setClientVersion('5.7.1');
    service = _MockServerInfoService();
    container = ProviderContainer(overrides: [serverInfoServiceProvider.overrideWithValue(service)]);
    addTearDown(container.dispose);
  });

  Future<void> receiveReleaseInfo(ServerVersion current, ServerVersion latest) async {
    container.read(serverInfoProvider.notifier).handleReleaseInfo(current, latest);
    // handleReleaseInfo receives a socket event and schedules PackageInfo lookup.
    await Future<void>.delayed(Duration.zero);
  }

  test('version DTO feeds the account state and clears the false admin update warning', () async {
    final version = ServerVersion.fromDto(ServerVersionResponseDto(major: 5, minor: 7, patch_: 1, prerelease: null));
    when(() => service.getServerVersion()).thenAnswer((_) async => version);

    await container.read(serverInfoProvider.notifier).getServerVersion();
    await receiveReleaseInfo(version, release);

    final state = container.read(serverInfoProvider);
    expect(state.serverVersion.toString(), '5.7.1');
    expect(state.latestVersion.toString(), '5.7.1');
    expect(state.versionStatus, VersionStatus.upToDate);
    expect(container.read(versionWarningPresentProvider(admin)), isFalse);
  });

  test('client-only 5.7.2 patch does not advertise a nonexistent server update', () async {
    setClientVersion('5.7.2');

    await receiveReleaseInfo(release, release);

    expect(container.read(serverInfoProvider).versionStatus, VersionStatus.upToDate);
    expect(container.read(versionWarningPresentProvider(admin)), isFalse);
  });

  test('HTTP refresh retains the authoritative latest server release', () async {
    setClientVersion('5.7.2');
    await receiveReleaseInfo(release, release);
    when(() => service.getServerVersion()).thenAnswer((_) async => release);

    await container.read(serverInfoProvider.notifier).getServerVersion();

    expect(container.read(serverInfoProvider).versionStatus, VersionStatus.upToDate);
    expect(container.read(versionWarningPresentProvider(admin)), isFalse);
  });

  test('an actual newer server release still warns the administrator', () async {
    await receiveReleaseInfo(release, const ServerVersion(major: 5, minor: 7, patch: 2));

    expect(container.read(serverInfoProvider).versionStatus, VersionStatus.serverOutOfDate);
    expect(container.read(versionWarningPresentProvider(admin)), isTrue);
    expect(container.read(versionWarningPresentProvider(admin.copyWith(isAdmin: false))), isFalse);
  });

  test('a newer incompatible server still requests a client update', () async {
    const newerServer = ServerVersion(major: 6, minor: 0, patch: 0);

    await receiveReleaseInfo(newerServer, newerServer);

    expect(container.read(serverInfoProvider).versionStatus, VersionStatus.clientOutOfDate);
    expect(container.read(versionWarningPresentProvider(admin)), isTrue);
  });

  test('missing metadata remains an error', () async {
    when(() => service.getServerVersion()).thenAnswer((_) async => null);

    await container.read(serverInfoProvider.notifier).getServerVersion();

    expect(container.read(serverInfoProvider).versionStatus, VersionStatus.error);
    expect(container.read(versionWarningPresentProvider(admin)), isTrue);
  });
}
