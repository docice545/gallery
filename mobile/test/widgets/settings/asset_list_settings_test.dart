import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/widgets/settings/asset_list_settings/asset_list_settings.dart';

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
  });

  setUp(() async {
    await Store.clear();
    await SettingsRepository.instance.clear(SettingsKey.values);
  });

  tearDownAll(() async {
    await Store.clear();
    await SettingsRepository.reset();
    await db.close();
  });

  Finder autoplaySwitch() => find.ancestor(
    of: find.text(StaticTranslations.instance.theme_setting_asset_list_autoplay_live_photos_title),
    matching: find.byType(SwitchListTile),
  );

  testWidgets('offers live photo autoplay enabled by default alongside existing timeline preferences', (tester) async {
    await tester.pumpConsumerWidget(const AssetListSettings());

    expect(tester.widget<SwitchListTile>(autoplaySwitch()).value, isTrue);
    expect(find.text(StaticTranslations.instance.theme_setting_asset_list_storage_indicator_title), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
    expect(find.text(StaticTranslations.instance.asset_list_layout_settings_group_by_month_day), findsOneWidget);
  });

  testWidgets('disabling live photo autoplay persists and the switch remains off after reopening', (tester) async {
    await tester.pumpConsumerWidget(const AssetListSettings());
    await tester.tap(autoplaySwitch());
    await tester.pumpAndSettle();

    expect(SettingsRepository.instance.appConfig.timeline.autoplayLivePhotos, isFalse);
    expect(tester.widget<SwitchListTile>(autoplaySwitch()).value, isFalse);
    expect(SettingsRepository.instance.appConfig.timeline.storageIndicator, isTrue);

    await tester.pumpConsumerWidget(const SizedBox.shrink());
    await SettingsRepository.instance.refresh();
    await tester.pumpConsumerWidget(const AssetListSettings());

    expect(tester.widget<SwitchListTile>(autoplaySwitch()).value, isFalse);
  });
}
