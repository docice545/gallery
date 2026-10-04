import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_stack.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/utils/error_handler.dart';

enum _Operation { create, add, remove, primary, dissolve }

class ManageStackAction extends AssetActionBuilder {
  const ManageStackAction({required super.source});

  @override
  ActionItem? create(BuildContext context, WidgetRef ref) {
    final assets = ref.watch(ownedAssetsActionProvider(source)).toList();
    if (assets.isEmpty) {
      return null;
    }
    return ActionItem(
      icon: Icons.layers_outlined,
      label: 'stack_manage'.tr(context: context),
      onAction: () => _manage(context, ref, assets),
    );
  }

  Future<void> _manage(BuildContext context, WidgetRef ref, List<RemoteAsset> assets) async {
    final single = assets.length == 1 ? assets.first : null;
    final stacked = assets.where((asset) => asset.stackId != null).toList();
    final operation = await showModalBottomSheet<_Operation>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (assets.length >= 2)
              ListTile(
                title: Text(context.t.stack),
                leading: const Icon(Icons.layers),
                onTap: () => Navigator.pop(context, _Operation.create),
              ),
            ListTile(
              title: Text('stack_add_existing'.tr(context: context)),
              leading: const Icon(Icons.add),
              onTap: () => Navigator.pop(context, _Operation.add),
            ),
            if (single?.stackId != null) ...[
              ListTile(
                title: Text('stack_remove_asset'.tr(context: context)),
                leading: const Icon(Icons.remove),
                onTap: () => Navigator.pop(context, _Operation.remove),
              ),
              ListTile(
                title: Text('stack_set_primary'.tr(context: context)),
                leading: const Icon(Icons.photo),
                onTap: () => Navigator.pop(context, _Operation.primary),
              ),
            ],
            if (stacked.isNotEmpty)
              ListTile(
                title: Text(context.t.unstack),
                leading: const Icon(Icons.layers_clear),
                onTap: () => Navigator.pop(context, _Operation.dissolve),
              ),
          ],
        ),
      ),
    );
    if (operation == null || !context.mounted) {
      return;
    }
    final service = ref.read(assetServiceProvider);
    final userId = ref.read(authUserProvider).id;
    try {
      switch (operation) {
        case _Operation.create:
          await service.stack(userId, assets.map((asset) => asset.id).toList());
        case _Operation.add:
          final stacks = (await service.getStacks())
              .where((choice) => assets.any((asset) => !choice.stack.assetIds.contains(asset.id)))
              .toList();
          if (!context.mounted) {
            return;
          }
          final primary = await showDialog<String>(
            context: context,
            builder: (context) => SimpleDialog(
              title: Text('stack_add_existing'.tr(context: context)),
              children: [
                if (stacks.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(context.t.no_results)),
                for (final choice in stacks)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(context, choice.stack.primaryAssetId),
                    child: Text('${choice.name} (${choice.stack.assetIds.length})'),
                  ),
              ],
            ),
          );
          if (primary == null) {
            return;
          }
          await service.stack(userId, {primary, ...assets.map((asset) => asset.id)}.toList());
        case _Operation.remove:
          await service.removeFromStack(userId, single!);
        case _Operation.primary:
          await service.setStackPrimary(userId, single!.stackId!, single.id);
        case _Operation.dissolve:
          await service.unstack(stacked.map((asset) => asset.stackId!).toSet().toList());
      }
      ref.invalidate(stackChildrenNotifier);
      if (!context.mounted) {
        return;
      }
      ref.read(clearSelectionProvider(source))();
      if (source == .viewer && single != null) {
        final updated = await service.getAsset(single);
        if (updated != null && context.mounted) {
          ref.read(assetViewerProvider.notifier).setAsset(updated);
        }
      }
    } catch (error, stack) {
      handleError(error, stack: stack, description: 'Failed to manage asset stack');
    }
  }
}
