import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/store.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/datetime_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/favorite.action.dart';
import 'package:immich_mobile/presentation/widgets/action_buttons/motion_photo_action_button.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_control_surface.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_kebab_menu.widget.dart';
import 'package:immich_mobile/presentation/widgets/icons/proposal/foto_icon.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset_viewer/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/current_album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/routes.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/timezone.dart';

class ViewerTopAppBar extends ConsumerWidget implements PreferredSizeWidget {
  const ViewerTopAppBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asset = ref.watch(assetViewerProvider.select((s) => s.currentAsset));
    if (asset == null) {
      return const SizedBox.shrink();
    }

    final album = ref.watch(currentRemoteAlbumProvider);
    final isInTrash = ref.watch(timelineServiceProvider.select((service) => service.origin == TimelineOrigin.trash));

    final isInLockedView = ref.watch(inLockedViewProvider);
    final isReadonlyModeEnabled = ref.watch(readonlyModeProvider);

    final showingDetails = ref.watch(assetViewerProvider.select((state) => state.showingDetails));

    if (!isInTrash && album != null && album.isActivityEnabled && album.isShared && asset is RemoteAsset) {
      ref.watch(Store.activity.list(album.id, assetId: asset.id));
    }

    final showingControls = ref.watch(assetViewerProvider.select((s) => s.showingControls));
    final double opacity =
        ref.watch(assetViewerProvider.select((s) => s.backgroundOpacity)) * (showingControls ? 1 : 0);

    final originalTheme = context.themeData;

    final actions = isInTrash
        ? <Widget>[]
        : <Widget>[
            if (asset.isMotionPhoto) const MotionPhotoActionButton(iconOnly: true),
            if (album != null && album.isActivityEnabled && album.isShared)
              FotoIconButton(
                kind: FotoIconKind.comments,
                label: context.t.comments_and_likes,
                onPressed: () {
                  unawaited(
                    context.router.push(
                      ActivitiesRoute(
                        album: album,
                        assetId: asset is RemoteAsset ? asset.id : null,
                        assetName: asset.name,
                      ),
                    ),
                  );
                },
              ),

            if ((const FavoriteAction(source: .viewer)).create(context, ref) case final item?)
              FotoIconButton(
                kind: FotoIconKind.favorite,
                label: item.label,
                selected: asset.isFavorite,
                onPressed: item.onAction,
              ),
            ViewerKebabMenu(originalTheme: originalTheme),
          ];

    final lockedViewActions = <Widget>[ViewerKebabMenu(originalTheme: originalTheme)];

    return IgnorePointer(
      ignoring: opacity < 1.0,
      child: AnimatedOpacity(
        opacity: opacity,
        duration: Durations.short2,
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            child: _CompactViewerToolbar(
              asset: asset,
              showTitle: !showingDetails,
              actions: !isInTrash && !showingDetails && !isReadonlyModeEnabled
                  ? (isInLockedView ? lockedViewActions : actions)
                  : const [],
            ),
          ),
        ),
      ),
    );
  }

  @override
  // A loose maximum for the accessible two-row variant. The normal toolbar
  // sizes to 48dp with a 44dp painted capsule, including 48dp hit targets.
  Size get preferredSize => const Size.fromHeight(112.0);
}

class _AppBarBackButton extends ConsumerWidget {
  const _AppBarBackButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FotoIconButton(kind: FotoIconKind.back, label: context.t.back, onPressed: context.maybePop);
  }
}

class _CompactViewerToolbar extends ConsumerWidget {
  const _CompactViewerToolbar({required this.asset, required this.actions, required this.showTitle});
  final BaseAsset asset;
  final List<Widget> actions;
  final bool showTitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final exifInfo = ref.watch(assetExifProvider(asset)).valueOrNull;
    final (dateTime, _) = resolveAssetDateTime(asset, exifInfo);
    final date = DateFormat.MMMd(context.locale.toString()).format(dateTime);
    final time = dateTime.formatTime(alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context));
    final text = '$date · $time';
    final style = context.textTheme.labelMedium?.copyWith(fontSize: 12, color: Theme.of(context).colorScheme.onSurface);
    return LayoutBuilder(
      builder: (context, constraints) {
        final measure = TextPainter(
          text: TextSpan(text: text, style: style),
          textScaler: MediaQuery.textScalerOf(context),
          textDirection: Directionality.of(context),
        )..layout();
        final stacked = showTitle && measure.width + 8 > constraints.maxWidth - 48 * (actions.length + 1);
        measure.dispose();
        final title = Text(
          text,
          key: const ValueKey('viewer-compact-date-time'),
          semanticsLabel: '${dateTime.formatDate()} $time',
          textAlign: TextAlign.center,
          style: style,
        );
        return ViewerControlSurface(
          pill: true,
          visualHeight: stacked ? null : 44,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 48,
                child: NavigationToolbar(
                  centerMiddle: true,
                  middleSpacing: 4,
                  leading: const _AppBarBackButton(),
                  middle: showTitle && !stacked ? title : null,
                  trailing: actions.isEmpty ? null : Row(mainAxisSize: MainAxisSize.min, children: actions),
                ),
              ),
              if (stacked) Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 6), child: title),
            ],
          ),
        );
      },
    );
  }
}
