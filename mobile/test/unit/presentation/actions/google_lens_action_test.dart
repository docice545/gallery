import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_mobile/utils/action_button.utils.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../../../widget_tester_extensions.dart';
import '../../factories/local_asset_factory.dart';
import '../../factories/remote_asset_factory.dart';
import '../presentation_context.dart';

class _Viewer extends AssetViewerStateNotifier {
  _Viewer(this.asset);
  final BaseAsset asset;
  @override
  AssetViewerState build() => AssetViewerState(currentAsset: asset, isZoomed: true, stackIndex: 2);
}

void main() {
  setUpAll(() async {
    await (FontLoader('GoogleSans')..addFont(rootBundle.load('fonts/GoogleSans/GoogleSans-Regular.ttf'))).load();
    await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  late PresentationContext fixture;
  late ProviderContainer container;
  late GlobalKey boundary;
  late List<({List<BaseAsset> assets, ShareAssetType type, LivePhotoShareMode motion, Completer<void>? cancel})> calls;
  late Future<int> Function() share;
  void Function(double)? progress;

  setUp(() async {
    fixture = await PresentationContext.create();
    calls = [];
    share = () async => 1;
    progress = null;
    boundary = GlobalKey();
    when(
      () => fixture.repository.assetMedia.api.shareAssets(
        any(),
        any(),
        fileType: any(named: 'fileType'),
        livePhotoMode: any(named: 'livePhotoMode'),
        cancelCompleter: any(named: 'cancelCompleter'),
        onAssetDownloadProgress: any(named: 'onAssetDownloadProgress'),
      ),
    ).thenAnswer((invocation) {
      calls.add((
        assets: invocation.positionalArguments.first as List<BaseAsset>,
        type: invocation.namedArguments[#fileType] as ShareAssetType,
        motion: invocation.namedArguments[#livePhotoMode] as LivePhotoShareMode,
        cancel: invocation.namedArguments[#cancelCompleter] as Completer<void>?,
      ));
      progress = invocation.namedArguments[#onAssetDownloadProgress] as void Function(double)?;
      return share();
    });
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await fixture.dispose();
  });

  ActionButtonContext actionContext(
    BaseAsset asset, {
    ActionSource source = ActionSource.viewer,
    TimelineOrigin origin = TimelineOrigin.main,
    bool locked = false,
  }) => ActionButtonContext(
    asset: asset,
    isOwner: true,
    isArchived: false,
    isTrashEnabled: true,
    isStacked: false,
    isInLockedView: locked,
    currentAlbum: null,
    advancedTroubleshooting: false,
    source: source,
    timelineOrigin: origin,
  );

  Future<void> mount(
    WidgetTester tester,
    BaseAsset asset, {
    Brightness brightness = Brightness.light,
    double textScale = 1,
    bool russian = false,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      localizedForTest(
        ProviderScope(
          overrides: [...fixture.overrides, assetViewerProvider.overrideWith(() => _Viewer(asset))],
          child: Builder(
            builder: (context) => MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(brightness: brightness, useMaterial3: true, fontFamily: 'GoogleSans'),
              locale: context.locale,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(textScale),
                  padding: const EdgeInsets.only(top: 24, bottom: 24),
                  viewPadding: const EdgeInsets.only(top: 24, bottom: 24),
                ),
                child: RepaintBoundary(key: boundary, child: child),
              ),
              home: Scaffold(
                body: SafeArea(
                  child: Builder(
                    builder: (host) {
                      container = ProviderScope.containerOf(host);
                      return Align(
                        alignment: Alignment.topRight,
                        child: ImmichMenu(
                          children: [ActionButtonType.googleLens.buildButton(actionContext(asset), host)],
                          builder: (_, controller, _) => IconButton(
                            tooltip: 'Photo tools',
                            icon: const Icon(Icons.more_vert),
                            onPressed: () => controller.open(),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (russian) {
      final context = tester.element(find.byType(Scaffold));
      await context.setLocale(const Locale('ru'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byTooltip('Photo tools'));
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text(StaticTranslations.instance.google_lens));
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, StaticTranslations.instance.google_lens_choose_app));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<void> capture(WidgetTester tester, String name) async {
    const directory = String.fromEnvironment('FOTO_LENS_CAPTURE');
    if (directory.isEmpty) {
      return;
    }
    final render = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await render.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(directory).create(recursive: true);
      await File('$directory/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final storage in ['local', 'cloud', 'merged']) {
    testWidgets('$storage photo is handed off only after explicit choice; return preserves viewer state', (
      tester,
    ) async {
      final BaseAsset asset = switch (storage) {
        'local' => LocalAssetFactory.create(id: 'lens-local'),
        'cloud' => RemoteAssetFactory.create(id: 'lens-cloud'),
        _ => RemoteAssetFactory.create(id: 'lens-cloud', localId: 'lens-local'),
      };
      await mount(tester, asset);
      final before = container.read(assetViewerProvider);
      expect(calls, isEmpty);
      await open(tester);
      expect(calls, isEmpty, reason: 'Opening tools/dialog cannot send or download anything');
      await choose(tester);
      await tester.pumpAndSettle();
      expect(calls.single.assets.single, same(asset));
      expect(calls.single.type, storage == 'cloud' ? ShareAssetType.preview : ShareAssetType.original);
      expect(calls.single.motion, LivePhotoShareMode.imageOnly);
      expect(find.byType(AlertDialog), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(container.read(assetViewerProvider), before);
      expect(find.byTooltip('Photo tools'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('absent Google/Lens has a clear compatible-app fallback, without package-specific launch', (
    tester,
  ) async {
    await mount(tester, LocalAssetFactory.create());
    await open(tester);
    expect(find.textContaining('install or update the Google app'), findsOneWidget);
    expect(find.textContaining('another compatible app'), findsOneWidget);
    await choose(tester);
    expect(calls, hasLength(1));
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('cancel before choosing an app never prepares or shares a photo', (tester) async {
    await mount(tester, LocalAssetFactory.create());
    await open(tester);
    await tester.tap(find.text(StaticTranslations.instance.cancel));
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
  });

  for (final failure in ['unavailable photo', 'native chooser failure']) {
    testWidgets('$failure shows retry/close and retries only on explicit tap', (tester) async {
      share = failure == 'unavailable photo'
          ? () async => 0
          : () async => throw PlatformException(code: 'SHARE_FAILED');
      await mount(tester, RemoteAssetFactory.create());
      await open(tester);
      await choose(tester);
      expect(find.text(StaticTranslations.instance.google_lens_share_failed), findsOneWidget);
      expect(calls, hasLength(1));
      share = () async => 1;
      await tester.tap(find.widgetWithText(FilledButton, StaticTranslations.instance.retry));
      await tester.pumpAndSettle();
      expect(calls, hasLength(2));
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final cancellation in ['button', 'back', 'dispose']) {
    testWidgets('pending preparation cancels via $cancellation; late completion cannot navigate', (tester) async {
      final pending = Completer<int>();
      share = () => pending.future;
      await mount(tester, RemoteAssetFactory.create());
      await open(tester);
      await choose(tester);
      progress!(.4);
      await tester.pump();
      expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, .4);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
      expect(calls, hasLength(1));
      switch (cancellation) {
        case 'button':
          await tester.tap(find.text(StaticTranslations.instance.cancel));
        case 'back':
          Navigator.of(tester.element(find.byType(AlertDialog))).pop();
        default:
          await tester.pumpWidget(const SizedBox());
      }
      await tester.pump();
      expect(calls.single.cancel!.isCompleted, isTrue);
      progress!(1);
      pending.complete(1);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('Russian tools and Lens dialog at 390x844 $brightness font $scale', (tester) async {
        await mount(tester, LocalAssetFactory.create(), brightness: brightness, textScale: scale, russian: true);
        expect(find.text('Google Объектив'), findsOneWidget);
        await capture(tester, 'lens-menu-${brightness.name}-$scale');
        await open(tester);
        expect(find.text('Выбрать приложение'), findsOneWidget);
        final rect = tester.getRect(find.byType(AlertDialog));
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(390));
        expect(rect.top, greaterThanOrEqualTo(24));
        expect(rect.bottom, lessThanOrEqualTo(820));
        expect(Theme.of(tester.element(find.byType(AlertDialog))).brightness, brightness);
        await capture(tester, 'lens-dialog-${brightness.name}-$scale');
        expect(tester.takeException(), isNull);
        expect(calls, isEmpty);
      });
    }
  }

  test('Lens appears only for Android photographs in an unlocked non-trash viewer', () {
    final photo = RemoteAssetFactory.create();
    for (final origin in [TimelineOrigin.main, TimelineOrigin.localAlbum, TimelineOrigin.remoteAlbum]) {
      expect(ActionButtonType.googleLens.shouldShow(actionContext(photo, origin: origin)), isTrue);
    }
    expect(ActionButtonType.googleLens.shouldShow(actionContext(photo, source: ActionSource.timeline)), isFalse);
    expect(ActionButtonType.googleLens.shouldShow(actionContext(photo, origin: TimelineOrigin.trash)), isFalse);
    expect(ActionButtonType.googleLens.shouldShow(actionContext(photo, locked: true)), isFalse);
    expect(ActionButtonType.googleLens.shouldShow(actionContext(photo.copyWith(type: AssetType.video))), isFalse);
    expect(ActionButtonType.googleLens.shouldShow(actionContext(photo.copyWith(deletedAt: DateTime.now()))), isFalse);
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      expect(ActionButtonType.googleLens.shouldShow(actionContext(photo)), isFalse);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
