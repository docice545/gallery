import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/offline_thumbnail_network.provider.dart';

/// Settings > Networking: separate from cellular BACKUP. Consent is required
/// before a potentially large thumbnail library is prefetched on mobile data.
class OfflineThumbnailNetworkSettings extends ConsumerStatefulWidget {
  const OfflineThumbnailNetworkSettings({super.key});

  @override
  ConsumerState<OfflineThumbnailNetworkSettings> createState() => _OfflineThumbnailNetworkSettingsState();
}

class _OfflineThumbnailNetworkSettingsState extends ConsumerState<OfflineThumbnailNetworkSettings> {
  bool _updating = false;

  Future<void> _change(bool useAnyNetwork) async {
    if (_updating) {
      return;
    }
    if (useAnyNetwork) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(context.t.offline_thumbnail_mobile_warning_title),
          content: Text(context.t.offline_thumbnail_mobile_warning_body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(context.t.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(context.t.offline_thumbnail_mobile_allow),
            ),
          ],
        ),
      );
      if (!mounted || accepted != true) {
        return;
      }
    }

    setState(() => _updating = true);
    try {
      await Store.put(StoreKey.offlineThumbnailAnyNetwork, useAnyNetwork);
    } finally {
      if (mounted) {
        setState(() => _updating = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final useAnyNetwork = ref.watch(offlineThumbnailAnyNetworkProvider).valueOrNull ?? false;
    return SwitchListTile.adaptive(
      value: useAnyNetwork,
      onChanged: _updating ? null : (value) => _change(value),
      title: Text(
        useAnyNetwork
            ? context.t.offline_thumbnail_any_network
            : context.t.offline_thumbnail_wifi_only,
      ),
      subtitle: Text(context.t.offline_thumbnail_network_subtitle),
      secondary: const Icon(Icons.cloud_download_outlined),
    );
  }
}
