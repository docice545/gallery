import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/map_config.dart';
import 'package:immich_mobile/domain/models/map.model.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/domain/services/user.service.dart';
import 'package:immich_mobile/infrastructure/repositories/map.repository.dart';
import 'package:immich_mobile/presentation/widgets/map/map.state.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/map.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/map/map_state.provider.dart' as legacy;
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/providers/sync_status.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/services/server_info.service.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:mocktail/mocktail.dart';

class _Database extends Mock implements Drift {}

class _Repository extends Mock implements MapRepository {}

class _Users extends Mock implements UserService {}

class _Server extends Mock implements ServerInfoService {}

class _MapState extends MapStateNotifier {
  @override
  MapState build() => MapState(
    bounds: LatLngBounds(southwest: const LatLng(0, 0), northeast: const LatLng(0, 0)),
  );
  void favorite() => state = state.copyWith(onlyFavorites: true);
}

class _ServerState extends ServerInfoNotifier {
  _ServerState() : super(_Server());
  void sources(String light, String dark) => state = state.copyWith(
    serverConfig: state.serverConfig.copyWith(mapLightStyleUrl: light, mapDarkStyleUrl: dark),
  );
}

void main() {
  setUpAll(
    () => registerFallbackValue(
      TimelineMapOptions(
        bounds: LatLngBounds(southwest: const LatLng(0, 0), northeast: const LatLng(0, 0)),
      ),
    ),
  );

  test('panning does not rebuild query or aggregate extent; filter and sync changes do', () async {
    final db = _Database();
    final repository = _Repository();
    final users = _Users();
    final map = _MapState();
    when(() => db.mapRepository).thenReturn(repository);
    when(
      () => users.tryGetMyUser(),
    ).thenReturn(UserDto(id: 'viewer', name: 'viewer', email: 'v@test', profileChangedAt: DateTime(2025)));
    when(() => users.watchMyUser()).thenAnswer((_) => const Stream.empty());
    when(() => repository.remote(any(), any(), any())).thenReturn((markerSource: (_) async => []));
    var reads = 0;
    when(() => repository.getInitialViewport(any(), any(), any())).thenAnswer((_) async {
      reads++;
      return null;
    });
    final container = ProviderContainer(
      overrides: [
        driftProvider.overrideWith((_) => db),
        currentUserProvider.overrideWith((_) => CurrentUserProvider(users)),
        mapStateProvider.overrideWith(() => map),
      ],
    );
    addTearDown(container.dispose);
    final first = container.read(mapServiceProvider);
    await container.read(initialMapViewportProvider.future);
    map.setBounds(LatLngBounds(southwest: const LatLng(50, 30), northeast: const LatLng(60, 40)));
    await container.pump();
    expect(identical(container.read(mapServiceProvider), first), isTrue);
    await container.read(initialMapViewportProvider.future);
    expect(reads, 1);
    container.read(syncStatusProvider.notifier).markRemoteContentChanged();
    await container.read(initialMapViewportProvider.future);
    expect(reads, 2);
    map.favorite();
    await container.pump();
    expect(identical(container.read(mapServiceProvider), first), isFalse);
    await container.read(initialMapViewportProvider.future);
    expect(reads, 3);
  });

  test('async custom server sources arrive without replacing the persisted map theme', () {
    final server = _ServerState();
    final container = ProviderContainer(
      overrides: [
        serverInfoProvider.overrideWith((_) => server),
        appConfigProvider.overrideWithValue(const AppConfig(map: MapConfig(themeMode: ThemeMode.dark))),
      ],
    );
    addTearDown(container.dispose);
    expect(container.read(legacy.mapStateNotifierProvider).themeMode, ThemeMode.dark);
    server.sources('https://custom.test/light', '{"version":8,"layers":[]}');
    final map = container.read(legacy.mapStateNotifierProvider);
    expect(map.themeMode, ThemeMode.dark);
    expect(map.lightStyleFetched.valueOrNull, 'https://custom.test/light');
    expect(map.darkStyleFetched.valueOrNull, '{"version":8,"layers":[]}');
  });
}
