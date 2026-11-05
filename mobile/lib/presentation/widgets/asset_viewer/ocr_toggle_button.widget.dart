import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/action_buttons/base_action_button.widget.dart';
import 'package:immich_mobile/presentation/widgets/icons/proposal/foto_icon.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/ocr.provider.dart';

class OcrToggleButton extends ConsumerWidget {
  final BaseAsset asset;
  const OcrToggleButton({super.key, required this.asset, this.menuItem = false});
  final bool menuItem;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asset = this.asset;
    final hasOcr = asset is RemoteAsset && ref.watch(ocrAssetProvider(asset.id)).valueOrNull?.isNotEmpty == true;
    final showingOcr = ref.watch(assetViewerProvider.select((s) => s.showingOcr));

    return !hasOcr
        ? const SizedBox.shrink()
        : menuItem
        ? BaseActionButton(
            menuItem: true,
            fotoKind: FotoIconKind.ocr,
            iconData: Icons.text_snippet_outlined,
            label: context.t.ocr,
            selected: showingOcr,
            onPressed: ref.watch(assetViewerProvider.notifier).toggleOcr,
          )
        : FotoIconButton(
            kind: FotoIconKind.ocr,
            label: context.t.ocr,
            selected: showingOcr,
            onPressed: ref.watch(assetViewerProvider.notifier).toggleOcr,
          );
  }
}
