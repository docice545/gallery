import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/asset_edit.model.dart';
import 'package:immich_mobile/domain/models/server_capability.model.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/pages/edit/editor.provider.dart';
import 'package:immich_mobile/presentation/widgets/images/remote_image_provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/providers/websocket.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/error_handler.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';
import 'package:openapi/api.dart' show AssetMediaSize;

final _stateProvider = Provider.family.autoDispose<RemoteAsset?, ActionSource>((ref, source) {
  final isSupported = ref.watch(serverInfoProvider.select((state) => state.serverVersion.supports(.assetEdits)));
  if (!isSupported) {
    return null;
  }

  final assets = ref.watch(ownedAssetsActionProvider(source));
  // Live/Motion stills can create an AI copy. Their existing crop edit pipeline
  // remains disabled so the motion component is never silently desynchronized.
  return assets.where((asset) => asset.isEditable || (asset.isImage && asset.isMotionPhoto)).singleOrNull;
}, dependencies: [ownedAssetsActionProvider]);

class EditAssetAction extends AssetActionBuilder {
  const EditAssetAction({required super.source});

  @override
  ActionItem? create(BuildContext context, WidgetRef ref) {
    if (!ref.watch(_stateProvider(source).select((asset) => asset != null))) {
      return null;
    }

    return .new(icon: Icons.tune, label: context.t.edit, onAction: () => _edit(context, ref));
  }

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final asset = ref.read(_stateProvider(source));
    if (asset == null) {
      return;
    }

    try {
      // TODO(shenlong): Move all EXIF and Apply Edits logic onto the Route
      final repository = ref.read(driftProvider).remoteAssetRepository;
      final (edits, exif) = await (repository.getAssetEdits(asset.id), repository.getExif(asset.id)).wait;
      if (exif == null || !context.mounted) {
        return;
      }

      ref.read(editorStateProvider.notifier).init(edits, exif);
      unawaited(
        context.pushRoute(
          EditImageRoute(
            image: Image(image: getEditorImageProvider(asset)),
            applyEdits: (newEdits) => applyEdits(ref, asset.id, newEdits),
            asset: asset,
          ),
        ),
      );
    } catch (error, stack) {
      handleError(error, stack: stack, description: "Failed to open the editor for the asset");
    }
  }
}

@visibleForTesting
RemoteImageProvider getEditorImageProvider(RemoteAsset asset) => RemoteImageProvider(
  // Crop parameters still use the original EXIF dimensions. An interactive
  // preview avoids an unnecessary original download before opening the AI tool.
  url: getThumbnailUrlForRemoteId(asset.id, type: AssetMediaSize.preview, edited: false, thumbhash: asset.thumbHash),
  edited: false,
);

@visibleForTesting
Future<void> applyEdits(WidgetRef ref, String remoteId, List<AssetEdit> edits) async {
  final websocket = ref.read(websocketProvider.notifier);

  bool isCurrentId(dynamic data) => data is Map && (data['asset'] as Map?)?['id'] == remoteId;
  await ref.read(assetServiceProvider).applyEdits(remoteId, edits);
  await Future.any([
    websocket.waitForEvent('AssetEditReadyV1', isCurrentId, const .new(seconds: 10)),
    websocket.waitForEvent('AssetEditReadyV2', isCurrentId, const .new(seconds: 10)),
  ]).catchError((_) {});
}
