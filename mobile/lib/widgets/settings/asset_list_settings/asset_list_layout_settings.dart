import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/config/timeline_config.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/app_settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_ui/immich_ui.dart';

class LayoutSettings extends HookConsumerWidget {
  const LayoutSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(appConfigProvider.select((s) => s.timeline));
    final tilesPerRow = useState(config.tilesPerRow.clamp(2, 5));
    useEffect(() {
      tilesPerRow.value = config.tilesPerRow.clamp(2, 5);
      return null;
    }, [config.tilesPerRow]);
    useValueChanged<int, void>(tilesPerRow.value, (_, _) {
      unawaited(ref.read(settingsProvider).write(.timelineTilesPerRow, tilesPerRow.value));
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingGroupTitle(title: context.t.asset_list_layout_sub_title, icon: Icons.view_module_outlined),
        SettingsRadioListTile(
          groups: [
            SettingsRadioGroup(title: context.t.timeline_presentation_classic, value: TimelinePresentation.classic),
            SettingsRadioGroup(title: context.t.timeline_presentation_immersive, value: TimelinePresentation.immersive),
          ],
          groupBy: config.presentation,
          onRadioChanged: (TimelinePresentation? value) {
            if (value != null) {
              unawaited(ref.read(settingsProvider).write(.timelinePresentation, value));
            }
          },
        ),
        if (config.presentation == TimelinePresentation.classic)
          SwitchListTile.adaptive(
            key: const Key('timeline-floating-date-setting'),
            title: Text(context.t.timeline_floating_date),
            value: config.floatingDate,
            onChanged: (value) => unawaited(ref.read(settingsProvider).write(.timelineFloatingDate, value)),
          ),
        SettingsSliderListTile(
          valueNotifier: tilesPerRow,
          text: context.t.theme_setting_asset_list_tiles_per_row_title(count: tilesPerRow.value),
          label: "${tilesPerRow.value}",
          maxValue: 5,
          minValue: 2,
          noDivisons: 3,
          onChangeEnd: (value) {
            ref.invalidate(appSettingsServiceProvider);
          },
        ),
      ],
    );
  }
}
