import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/models/stack.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/asset.service.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_exif.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/trashed_local_asset.repository.dart';
import 'package:immich_mobile/platform/remote_image_api.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_details.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_page.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_stack.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_viewer.page.dart';
import 'package:immich_mobile/presentation/widgets/icons/proposal/foto_icon.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/routes.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/services/cleanup.service.dart';
import 'package:immich_mobile/services/gcast.service.dart';
import 'package:immich_mobile/services/server_info.service.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart' as api_client;

import '../../../medium/repository_context.dart';
import '../../../repository.mocks.dart';
import '../../../unit/presentation/presentation_context.dart';

const _homeName = 'StackDeletionHome';
const _viewerName = 'StackDeletionViewer';

class _SeededViewer extends AssetViewerStateNotifier {
  _SeededViewer(this.asset);

  final RemoteAsset asset;

  @override
  AssetViewerState build() {
    super.build();
    return AssetViewerState(currentAsset: asset);
  }
}

class _GatedAssetService extends AssetService {
  _GatedAssetService({
    required super.remoteRepository,
    required super.exifRepository,
    required super.localRepository,
    required super.apiRepository,
    required super.mediaRepository,
    required super.trashedLocalRepository,
  });

  Completer<void>? stackGate;
  Completer<void>? stackRefreshEntered;
  bool failNextStackRead = false;

  @override
  Future<List<RemoteAsset>> getStack(RemoteAsset asset) async {
    final gate = stackGate;
    stackGate = null;
    final stack = await super.getStack(asset);
    if (failNextStackRead) {
      failNextStackRead = false;
      throw StateError('fixture stack read failure');
    }
    if (gate != null) {
      stackRefreshEntered?.complete();
      await gate.future;
    }
    return stack;
  }
}

class _GatedTimeline extends TimelineService {
  _GatedTimeline(super.query);

  Completer<void>? neighborGate;
  Completer<void>? neighborEntered;

  @override
  Future<BaseAsset?> getAssetAsync(int index) async {
    final asset = await super.getAssetAsync(index);
    if (asset?.id == 'neighbor' && neighborGate != null) {
      final gate = neighborGate!;
      neighborEntered?.complete();
      neighborEntered = null;
      await gate.future;
    }
    return asset;
  }
}

