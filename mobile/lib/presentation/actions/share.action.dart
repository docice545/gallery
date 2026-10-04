import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/toast.provider.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';

final _stateProvider = Provider.family.autoDispose<List<BaseAsset>?, ActionSource>((ref, source) {
  final assets = ref.watch(assetsActionProvider(source));
  final shareable = assets.toList(growable: false);
  return shareable.isEmpty ? null : shareable;
}, dependencies: [assetsActionProvider]);

class ShareAction extends AssetActionBuilder {
  const ShareAction({required super.source});

  @override
  ActionItem? create(BuildContext context, WidgetRef ref) {
    final assets = ref.watch(_stateProvider(source));
    if (assets == null) {
      return null;
    }

    return .new(
      icon: CurrentPlatform.isAndroid ? Icons.share_rounded : Icons.ios_share_rounded,
      label: context.t.share,
      onAction: () => _share(context, ref, assets, ref.read(appConfigProvider).share.fileType),
      onSecondaryAction: () => _promptQualityAndShare(context, ref, assets),
    );
  }

  Future<void> _promptQualityAndShare(BuildContext context, WidgetRef ref, List<BaseAsset> assets) async {
    // Only show preview option when at least one of the assets is not a video
    final showPreview = assets.any((asset) => !asset.isVideo);

    final fileType = await showDialog<ShareAssetType>(
      context: context,
      builder: (_) => _ShareFileTypeDialog(showPreview: showPreview),
      useRootNavigator: false,
    );
    if (fileType == null || !context.mounted) {
      return;
    }

    await _share(context, ref, assets, fileType);
  }

  Future<void> _share(BuildContext context, WidgetRef ref, List<BaseAsset> assets, ShareAssetType fileType) async {
    final cancelCompleter = Completer<void>();
    final progress = ValueNotifier<double?>(null);
    final mediaRepository = ref.read(assetMediaRepositoryProvider);
    final toastService = ref.read(toastServiceProvider);
    final errorMessage = context.t.scaffold_body_error_occurred;

    await showDialog(
      context: context,
      barrierDismissible: false,
      useRootNavigator: false,
      builder: (dialogContext) => _SharePreparingDialog(
        progress: progress,
        prepare: () => mediaRepository.shareAssets(
          assets,
          context,
          fileType: fileType,
          cancelCompleter: cancelCompleter,
          onAssetDownloadProgress: (value) {
            if (!cancelCompleter.isCompleted) {
              progress.value = value;
            }
          },
        ),
        onFinished: (count) {
          if (cancelCompleter.isCompleted || !dialogContext.mounted) {
            return;
          }
          if (count != assets.length) {
            unawaited(.value(toastService.error(errorMessage)));
          }
          dialogContext.pop();
        },
        onCancel: () {
          if (!cancelCompleter.isCompleted) {
            cancelCompleter.complete();
          }
          dialogContext.pop();
        },
      ),
    ).then((_) {
      if (!cancelCompleter.isCompleted) {
        cancelCompleter.complete();
      }
      progress.dispose();
    });
  }
}

class _SharePreparingDialog extends StatefulWidget {
  final ValueNotifier<double?> progress;

  final Future<int> Function() prepare;
  final void Function(int count) onFinished;
  final VoidCallback onCancel;

  const _SharePreparingDialog({
    required this.progress,
    required this.prepare,
    required this.onFinished,
    required this.onCancel,
  });

  @override
  State<_SharePreparingDialog> createState() => _SharePreparingDialogState();
}

class _SharePreparingDialogState extends State<_SharePreparingDialog> {
  @override
  void initState() {
    super.initState();
    // Start once: dialog rebuilds must never enqueue the same originals again.
    unawaited(widget.prepare().then<void>(widget.onFinished, onError: (_) => widget.onFinished(0)));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: Column(
        mainAxisSize: .min,
        children: [
          Container(margin: const .only(bottom: 12), child: Text(context.t.share_dialog_preparing)),
          SizedBox(
            width: 240,
            child: ValueListenableBuilder<double?>(
              valueListenable: widget.progress,
              builder: (context, value, _) {
                final percent = value == null ? null : (value * 100).clamp(0, 100);
                return Column(
                  mainAxisSize: .min,
                  children: [
                    LinearProgressIndicator(value: value, minHeight: 8.0),
                    if (percent != null)
                      Container(margin: const .only(top: 8), child: Text('${percent.toStringAsFixed(0)}%')),
                  ],
                );
              },
            ),
          ),
        ],
      ),
      actions: [TextButton(onPressed: widget.onCancel, child: Text(context.t.cancel))],
    );
  }
}

class _ShareFileTypeDialog extends StatelessWidget {
  final bool showPreview;

  const _ShareFileTypeDialog({this.showPreview = true});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.t.select_quality),
      contentPadding: const .symmetric(vertical: 8),
      content: Column(
        mainAxisSize: .min,
        children: [
          ListTile(
            leading: const Icon(Icons.high_quality_rounded),
            title: Text(context.t.share_original),
            onTap: () => context.pop(ShareAssetType.original),
          ),
          if (showPreview)
            ListTile(
              leading: const Icon(Icons.photo_size_select_large_rounded),
              title: Text(context.t.share_preview),
              onTap: () => context.pop(ShareAssetType.preview),
            ),
        ],
      ),
      actions: [TextButton(onPressed: () => context.pop(), child: Text(context.t.cancel))],
    );
  }
}
