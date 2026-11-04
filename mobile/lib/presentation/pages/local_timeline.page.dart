import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/delete.action.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/local_album_bottom_sheet.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_route_scope.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/widgets/common/mesmerizing_sliver_app_bar.dart';

@RoutePage()
class LocalTimelinePage extends StatelessWidget {
  final LocalAlbum album;

  const LocalTimelinePage({super.key, required this.album});

  static const timelineOverviewControlsEnabled = true;

  @override
  Widget build(BuildContext context) {
    return TimelineRouteScope(
      timelineServiceBuilder: (ref, scope, groupBy) =>
          ref.watch(timelineFactoryProvider).localAlbum(albumId: album.id, groupBy: groupBy, temporalScope: scope),
      child: Timeline(
        withGroupingPill: true,
        appBar: MesmerizingSliverAppBar(
          title: album.name,
          actions: [_LocalAlbumMenu(albumId: album.id, albumName: album.name, isShared: album.isIosSharedAlbum)],
        ),
        bottomSheet: const LocalAlbumBottomSheet(),
        showStorageIndicator: true,
      ),
    );
  }
}

class _LocalAlbumMenu extends ConsumerWidget {
  const _LocalAlbumMenu({required this.albumId, required this.albumName, required this.isShared});

  final String albumId;
  final String albumName;
  final bool isShared;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final action = CleanupLocalAlbumAction(
      albumId: albumId,
      albumName: albumName,
      isShared: isShared,
    ).create(context, ref);
    return PopupMenuButton<int>(
      tooltip: context.t.more,
      onSelected: (_) => action.onAction(),
      itemBuilder: (_) => [PopupMenuItem(value: 0, child: Text(action.label))],
    );
  }
}
