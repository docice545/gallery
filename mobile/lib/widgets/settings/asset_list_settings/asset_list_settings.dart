import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/app_settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/widgets/settings/asset_list_settings/asset_list_group_settings.dart';
import 'package:immich_mobile/widgets/settings/asset_list_settings/asset_list_layout_settings.dart';
import 'package:immich_ui/immich_ui.dart';

class AssetListSettings extends HookConsumerWidget {
  const AssetListSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storageIndicator = useValueNotifier(ref.watch(appConfigProvider.select((s) => s.timeline.storageIndicator)));
    final autoplayLivePhotos = useValueNotifier(
      ref.watch(appConfigProvider.select((s) => s.timeline.autoplayLivePhotos)),
    );

    final assetListSetting = [
      SettingsSwitchListTile(
        valueNotifier: storageIndicator,
        title: context.t.theme_setting_asset_list_storage_indicator_title,
        onChanged: (value) {
          unawaited(ref.read(settingsProvider).write(.timelineStorageIndicator, value));
          ref.invalidate(appSettingsServiceProvider);
          ref.invalidate(settingsProvider);
        },
      ),
      SettingsSwitchListTile(
        valueNotifier: autoplayLivePhotos,
        title: context.t.theme_setting_asset_list_autoplay_live_photos_title,
        onChanged: (value) {
          unawaited(ref.read(settingsProvider).write(.timelineAutoplayLivePhotos, value));
        },
      ),
      const LayoutSettings(),
      const GroupSettings(),
    ];

    return SettingsSubPageScaffold(settings: assetListSetting, showDivider: true);
  }
}