void main() {
  late PresentationContext presentation;
  late MediumRepositoryContext repository;
  late RemoteAssetRepository remote;
  late MockAssetApiRepository api;
  late _GatedAssetService assets;
  late _GatedTimeline timeline;
  late RemoteAsset cover;
  late Completer<void> response;
  late Completer<void> requestEntered;
  var rejectResponse = false;

  const requestChannel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.RemoteImageApi.requestImage',
    RemoteImageApi.pigeonChannelCodec,
  );
  const cancelChannel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.RemoteImageApi.cancelRequest',
    RemoteImageApi.pigeonChannelCodec,
  );

  setUpAll(() async => initializeDateFormatting('en'));

  setUp(() async {
    presentation = await PresentationContext.create();
    repository = MediumRepositoryContext();
    final owner = presentation.currentUser.id;
    await repository.newUser(id: owner);
    await repository.newAuthUser(id: owner);
    for (final (index, id) in ['cover', 'next-frame', 'last-frame'].indexed) {
      await repository.newRemoteAsset(
        id: id,
        ownerId: owner,
        stackId: 'stack',
        checksum: 'checksum-$id',
        createdAt: DateTime(2026, 10, 26, 12 - index),
        width: 400,
        height: 300,
        thumbHash: '',
      );
    }
    await repository.insertStack(id: 'stack', ownerId: owner, primaryAssetId: 'cover');
    remote = RemoteAssetRepository(repository.db);
    cover = (await remote.get('cover'))!;
    api = MockAssetApiRepository();
    response = Completer<void>();
    requestEntered = Completer<void>();
    rejectResponse = false;
    when(() => api.delete(['cover'], false)).thenAnswer((_) async {
      requestEntered.complete();
      await response.future;
      if (rejectResponse) {
        throw api_client.ApiException(403, 'fixture rejection');
      }
    });
    assets = _GatedAssetService(
      remoteRepository: remote,
      exifRepository: RemoteExifRepository(repository.db),
      localRepository: LocalAssetRepository(repository.db),
      apiRepository: api,
      mediaRepository: presentation.repository.assetMedia.api,
      trashedLocalRepository: TrashedLocalAssetRepository(repository.db),
    );
    final initialReload = EventStream.shared.where<TimelineReloadEvent>().first;
    timeline = _GatedTimeline(TimelineRepository(repository.db).main([owner], owner, GroupAssetsBy.day));
    await initialReload;

    // Keep images pending through the existing channel. Route and active-frame
    // assertions must not depend on HTTP or native media decoders.
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockDecodedMessageHandler(requestChannel, (_) async => <Object?>[null]);
    messenger.setMockDecodedMessageHandler(cancelChannel, (_) async => <Object?>[null]);
  });

  tearDown(() async {
    if (!response.isCompleted) {
      response.complete();
    }
    await timeline.dispose();
    await repository.dispose();
    await presentation.dispose();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockDecodedMessageHandler(requestChannel, null);
    messenger.setMockDecodedMessageHandler(cancelChannel, null);
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  Future<RootStackRouter> openViewer(WidgetTester tester) async {
    final router = RootStackRouter.build(
      routes: [
        AutoRoute(initial: true, page: PageInfo(_homeName, builder: (_) => const SizedBox.shrink())),
        AutoRoute(page: PageInfo(_viewerName, builder: (_) => const AssetViewer(initialIndex: 0, heroOffset: 0))),
      ],
    );
    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: locales.values.toList(),
        path: translationsPath,
        startLocale: locales.values.first,
        fallbackLocale: locales.values.first,
        saveLocale: false,
        useFallbackTranslations: true,
        assetLoader: const CodegenLoader(),
        child: ProviderScope(
          overrides: [
            driftProvider.overrideWithValue(repository.db),
            assetServiceProvider.overrideWithValue(assets),
            timelineServiceProvider.overrideWithValue(timeline),
            assetViewerProvider.overrideWith(() => _SeededViewer(cover)),
            currentUserProvider.overrideWith((_) => CurrentUserProvider(presentation.service.user.service)),
            cleanupServiceProvider.overrideWithValue(presentation.service.cleanup.service),
            remoteAlbumServiceProvider.overrideWithValue(presentation.service.album.service),
            gCastServiceProvider.overrideWithValue(presentation.service.cast),
            serverInfoServiceProvider.overrideWithValue(presentation.service.serverInfo),
            inLockedViewProvider.overrideWithValue(false),
          ],
          child: Builder(
            builder: (context) => MaterialApp.router(
              debugShowCheckedModeBanner: false,
              routerConfig: router.config(),
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    unawaited(router.push(const PageRouteInfo(_viewerName)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    return router;
  }

  Future<void> drain(WidgetTester tester) async {
    // Drift invalidation and widget frames use separate schedulers.
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
    }
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> awaitRequest(WidgetTester tester) async {
    for (var frame = 0; frame < 200 && !requestEntered.isCompleted; frame++) {
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    }
    expect(requestEntered.isCompleted, isTrue);
  }

  Future<void> closeViewer(WidgetTester tester, RootStackRouter router, {Future<void>? deletion}) async {
    if (!response.isCompleted) {
      response.complete();
    }
    await drain(tester);
    if (deletion != null) {
      await tester.runAsync(() => deletion.timeout(const Duration(seconds: 5)));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    router.dispose();
  }

  for (final deleted in ['cover', 'next-frame']) {
    testWidgets('exact stack 2→1: deleting $deleted keeps its survivor without a stack container', (tester) async {
      await tester.runAsync(() => remote.trash(['last-frame']));
      final router = await openViewer(tester);
      final container = ProviderScope.containerOf(tester.element(find.byType(AssetViewer)));
      Future<void>? deletion;
      try {
        expect(find.text('1/2'), findsOneWidget);
        if (deleted != 'cover') {
          final child = await tester.runAsync(() => remote.get(deleted));
          container.read(assetViewerProvider.notifier)
            ..setAsset(child!)
            ..setStackIndex(1);
          when(() => api.delete([deleted], false)).thenAnswer((_) async {
            requestEntered.complete();
            await response.future;
          });
          await drain(tester);
        }
        final button = tester.widget<FotoIconButton>(
          find.byWidgetPredicate((widget) => widget is FotoIconButton && widget.kind == FotoIconKind.trash),
        );
        deletion = Future<void>.sync(button.onPressed!);
        await awaitRequest(tester);
        response.complete();
        await drain(tester);
        await tester.runAsync(() => deletion!.timeout(const Duration(seconds: 5)));
        final survivor = deleted == 'cover' ? 'next-frame' : 'cover';
        expect(router.current.name, _viewerName);
        expect(container.read(assetViewerProvider).currentAsset?.id, survivor);
        expect(timeline.totalAssets, 1);
        expect(timeline.getAssetSafe(0)?.id, survivor, reason: 'no sync or unStack is required');
        expect(tester.widgetList<AssetDetails>(find.byType(AssetDetails)).map((details) => details.asset.id), [
          survivor,
        ]);
        expect(
          find.descendant(of: find.byType(AssetStackRow), matching: find.byType(SingleChildScrollView)),
          findsNothing,
        );
        expect(await tester.runAsync(() async => (await remote.get(survivor))!.deletedAt), isNull);
        expect(await tester.runAsync(() async => (await remote.get(survivor))!.checksum), 'checksum-$survivor');
        await tester.runAsync(() => remote.restoreTrash([deleted]));
        await drain(tester);
        expect(
          find.descendant(of: find.byType(AssetStackRow), matching: find.byType(SingleChildScrollView)),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await closeViewer(tester, router, deletion: deletion);
      }
    });
  }

  testWidgets('trashing a viewed primary keeps active siblings open while the server response is pending', (
    tester,
  ) async {
    final router = await openViewer(tester);
    expect(router.current.name, _viewerName);
    expect(timeline.totalAssets, 1, reason: 'the real main Timeline collapses the three-frame stack');
    expect(find.byTooltip(StaticTranslations.instance.move_to_server_trash), findsOneWidget);
    final container = ProviderScope.containerOf(tester.element(find.byType(AssetViewer)));
    final deleteButton = tester.widget<FotoIconButton>(
      find.byWidgetPredicate((widget) => widget is FotoIconButton && widget.kind == FotoIconKind.trash),
    );
    late Future<void> deletion;

    try {
      final activeSiblings = await tester.runAsync(() async {
        deletion = Future<void>.sync(deleteButton.onPressed!);
        await requestEntered.future.timeout(const Duration(seconds: 5));
        return assets.getStack(cover).timeout(const Duration(seconds: 5));
      });
      await drain(tester);

      expect(activeSiblings!.map((asset) => asset.id), ['next-frame', 'last-frame']);
      expect(response.isCompleted, isFalse);
      verify(() => api.delete(['cover'], false)).called(1);
      expect(
        router.current.name,
        _viewerName,
        reason: 'optimistic Trash must not close the Viewer while this stack still has two active frames',
      );
      expect(find.byType(AssetViewer), findsOneWidget);
      final current = container.read(assetViewerProvider).currentAsset;
      expect(current?.id, 'next-frame');
      expect(
        tester.widgetList<AssetDetails>(find.byType(AssetDetails)).map((details) => details.asset.id),
        contains(current!.id),
        reason: 'the retained route must display its active frame, rather than an empty page',
      );
      expect(tester.takeException(), isNull);

      response.complete();
      await drain(tester);
      await tester.runAsync(() => deletion.timeout(const Duration(seconds: 5)));
      await tester.runAsync(() async {
        await remote.stack(
          presentation.currentUser.id,
          const StackResponse(id: 'stack', primaryAssetId: 'next-frame', assetIds: ['next-frame', 'last-frame']),
        );
      });
      await drain(tester);
      expect(container.read(assetViewerProvider).currentAsset?.id, 'next-frame');
      expect(tester.widgetList<AssetDetails>(find.byType(AssetDetails)).map((details) => details.asset.id), [
        'next-frame',
      ]);
      expect(tester.widget<PageView>(find.byType(PageView)).childrenDelegate.estimatedChildCount, 1);
    } finally {
      await closeViewer(tester, router, deletion: deletion);
    }
  });

  testWidgets('a definite server rejection restores the original viewed primary', (tester) async {
    final router = await openViewer(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(AssetViewer)));
    final button = tester.widget<FotoIconButton>(
      find.byWidgetPredicate((widget) => widget is FotoIconButton && widget.kind == FotoIconKind.trash),
    );
    late Future<void> deletion;
    try {
      await tester.runAsync(() async {
        deletion = Future<void>.sync(button.onPressed!);
        await requestEntered.future;
      });
      await drain(tester);
      expect(container.read(assetViewerProvider).currentAsset?.id, 'next-frame');
      rejectResponse = true;
      response.complete();
      await drain(tester);
      await tester.runAsync(() => deletion.timeout(const Duration(seconds: 5)));
      expect(router.current.name, _viewerName);
      expect(container.read(assetViewerProvider).currentAsset?.id, 'cover');
      expect(tester.widgetList<AssetDetails>(find.byType(AssetDetails)).map((details) => details.asset.id), ['cover']);
      expect(await tester.runAsync(() async => (await remote.get('cover'))!.deletedAt), isNull);
      expect(tester.takeException(), isNull);
    } finally {
      await closeViewer(tester, router, deletion: deletion);
    }
  });

  testWidgets('remote frame changes refresh the cached stack and ignore a late local deletion event', (tester) async {
    final router = await openViewer(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(AssetViewer)));
    try {
      await drain(tester);
      await tester.runAsync(() async {
        final child = await remote.get('next-frame');
        container.read(assetViewerProvider.notifier)
          ..setAsset(child!)
          ..setStackIndex(1);
        await remote.trash(['next-frame']);
      });
      await drain(tester);
      expect(container.read(assetViewerProvider).currentAsset?.id, 'last-frame');
      expect(find.text('2/2'), findsOneWidget);
      EventStream.shared.emit(
        const ViewerStackAssetDeletedEvent(stackIndex: 1, assetId: 'next-frame', stackId: 'stack'),
      );
      await drain(tester);
      expect(container.read(assetViewerProvider).currentAsset?.id, 'last-frame');

      await tester.runAsync(() => remote.trash(['last-frame']));
      await drain(tester);
      await tester.runAsync(() => remote.unStack(['stack']));
      await drain(tester);
      expect(container.read(assetViewerProvider).currentAsset?.id, 'cover');
      expect(find.text('1/1'), findsNothing);
      await tester.runAsync(() => remote.trash(['cover']));
      await drain(tester);
      expect(router.current.name, _homeName);
      expect(tester.takeException(), isNull);
    } finally {
      await closeViewer(tester, router);
    }
  });

  testWidgets('an older asynchronous stack refresh cannot replace the frame selected meanwhile', (tester) async {
    final router = await openViewer(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(AssetViewer)));
    final gate = Completer<void>();
    try {
      await drain(tester);
      assets.stackGate = gate;
      assets.stackRefreshEntered = Completer<void>();
      await tester.runAsync(() async {
        final child = await remote.get('next-frame');
        container.read(assetViewerProvider.notifier)
          ..setAsset(child!)
          ..setStackIndex(1);
        await remote.trash(['next-frame']);
      });
      await drain(tester);
      expect(assets.stackRefreshEntered!.isCompleted, isTrue);
      await tester.runAsync(() async {
        container.read(assetViewerProvider.notifier)
          ..setAsset(cover)
          ..setStackIndex(0);
      });
      gate.complete();
      await drain(tester);
      expect(router.current.name, _viewerName);
      expect(container.read(assetViewerProvider).currentAsset?.id, 'cover');
      expect(tester.widgetList<AssetDetails>(find.byType(AssetDetails)).map((details) => details.asset.id), ['cover']);
      expect(tester.takeException(), isNull);
    } finally {
      if (!gate.isCompleted) {
        gate.complete();
      }
      await closeViewer(tester, router);
    }
  });

  testWidgets('a rejected second deletion restores that frame while primary promotion is still pending', (
    tester,
  ) async {
    final router = await openViewer(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(AssetViewer)));
    Future<void> deleteCurrent() => Future<void>.sync(
      tester
          .widget<FotoIconButton>(
            find.byWidgetPredicate((widget) => widget is FotoIconButton && widget.kind == FotoIconKind.trash),
          )
          .onPressed!,
    );
    late Future<void> first;
    late Future<void> second;
    final secondResponse = Completer<void>();
    try {
      await tester.runAsync(() async {
        first = deleteCurrent();
        await requestEntered.future;
      });
      await drain(tester);
      response.complete();
      await drain(tester);
      await tester.runAsync(() => first);
      expect(container.read(assetViewerProvider).currentAsset?.id, 'next-frame');
      when(() => api.delete(['next-frame'], false)).thenAnswer((_) async {
        await secondResponse.future;
        throw api_client.ApiException(403, 'second fixture rejection');
      });
      await tester.runAsync(() async {
        second = deleteCurrent();
      });
      await drain(tester);
      expect(container.read(assetViewerProvider).currentAsset?.id, 'last-frame');
      secondResponse.complete();
      await drain(tester);
      await tester.runAsync(() => second);
      expect(router.current.name, _viewerName);
      expect(container.read(assetViewerProvider).currentAsset?.id, 'next-frame');
      expect(tester.takeException(), isNull);
    } finally {
      if (!secondResponse.isCompleted) {
        secondResponse.complete();
      }
      await closeViewer(tester, router);
    }
  });

  testWidgets('returning to the surviving stack page cancels a delayed neighbor load and keeps navigation mapped', (
    tester,
  ) async {
    await tester.runAsync(
      () => repository.newRemoteAsset(
        id: 'neighbor',
        ownerId: presentation.currentUser.id,
        createdAt: DateTime(2020),
        thumbHash: '',
      ),
    );
    await drain(tester);
    expect(timeline.totalAssets, 2);
    await tester.runAsync(() => timeline.loadAssets(0, 2));
    expect(timeline.getAssets(0, 2).map((asset) => asset.id), ['cover', 'neighbor']);
    final router = await openViewer(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(AssetViewer)));
    late Future<void> deletion;
    final gate = Completer<void>();
    try {
      final button = tester.widget<FotoIconButton>(
        find.byWidgetPredicate((widget) => widget is FotoIconButton && widget.kind == FotoIconKind.trash),
      );
      await tester.runAsync(() async {
        deletion = Future<void>.sync(button.onPressed!);
        await requestEntered.future;
      });
      await drain(tester);
      expect(timeline.totalAssets, 2, reason: 'the active stack representative remains in the real Timeline');
      expect(tester.widget<PageView>(find.byType(PageView)).childrenDelegate.estimatedChildCount, 2);
      final entered = Completer<void>();
      timeline.neighborGate = gate;
      timeline.neighborEntered = entered;
      final controller = tester.widget<PageView>(find.byType(PageView)).controller!;
      final navigate = tester
          .widgetList<AssetPage>(find.byType(AssetPage))
          .firstWhere((page) => page.index == 0)
          .onTapNavigate!;
      navigate(1);
      await drain(tester);
      expect(entered.isCompleted, isTrue);
      navigate(-1);
      await drain(tester);
      gate.complete();
      timeline.neighborGate = null;
      await drain(tester);
      expect(container.read(assetViewerProvider).currentAsset?.id, 'next-frame');
      expect(controller.page, 0);
      navigate(1);
      await drain(tester);
      expect(container.read(assetViewerProvider).currentAsset?.id, 'neighbor');
      expect(controller.page, 1, reason: 'the survivor remains a real Timeline card before the neighbor');
      expect(tester.widget<PageView>(find.byType(PageView)).childrenDelegate.estimatedChildCount, 2);
      expect(tester.takeException(), isNull);
    } finally {
      if (!gate.isCompleted) {
        gate.complete();
      }
      await closeViewer(tester, router, deletion: deletion);
    }
  });

  testWidgets('a failed stack refresh keeps the last displayed frame and reports the error', (tester) async {
    final router = await openViewer(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(AssetViewer)));
    try {
      await drain(tester);
      expect(find.text('1/3'), findsOneWidget);
      assets.failNextStackRead = true;
      EventStream.shared.emit(const TimelineReloadEvent());
      await drain(tester);
      expect(router.current.name, _viewerName);
      expect(container.read(assetViewerProvider).currentAsset?.id, 'cover');
      expect(tester.widgetList<AssetDetails>(find.byType(AssetDetails)).map((details) => details.asset.id), ['cover']);
      expect(find.text('1/3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await closeViewer(tester, router);
    }
  });

  testWidgets('deleting the final active stack frame displays the following standalone photo at the same index', (
    tester,
  ) async {
    await tester.runAsync(
      () => repository.newRemoteAsset(
        id: 'neighbor',
        ownerId: presentation.currentUser.id,
        createdAt: DateTime(2020),
        thumbHash: '',
      ),
    );
    await drain(tester);
    await tester.runAsync(() => timeline.loadAssets(0, 2));
    final router = await openViewer(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(AssetViewer)));
    late Future<void> deletion;
    try {
      await tester.runAsync(() => remote.trash(['next-frame', 'last-frame']));
      await drain(tester);
      expect(container.read(assetViewerProvider).currentAsset?.id, 'cover');
      expect(find.text('1/1'), findsNothing);
      final button = tester.widget<FotoIconButton>(
        find.byWidgetPredicate((widget) => widget is FotoIconButton && widget.kind == FotoIconKind.trash),
      );
      await tester.runAsync(() async {
        deletion = Future<void>.sync(button.onPressed!);
        await requestEntered.future;
      });
      await drain(tester);
      expect(response.isCompleted, isFalse);
      expect(router.current.name, _viewerName);
      expect(container.read(assetViewerProvider).currentAsset?.id, 'neighbor');
      expect(tester.widgetList<AssetDetails>(find.byType(AssetDetails)).map((details) => details.asset.id), [
        'neighbor',
      ]);
      expect(tester.takeException(), isNull);
    } finally {
      await closeViewer(tester, router, deletion: deletion);
    }
  });
}
