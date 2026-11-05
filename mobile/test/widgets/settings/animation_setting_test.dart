import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/widgets/settings/preference_settings/animation_setting.dart';
import 'package:immich_mobile/widgets/settings/preference_settings/preference_setting.dart';

import '../../test_utils.dart';
import '../../widget_tester_extensions.dart';

void main() {
  late Drift db;
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestUtils.init();
    db = Drift(drift.DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await SettingsRepository.ensureInitialized(db);
    await StoreService.init(storeRepository: StoreRepository(db), listenUpdates: false);
    await (FontLoader('Roboto')..addFont(rootBundle.load('fonts/GoogleSans/GoogleSans-Regular.ttf'))).load();
    await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  setUp(() async => SettingsRepository.instance.clear(SettingsKey.values));
  tearDownAll(() async {
    await SettingsRepository.reset();
    await db.close();
  });
  testWidgets('Animations is reachable from the Interface settings page', (tester) async {
    await tester.pumpConsumerWidget(const PreferenceSetting());
    expect(find.byType(AnimationSetting), findsOneWidget);
    expect(find.byKey(const Key('fancy-deletion-switch')), findsOneWidget);
  });
  for (final brightness in Brightness.values) {
    testWidgets('persistent live switch and readable Russian labels in $brightness', (tester) async {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final boundary = GlobalKey();
      Future<void> mount() async {
        await tester.pumpConsumerWidget(
          Theme(
            data: ThemeData(brightness: brightness, colorSchemeSeed: Colors.teal, fontFamily: 'Roboto'),
            child: RepaintBoundary(
              key: boundary,
              child: const Scaffold(body: SafeArea(child: AnimationSetting())),
            ),
          ),
        );
        final context = tester.element(find.byType(AnimationSetting));
        await EasyLocalization.of(context)!.setLocale(const Locale('ru'));
        await tester.pumpAndSettle();
      }

      await mount();
      SwitchListTile tile() => tester.widget(find.byKey(const Key('fancy-deletion-switch')));
      // The public key belongs to SwitchListTile.adaptive's actual widget.
      expect(tile().value, isTrue);
      expect(find.text('Анимации'), findsOneWidget);
      expect(find.text('Эффектное удаление'), findsOneWidget);
      final output = Platform.environment['FOTO_ANIMATION_SETTINGS_EVIDENCE'];
      for (final enabled in [false, true]) {
        await tester.tap(find.byKey(const Key('fancy-deletion-switch')));
        await tester.pumpAndSettle();
        expect(tile().value, enabled);
        expect(SettingsRepository.instance.appConfig.theme.fancyDeletion, enabled);
        if (output != null) {
          await tester.runAsync(() async {
            final image = await (boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage(
              pixelRatio: 1,
            );
            final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
            await Directory(output).create(recursive: true);
            await File('$output/${brightness.name}-$enabled.png').writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await SettingsRepository.instance.refresh();
        await mount();
        expect(tile().value, enabled, reason: 'Recreated settings read the persisted value, not widget state');
        expect(tester.takeException(), isNull);
      }
    });
  }
}
