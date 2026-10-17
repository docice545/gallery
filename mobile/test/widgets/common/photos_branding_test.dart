import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/utils/app_asset_loader.dart';
import 'package:immich_mobile/widgets/common/app_logo_with_text.dart';
import 'package:immich_mobile/widgets/common/immich_title_text.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (_) async => <String, Object>{},
    );
    await EasyLocalization.ensureInitialized();
    EasyLocalization.logger.enableBuildModes = [];
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      null,
    );
  });

  test('only known mobile product prose is changed, including post-release branding', () {
    final original = {
      'welcome_to_immich': 'Welcome to Noodle Gallery',
      'open_in_immich_title': 'Open in Immich',
      'open_in_immich_body': 'Open Gallery at https://immich.app or app.immich://',
      'manage_media_access_subtitle': 'Use the default gallery with Noodle Gallery',
      'technical_value': 'Noodle Gallery de.opennoodle.gallery',
    };
    final branded = AppAssetLoader.brandTranslations(original, appName: 'Photos');
    expect(branded['welcome_to_immich'], 'Welcome to Photos');
    expect(branded['open_in_immich_title'], 'Open in Photos');
    expect(branded['open_in_immich_body'], 'Open Photos at https://immich.app or app.immich://');
    expect(branded['manage_media_access_subtitle'], 'Use the default gallery with Photos');
    expect(branded['technical_value'], original['technical_value']);
    expect(original['welcome_to_immich'], 'Welcome to Noodle Gallery');
  });

  test('Russian uses its localized product name and other locales fall back to Photos', () async {
    const loader = AppAssetLoader();
    expect((await loader.load('', const Locale('ru')))!['app_name'], 'Фото');
    for (final locale in [
      const Locale('en'),
      const Locale('de'),
      const Locale('fr'),
      const Locale('it'),
      const Locale('nl'),
      const Locale('pl'),
      const Locale('es'),
      const Locale('zh', 'Hans'),
      const Locale('zh', 'Hant'),
      const Locale('ja'),
    ]) {
      expect((await loader.load('', locale))!['app_name'], 'Photos');
    }
  });

  for (final (locale, name) in [(const Locale('ru'), 'Фото'), (const Locale('en'), 'Photos')]) {
    testWidgets('login/start, app title, timeline logo and license page use $name', (tester) async {
      await tester.pumpWidget(
        EasyLocalization(
          supportedLocales: const [Locale('en'), Locale('ru')],
          startLocale: locale,
          fallbackLocale: const Locale('en'),
          path: '../i18n',
          assetLoader: const AppAssetLoader(),
          saveLocale: false,
          child: Builder(
            builder: (context) => MaterialApp(
              onGenerateTitle: (appContext) => appContext.t.app_name,
              locale: context.locale,
              supportedLocales: context.supportedLocales,
              localizationsDelegates: context.localizationDelegates,
              home: Scaffold(
                body: Column(
                  children: [
                    const ImmichTitleText(),
                    const AppLogoWithText(),
                    Builder(
                      builder: (context) => TextButton(
                        onPressed: () => showLicensePage(context: context, applicationName: context.t.app_name),
                        child: const Text('Licenses'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.onGenerateTitle!(tester.element(find.byType(ImmichTitleText))), name);
      expect(find.text(name), findsNWidgets(2));
      expect(find.text('Noodle Gallery'), findsNothing);
      await tester.tap(find.text('Licenses'));
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byType(LicensePage), matching: find.text(name)), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
