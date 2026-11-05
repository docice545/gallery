import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';

/// Lens has no documented public image-launch contract. Use Android's public
/// image Sharesheet contract through the existing, narrowly scoped FileProvider.
/// Google/Lens appears only when the installed app accepts this image type.
class GoogleLensAction extends ActionBuilder {
  final BaseAsset asset;
  final BuildContext? viewerContext;

  const GoogleLensAction({required this.asset, this.viewerContext});

  @override
  ActionItem? create(BuildContext context, WidgetRef ref) {
    if (!CurrentPlatform.isAndroid || !asset.isImage || (asset is RemoteAsset && (asset as RemoteAsset).isTrashed)) {
      return null;
    }
    return ActionItem(
      icon: Icons.image_search_outlined,
      label: context.t.google_lens,
      onAction: () {
        // Opening a menu item disposes its own context. Keep the viewer's host
        // and repository before the menu closes; never read its ref after await.
        final host = viewerContext ?? context;
        final repository = ref.read(assetMediaRepositoryProvider);
        return showDialog<void>(
          context: host,
          useRootNavigator: false,
          builder: (_) => _GoogleLensDialog(asset: asset, repository: repository),
        );
      },
    );
  }
}

class _GoogleLensDialog extends StatefulWidget {
  final BaseAsset asset;
  final AssetMediaRepository repository;

  const _GoogleLensDialog({required this.asset, required this.repository});

  @override
  State<_GoogleLensDialog> createState() => _GoogleLensDialogState();
}

class _GoogleLensDialogState extends State<_GoogleLensDialog> {
  Completer<void>? _cancellation;
  bool _preparing = false;
  bool _failed = false;
  double? _progress;

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }

  void _cancel() {
    final cancellation = _cancellation;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
  }

  Future<void> _chooseApp() async {
    if (_preparing) {
      return;
    }
    final cancellation = Completer<void>();
    _cancellation = cancellation;
    setState(() {
      _preparing = true;
      _failed = false;
      _progress = null;
    });
    try {
      final shared = await widget.repository.shareAssets(
        [widget.asset],
        context,
        // Use an available device copy first. Cloud-only images use the
        // existing JPEG preview download/cache, never a Google-facing backend.
        fileType: widget.asset.hasLocal ? ShareAssetType.original : ShareAssetType.preview,
        livePhotoMode: LivePhotoShareMode.imageOnly,
        cancelCompleter: cancellation,
        onAssetDownloadProgress: (value) {
          if (mounted && !cancellation.isCompleted) {
            setState(() => _progress = value.clamp(0, 1));
          }
        },
      );
      if (!mounted || cancellation.isCompleted) {
        return;
      }
      if (shared == 1) {
        // Launch is not proof of a Lens search. Android owns target selection
        // and Back returns to the unchanged viewer. Retain the share cache.
        Navigator.of(context).pop();
        return;
      }
    } catch (_) {
      // Includes missing native activity, unavailable files and chooser errors.
      // Keep a retry/close path without leaving the viewer or claiming success.
    }
    if (mounted && !cancellation.isCompleted) {
      setState(() {
        _preparing = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<void>(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          _cancel();
        }
      },
      child: AlertDialog(
        title: Text(context.t.google_lens),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.t.google_lens_share_help),
            if (_preparing) ...[
              const SizedBox(height: 16),
              Text(context.t.share_dialog_preparing),
              const SizedBox(height: 8),
              LinearProgressIndicator(value: _progress),
            ],
            if (_failed) ...[
              const SizedBox(height: 16),
              Semantics(liveRegion: true, child: Text(context.t.google_lens_share_failed)),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              _cancel();
              Navigator.of(context).pop();
            },
            child: Text(context.t.cancel),
          ),
          FilledButton(
            onPressed: _preparing ? null : _chooseApp,
            child: Text(_failed ? context.t.retry : context.t.google_lens_choose_app, textAlign: TextAlign.center),
          ),
        ],
      ),
    );
  }
}
