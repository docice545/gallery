import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/theme_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/pages/common/large_leading_tile.dart';
import 'package:immich_mobile/presentation/actions/delete.action.dart';
import 'package:immich_mobile/presentation/widgets/album/album_trash_reveal.dart';
import 'package:immich_mobile/presentation/widgets/album/animated_album_rows.dart';
import 'package:immich_mobile/presentation/widgets/deletion/ghost_trap.dart';
import 'package:immich_mobile/presentation/widgets/images/local_album_thumbnail.widget.dart';
import 'package:immich_mobile/providers/haptic_feedback.provider.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/widgets/common/local_album_sliver_app_bar.dart';
import 'package:sliver_tools/sliver_tools.dart';

@RoutePage()
class LocalAlbumsPage extends StatelessWidget {
  const LocalAlbumsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: CustomScrollView(slivers: [LocalAlbumsSliverAppBar(), _AlbumList()]));
  }
}

class _AlbumList extends ConsumerWidget {
  const _AlbumList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albums = ref.watch(localAlbumProvider);
    final held = ref.watch(albumDeletionHoldsProvider);

    return albums.when(
      loading: () => const SliverToBoxAdapter(
        child: Center(
          child: Padding(padding: EdgeInsets.all(20.0), child: CircularProgressIndicator()),
        ),
      ),
      error: (error, stack) => SliverToBoxAdapter(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Text(
              'Error loading albums: $error, stack: $stack',
              style: TextStyle(color: context.colorScheme.error),
            ),
          ),
        ),
      ),
      data: (albums) {
        return MultiSliver(
          children: [
            SliverPadding(
              padding: const EdgeInsets.all(18.0),
              sliver: AnimatedAlbumRows<LocalAlbum>(
                items: albums,
                keyOf: (album) => ghostAlbumKey('local', album.id),
                heldKeys: held,
                builder: (_, album) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8.0),
                    child: AlbumTrashReveal(
                      key: ValueKey('local-album-${album.id}'),
                      onReveal: () => ref.read(hapticFeedbackProvider.notifier).selectionClick(),
                      ghostKey: ghostAlbumKey('local', album.id),
                      onTrash: () async => CleanupLocalAlbumAction(
                        albumId: album.id,
                        albumName: album.name,
                      ).create(context, ref).onAction(),
                      child: LargeLeadingTile(
                        leadingPadding: const EdgeInsets.only(right: 16),
                        leading: SizedBox(width: 80, height: 80, child: LocalAlbumThumbnail(albumId: album.id)),
                        title: Text(
                          album.name,
                          style: context.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          context.t.items_count(count: album.assetCount),
                          style: context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceSecondary),
                        ),
                        onTap: () => context.pushRoute(LocalTimelineRoute(album: album)),
                      ),
                    ),
                  );
                },
              ),
            ),
            if (albums.isEmpty && held.isEmpty)
              SliverToBoxAdapter(
                child: Center(
                  child: Padding(padding: const EdgeInsets.all(20), child: Text(context.t.no_albums_yet)),
                ),
              ),
          ],
        );
      },
    );
  }
}
