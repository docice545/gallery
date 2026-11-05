import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/presentation/widgets/album/local_album_deletion_listener.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:mocktail/mocktail.dart';

import '../../../infrastructure/repository.mock.dart';
import '../../../unit/factories/local_asset_factory.dart';
import '../../../unit/presentation/presentation_context.dart';

void main() {
  late PresentationContext fixture;
  late MockLocalAlbumRepository repository;
  setUp(() async {
    fixture = await PresentationContext.create();
    repository = MockLocalAlbumRepository();
    when(() => repository.getAssets('camera')).thenAnswer((_) async => []);
  });
  tearDown(() => fixture.dispose());

  Future<RootStackRouter> mount(WidgetTester tester) async {
    final drift = MockDrift();
    when(() => drift.localAlbumRepository).thenReturn(repository);
    final router = RootStackRouter.build(
      routes: [
        AutoRoute(
          initial: true,
          page: PageInfo('Albums', builder: (_) => const Scaffold(body: Text('Device albums'))),
        ),
        AutoRoute(
          page: PageInfo(
            'Album',
            builder: (_) => const Scaffold(
              body: LocalAlbumDeletionListener(albumId: 'camera', child: Text('Camera photos')),
            ),
          ),
        ),
        AutoRoute(
          page: PageInfo('Viewer', builder: (_) => const Scaffold(body: Text('Viewer'))),
        ),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      router.dispose();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: fixture.overrides,
        child: ProviderScope(
          overrides: [driftProvider.overrideWithValue(drift)],
          child: MaterialApp.router(routerConfig: router.config()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    unawaited(router.push(const PageRouteInfo('Album')));
    await tester.pumpAndSettle();
    return router;
  }

  void acknowledged({String album = 'camera', Set<String> assets = const {'deleted'}}) =>
      EventStream.shared.emit(DeviceTrashAcknowledgedEvent(albumIds: {album}, assetIds: assets));

  testWidgets('initial empty/loading/refresh and unrelated deletion never navigate', (tester) async {
    final router = await mount(tester);
    EventStream.shared.emit(const TimelineReloadEvent());
    acknowledged(album: 'another-album');
    acknowledged(assets: {});
    await tester.pumpAndSettle();
    expect(router.current.name, 'Album');
    verifyNever(() => repository.getAssets(any()));
  });

  testWidgets('a confirmed last deletion reads fresh membership then returns to list exactly once', (tester) async {
    final router = await mount(tester);
    acknowledged();
    await tester.pumpAndSettle();
    expect(router.current.name, 'Albums');
    expect(find.text('Device albums'), findsOneWidget);
    verify(() => repository.getAssets('camera')).called(1);
  });

  testWidgets('a survivor or failed database read cannot be interpreted as empty', (tester) async {
    final router = await mount(tester);
    when(() => repository.getAssets('camera')).thenAnswer((_) async => [LocalAssetFactory.create()]);
    acknowledged();
    await tester.pumpAndSettle();
    expect(router.current.name, 'Album');
    when(() => repository.getAssets('camera')).thenThrow(StateError('synthetic read failure'));
    acknowledged();
    await tester.pumpAndSettle();
    expect(router.current.name, 'Album');
    expect(tester.takeException(), isNull);
  });

  testWidgets('ACK under Viewer waits for the album route and never pops an unrelated route', (tester) async {
    final router = await mount(tester);
    unawaited(router.push(const PageRouteInfo('Viewer')));
    await tester.pumpAndSettle();
    acknowledged();
    await tester.pumpAndSettle();
    expect(router.current.name, 'Viewer');
    verifyNever(() => repository.getAssets(any()));
    await router.maybePop();
    await tester.pumpAndSettle();
    expect(router.current.name, 'Albums');
  });

  testWidgets('disposing the album during membership lookup cannot pop its replacement', (tester) async {
    final router = await mount(tester);
    final pending = Completer<List<LocalAsset>>();
    when(() => repository.getAssets('camera')).thenAnswer((_) => pending.future);
    acknowledged();
    await tester.pump();
    unawaited(router.replace(const PageRouteInfo('Viewer')));
    await tester.pumpAndSettle();
    pending.complete([]);
    await tester.pumpAndSettle();
    expect(router.current.name, 'Viewer');
    expect(tester.takeException(), isNull);
  });
}
