import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/presentation/actions/action.widget.dart';
import 'package:immich_mobile/presentation/actions/share.action.dart';
import 'package:immich_mobile/presentation/actions/share_link.action.dart';
import 'package:immich_mobile/providers/infrastructure/toast.provider.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../../factories/local_asset_factory.dart';
import '../../factories/remote_asset_factory.dart';
import '../presentation_context.dart';

void main() {
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  late BuildContext actionContext;
  late WidgetRef actionRef;

  Future<void> pumpShare(WidgetTester tester, {Set<BaseAsset>? selection}) => tester.pumpTestWidget(
    context,
    Consumer(
      builder: (widgetContext, ref, _) {
        actionContext = widgetContext;
        actionRef = ref;
        return const ActionIconButton(action: ShareAction(source: .timeline));
      },
    ),
    overrides: [
      ...context.selected(selection ?? {RemoteAssetFactory.create(ownerId: context.currentUser.id)}),
    ],
  );

  // TODO: Replace with button tap once long press support in ui is merged
  Future<void> invokeSecondaryAction() async {
    final resolved = const ShareAction(source: .timeline).create(actionContext, actionRef);
    await resolved!.onSecondaryAction!();
  }

  List<ShareAssetType> sharedFileTypes() => verify(
    () => context.repository.assetMedia.api.shareAssets(
      any(),
      any(),
      fileType: captureAny(named: 'fileType'),
      cancelCompleter: any(named: 'cancelCompleter'),
      onAssetDownloadProgress: any(named: 'onAssetDownloadProgress'),
    ),
  ).captured.cast<ShareAssetType>();

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const .new(milliseconds: 300));
  }

  Future<void> pickPreviewQuality(WidgetTester tester) async {
    final shared = invokeSecondaryAction();
    await settle(tester);
    await tester.tap(find.byIcon(Icons.photo_size_select_large_rounded));
    await settle(tester);
    await shared;
  }

  group('ShareAction', () {
    testWidgets('single press shares with the configured default quality', (tester) async {
      await pumpShare(tester);

      await tester.tap(find.byType(ImmichIconButton));
      await settle(tester);

      expect(sharedFileTypes(), [ShareAssetType.original]);
    });

    testWidgets('the secondary action shares with the quality picked in the dialog', (tester) async {
      await pumpShare(tester);

      await pickPreviewQuality(tester);

      expect(sharedFileTypes(), [ShareAssetType.preview]);
    });

    testWidgets('quality picked there is a one-time choice and does not change the default', (tester) async {
      await pumpShare(tester);

      await pickPreviewQuality(tester);
      await tester.tap(find.byType(ImmichIconButton));
      await settle(tester);

      expect(sharedFileTypes(), [ShareAssetType.preview, ShareAssetType.original]);
      expect(SettingsRepository.instance.appConfig.share.fileType, ShareAssetType.original);
    });

    testWidgets('offers no preview option for a video, which has none to share', (tester) async {
      await pumpShare(
        tester,
        selection: {RemoteAssetFactory.create(ownerId: context.currentUser.id, type: .video)},
      );

      final shared = invokeSecondaryAction();
      await settle(tester);

      expect(find.byIcon(Icons.high_quality_rounded), findsOneWidget);
      expect(find.byIcon(Icons.photo_size_select_large_rounded), findsNothing);

      await tester.tap(find.byIcon(Icons.high_quality_rounded));
      await settle(tester);
      await shared;
      expect(find.byIcon(Icons.photo_size_select_large_rounded), findsNothing);
    });

    testWidgets('shows progress, cancels immediately and ignores late progress safely', (tester) async {
      final pending = Completer<int>();
      late Completer<void> cancellation;
      late void Function(double) onProgress;
      when(
        () => context.repository.assetMedia.api.shareAssets(
          any(),
          any(),
          fileType: any(named: 'fileType'),
          cancelCompleter: any(named: 'cancelCompleter'),
          onAssetDownloadProgress: any(named: 'onAssetDownloadProgress'),
        ),
      ).thenAnswer((invocation) {
        cancellation = invocation.namedArguments[#cancelCompleter] as Completer<void>;
        onProgress = invocation.namedArguments[#onAssetDownloadProgress] as void Function(double);
        return pending.future;
      });
      await pumpShare(tester);
      await tester.tap(find.byType(ImmichIconButton));
      await settle(tester);
      onProgress(0.42);
      await tester.pump();
      expect(find.text('42%'), findsOneWidget);
      expect(cancellation.isCompleted, isFalse);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(cancellation.isCompleted, isTrue);
      expect(find.byType(AlertDialog), findsNothing);
      onProgress(0.9);
      pending.complete(0);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(sharedFileTypes(), [ShareAssetType.original]);
    });

    testWidgets('dialog rebuilds do not start another download', (tester) async {
      final pending = Completer<int>();
      when(
        () => context.repository.assetMedia.api.shareAssets(
          any(),
          any(),
          fileType: any(named: 'fileType'),
          cancelCompleter: any(named: 'cancelCompleter'),
          onAssetDownloadProgress: any(named: 'onAssetDownloadProgress'),
        ),
      ).thenAnswer((_) => pending.future);
      await pumpShare(tester);
      await tester.tap(find.byType(ImmichIconButton));
      await settle(tester);
      tester.view.physicalSize = const Size(1000, 1600);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pump();
      pending.complete(1);
      await settle(tester);
      expect(sharedFileTypes(), [ShareAssetType.original]);
    });

    testWidgets('server download failure closes preparing UI and reports an error', (tester) async {
      when(() => context.service.toast.error(any())).thenAnswer((_) {});
      when(
        () => context.repository.assetMedia.api.shareAssets(
          any(),
          any(),
          fileType: any(named: 'fileType'),
          cancelCompleter: any(named: 'cancelCompleter'),
          onAssetDownloadProgress: any(named: 'onAssetDownloadProgress'),
        ),
      ).thenAnswer((_) async => throw StateError('offline'));
      await tester.pumpTestWidget(
        context,
        const ActionIconButton(action: ShareAction(source: .timeline)),
        overrides: [
          ...context.selected({RemoteAssetFactory.create()}),
          toastServiceProvider.overrideWithValue(context.service.toast),
        ],
      );
      await tester.tap(find.byType(ImmichIconButton));
      await settle(tester);
      expect(find.byType(AlertDialog), findsNothing);
      verify(() => context.service.toast.error(any())).called(1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('is hidden when nothing is selected', (tester) async {
      await pumpShare(tester, selection: const {});

      expect(find.byType(ImmichIconButton), findsNothing);
    });
  });

  group('ShareLinkAction', () {
    testWidgets('offers a link for a remote asset', (tester) async {
      await tester.pumpTestWidget(
        context,
        const ActionIconButton(action: ShareLinkAction(source: .timeline)),
        overrides: context.selected({RemoteAssetFactory.create()}),
      );

      expect(find.byType(ImmichIconButton), findsOneWidget);
    });

    testWidgets('is hidden for a local-only asset', (tester) async {
      await tester.pumpTestWidget(
        context,
        const ActionIconButton(action: ShareLinkAction(source: .timeline)),
        overrides: context.selected({LocalAssetFactory.create()}),
      );

      expect(find.byType(ImmichIconButton), findsNothing);
    });
  });
}
