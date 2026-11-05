import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/toast.provider.dart';
import 'package:immich_ui/immich_ui.dart';

class AnimationSetting extends ConsumerStatefulWidget {
  const AnimationSetting({super.key});

  @override
  ConsumerState<AnimationSetting> createState() => _AnimationSettingState();
}

class _AnimationSettingState extends ConsumerState<AnimationSetting> {
  bool _saving = false;

  Future<void> _setEnabled(bool enabled) async {
    if (_saving) {
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(settingsProvider).write(.animationFancyDeletion, enabled);
    } catch (_) {
      if (mounted) {
        ref.read(toastServiceProvider).error(context.t.error);
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SettingGroupTitle(title: context.t.animation_settings_title, icon: Icons.animation_outlined),
      SwitchListTile.adaptive(
        key: const Key('fancy-deletion-switch'),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20),
        dense: true,
        value: ref.watch(fancyDeletionEnabledProvider),
        onChanged: _saving ? null : _setEnabled,
        title: Text(context.t.fancy_deletion_title),
        subtitle: Text(context.t.fancy_deletion_description),
      ),
    ],
  );
}
