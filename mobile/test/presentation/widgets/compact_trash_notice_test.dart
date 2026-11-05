import 'dart:io';
import 'dart:ui' as ui;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/actions/action.widget.dart';
import 'package:immich_mobile/presentation/actions/delete.action.dart';
import 'package:immich_ui/immich_ui.dart' as ui_widgets;
import 'package:mocktail/mocktail.dart';

import '../../unit/factories/remote_asset_factory.dart';
import '../../unit/presentation/presentation_context.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await (FontLoader('Roboto')..addFont(rootBundle.load('fonts/GoogleSans/GoogleSans-Regular.ttf'))).load();
    await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final brightness in Brightness.values) {
    for (final count in [1, 3, 21]) {
      testWidgets('compact Russian trash notice and actual Undo $brightness count=$count', (tester) async {
        final fixture = await PresentationContext.create();
        addTearDown(fixture.dispose);
        final oldLocale = Intl.defaultLocale;
        Intl.defaultLocale = 'ru';
        addTearDown(() => Intl.defaultLocale = oldLocale);
        tester.view.physicalSize = const Size(393, 852);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final assets = List.generate(count, (_) => RemoteAssetFactory.create(ownerId: fixture.currentUser.id));
        final service = fixture.service.asset.service;
        for (final asset in assets) {
          when(() => service.getAsset(asset)).thenAnswer((_) async => asset);
        }
        when(() => service.getDeletionLocalIds(any())).thenAnswer((_) async => []);
        final boundary = GlobalKey();
        final theme = ThemeData(brightness: brightness, colorSchemeSeed: Colors.teal, fontFamily: 'Roboto');
        await tester.pumpWidget(
          EasyLocalization(
            supportedLocales: const [Locale('ru')],
            startLocale: const Locale('ru'),
            fallbackLocale: const Locale('ru'),
            path: translationsPath,
            assetLoader: const CodegenLoader(),
            child: ProviderScope(
              overrides: [...fixture.overrides, ...fixture.selected(assets.toSet())],
              child: Builder(
                builder: (context) => MaterialApp(
                  theme: theme,
                  debugShowCheckedModeBanner: false,
                  scaffoldMessengerKey: ui_widgets.scaffoldMessengerKey,
                  locale: context.locale,
                  supportedLocales: context.supportedLocales,
                  localizationsDelegates: context.localizationDelegates,
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(count == 21 ? 1.8 : 1)),
                    child: child!,
                  ),
                  home: RepaintBoundary(
                    key: boundary,
                    child: const Scaffold(
                      body: Center(
                        child: ActionIconButton(action: DeleteAction(source: .timeline)),
                      ),
                      bottomNavigationBar: SizedBox(key: Key('measured-controls'), height: 88),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byType(ui_widgets.ImmichIconButton));
        await tester.pumpAndSettle();
        final message = count == 1 ? 'Фото в корзине' : '$count фото в корзине';
        expect(find.text(message), findsOneWidget);
        expect(find.text('Отменить').hitTestable(), findsOneWidget);
        expect(find.text('Undo'), findsNothing);
        final notice = tester.widget<SnackBar>(find.byType(SnackBar));
        expect(notice.backgroundColor, theme.colorScheme.surfaceContainerHigh);
        final rect = tester.getRect(find.byType(SnackBar));
        expect(rect.height, lessThanOrEqualTo(count == 21 ? 120 : 64));
        expect(rect.bottom, lessThanOrEqualTo(tester.getRect(find.byKey(const Key('measured-controls'))).top));
        verify(() => service.trash(assets.map((a) => a.id).toList())).called(1);
        final output = Platform.environment['FOTO_TRASH_NOTICE_EVIDENCE'];
        if (output != null && count == 3) {
          await tester.runAsync(() async {
            final image = await (boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage();
            final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
            await Directory(output).create(recursive: true);
            await File('$output/${brightness.name}.png').writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.tap(find.text('Отменить'));
        await tester.pumpAndSettle();
        verify(() => service.restoreTrash(assets.map((a) => a.id).toList())).called(1);
        verifyNever(() => service.deleteWithResults(any()));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
