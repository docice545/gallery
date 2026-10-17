import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/library_card.model.dart';
import 'package:immich_mobile/domain/models/person.model.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/extensions/asyncvalue_extensions.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/images/local_album_thumbnail.widget.dart';
import 'package:immich_mobile/presentation/widgets/images/remote_image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail.widget.dart';
import 'package:immich_mobile/presentation/widgets/people/partner_user_avatar.widget.dart';
import 'package:immich_mobile/providers/gallery_nav/bottom_nav_height.provider.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/memory.provider.dart';
import 'package:immich_mobile/providers/infrastructure/people.provider.dart';
import 'package:immich_mobile/providers/infrastructure/user.provider.dart';
import 'package:immich_mobile/providers/library/library_album_preview.provider.dart';
import 'package:immich_mobile/providers/library/library_layout.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/providers/shared_space.provider.dart';
import 'package:immich_mobile/providers/sync_status.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';
import 'package:immich_mobile/widgets/common/immich_sliver_app_bar.dart';
import 'package:immich_mobile/widgets/common/immich_toast.dart';
import 'package:immich_mobile/widgets/map/map_thumbnail.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

@RoutePage()
class LibraryPage extends ConsumerWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final navHeight = ref.watch(bottomNavHeightProvider);
    final cards = ref.watch(libraryCardsProvider);
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          ImmichSliverAppBar(
            snap: false,
            floating: false,
            pinned: true,
            showUploadButton: false,
            actions: [
              IconButton(
                key: const Key('library-customize'),
                tooltip: context.t.library_customize,
                icon: const Icon(Icons.tune_rounded),
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  useSafeArea: true,
                  builder: (_) => const LibraryCustomizationSheet(),
                ),
              ),
            ],
          ),
          const LibraryCardsSliver(),
          if (cards.any((card) => card.action == LibraryCardAction.partners))
            const SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverToBoxAdapter(child: _VisiblePartnerList()),
            ),
          SliverToBoxAdapter(child: SizedBox(height: navHeight + 16)),
        ],
      ),
    );
  }
}

/// Every registry action has one destination. Shared by the cards and route
/// regression tests; no global Photos filters are changed by these shortcuts.
@visibleForTesting
PageRouteInfo libraryCardRoute(LibraryCardAction action) => switch (action) {
  LibraryCardAction.favorites => const FavoriteRoute(),
  LibraryCardAction.archive => const ArchiveRoute(),
  LibraryCardAction.sharedLinks => const SharedLinkRoute(),
  LibraryCardAction.trash => const TrashRoute(),
  LibraryCardAction.spaces => const SpacesRoute(),
  LibraryCardAction.people => const PeopleCollectionRoute(),
  LibraryCardAction.places => PlaceRoute(currentLocation: null),
  LibraryCardAction.onDevice => const LocalAlbumsRoute(),
  LibraryCardAction.albums => const AlbumsRoute(),
  LibraryCardAction.memories => const MemoryListRoute(),
  LibraryCardAction.folders => FolderRoute(),
  LibraryCardAction.lockedFolder => const LockedFolderRoute(),
  LibraryCardAction.partners => const PartnerRoute(),
  LibraryCardAction.recentlyAdded => const RecentlyAddedRoute(),
  LibraryCardAction.videos => const VideoRoute(),
  LibraryCardAction.livePhotos => const LivePhotosRoute(),
};

/// Pack consecutive presentation types into rows in the exact user order.
/// Hidden/unavailable entries have already been filtered; a partial final row
/// expands to fill its width instead of reserving slots for missing cards.
@visibleForTesting
List<List<LibraryCardDescriptor>> libraryCardRows(List<LibraryCardDescriptor> cards, int columns) {
  assert(columns > 0);
  final rows = <List<LibraryCardDescriptor>>[];
  for (final card in cards) {
    if (rows.isEmpty || rows.last.length == columns || rows.last.first.presentation != card.presentation) {
      rows.add([]);
    }
    rows.last.add(card);
  }
  return rows;
}

@visibleForTesting
class LibraryCardsSliver extends ConsumerWidget {
  const LibraryCardsSliver({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cards = ref.watch(libraryCardsProvider);
    if (cards.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Padding(padding: const EdgeInsets.all(24), child: Text(context.t.library_empty)),
        ),
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) {
          final rows = libraryCardRows(cards, constraints.crossAxisExtent > 600 ? 4 : 2);
          return SliverList.builder(
            itemCount: rows.length,
            itemBuilder: (context, index) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < rows[index].length; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    Expanded(child: _LibraryCard(card: rows[index][i])),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _LibraryCard extends StatelessWidget {
  final LibraryCardDescriptor card;
  const _LibraryCard({required this.card});

  @override
  Widget build(BuildContext context) => KeyedSubtree(
    key: ValueKey('library-card-${card.id}'),
    child: switch (card.previewKind) {
      LibraryCardPreviewKind.spaces => const _SpacesCollectionCard(),
      LibraryCardPreviewKind.people => const _PeopleCollectionCard(),
      LibraryCardPreviewKind.places => const _PlacesCollectionCard(),
      LibraryCardPreviewKind.onDevice => const _LocalAlbumsCollectionCard(),
      LibraryCardPreviewKind.albums => const AlbumsCollectionCard(),
      LibraryCardPreviewKind.memories => const _MemoriesCollectionCard(),
      null => FilledButton.icon(
        onPressed: () => context.pushRoute(libraryCardRoute(card.action)),
        label: Text(card.titleKey.tr(), style: TextStyle(color: context.colorScheme.onSurface, fontSize: 15)),
        style: FilledButton.styleFrom(
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          backgroundColor: context.colorScheme.surfaceContainerLow,
          alignment: Alignment.centerLeft,
          shape: RoundedRectangleBorder(
            borderRadius: const BorderRadius.all(Radius.circular(25)),
            side: BorderSide(color: context.colorScheme.onSurface.withAlpha(10), width: 1),
          ),
        ),
        icon: Icon(card.icon, color: context.primaryColor),
      ),
    },
  );
}

/// Hidden and unavailable cards remain in the editor, so hiding a destination
/// is always reversible. Availability does not overwrite the user's choice.
@visibleForTesting
class LibraryCustomizationSheet extends ConsumerWidget {
  const LibraryCustomizationSheet({super.key});

  Future<void> _save(BuildContext context, Future<void> operation) async {
    try {
      await operation;
    } catch (_) {
      if (context.mounted) {
        ImmichToast.show(context: context, msg: context.t.library_save_failed, toastType: ToastType.error);
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final layout = ref.watch(libraryLayoutProvider);
    final features = ref.watch(serverInfoProvider.select((state) => state.serverFeatures));
    final cards = layout.orderedCards();
    final notifier = ref.read(libraryLayoutProvider.notifier);
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * .85,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                Expanded(child: Text(context.t.library_customize, style: context.textTheme.titleLarge)),
                IconButton(
                  tooltip: context.t.close,
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Expanded(
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              itemCount: cards.length,
              onReorderItem: (oldIndex, newIndex) =>
                  _save(context, notifier.reorder(oldIndex, newIndex > oldIndex ? newIndex + 1 : newIndex)),
              itemBuilder: (context, index) {
                final card = cards[index];
                final available = card.isAvailable(trashAvailable: features.trash, mapAvailable: features.map);
                return ListTile(
                  key: ValueKey('library-setting-${card.id}'),
                  leading: Icon(card.icon),
                  title: Text(card.titleKey.tr()),
                  subtitle: available ? null : Text(context.t.library_unavailable),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Switch(
                        key: ValueKey('library-visible-${card.id}'),
                        value: layout.isVisible(card.id),
                        onChanged: (visible) => _save(context, notifier.setVisible(card.id, visible)),
                      ),
                      ReorderableDragStartListener(
                        index: index,
                        child: Semantics(
                          label: card.titleKey.tr(),
                          child: const Padding(padding: EdgeInsets.all(12), child: Icon(Icons.drag_handle)),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: TextButton.icon(
                key: const Key('library-reset'),
                onPressed: () => _save(context, notifier.resetDefaults()),
                icon: const Icon(Icons.restart_alt),
                label: Text(context.t.library_reset_defaults),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SpacesCollectionCard extends ConsumerWidget {
  const _SpacesCollectionCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spacesAsync = ref.watch(sharedSpacesProvider);

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.maxWidth.isFinite ? constraints.maxWidth : context.width * .5 - 20;
        final previewHeight = size.clamp(0.0, 224.0);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => context.pushRoute(libraryCardRoute(LibraryCardAction.spaces)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: previewHeight,
                width: size,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: const BorderRadius.all(Radius.circular(20)),
                    gradient: LinearGradient(
                      colors: [context.colorScheme.primary.withAlpha(30), context.colorScheme.primary.withAlpha(25)],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                  ),
                  child: spacesAsync.widgetWhen(
                    onLoading: () => const Center(child: CircularProgressIndicator()),
                    onData: (spaces) {
                      if (spaces.isEmpty) {
                        return Center(
                          child: Icon(Icons.workspaces_outlined, size: 48, color: context.colorScheme.primary),
                        );
                      }
                      return GridView.count(
                        crossAxisCount: 2,
                        padding: const EdgeInsets.all(12),
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                        physics: const NeverScrollableScrollPhysics(),
                        children: spaces.take(4).map((space) {
                          final thumbnailId = space.thumbnailAssetId.value;
                          if (thumbnailId == null) {
                            return DecoratedBox(
                              decoration: BoxDecoration(
                                color: context.colorScheme.surfaceContainerHigh,
                                borderRadius: const BorderRadius.all(Radius.circular(10)),
                              ),
                              child: Icon(Icons.workspaces_outlined, color: context.colorScheme.primary),
                            );
                          }
                          return ClipRRect(
                            borderRadius: const BorderRadius.all(Radius.circular(10)),
                            child: Image(
                              image: RemoteImageProvider(url: getThumbnailUrlForRemoteId(thumbnailId)),
                              fit: BoxFit.cover,
                            ),
                          );
                        }).toList(),
                      );
                    },
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text(
                  context.t.spaces,
                  style: context.textTheme.titleSmall?.copyWith(
                    color: context.colorScheme.onSurface,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PeopleCollectionCard extends ConsumerWidget {
  const _PeopleCollectionCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final people = ref.watch(getAllPeopleProvider(PeopleSortBy.photoCount));

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.maxWidth.isFinite ? constraints.maxWidth : context.width * .5 - 20;
        final previewHeight = size.clamp(0.0, 224.0);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => context.pushRoute(libraryCardRoute(LibraryCardAction.people)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: previewHeight,
                width: size,
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.all(Radius.circular(20)),
                  gradient: LinearGradient(
                    colors: [context.colorScheme.primary.withAlpha(30), context.colorScheme.primary.withAlpha(25)],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
                child: people.widgetWhen(
                  onLoading: () => const Center(child: CircularProgressIndicator()),
                  onData: (people) {
                    return GridView.count(
                      crossAxisCount: 2,
                      padding: const EdgeInsets.all(12),
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                      physics: const NeverScrollableScrollPhysics(),
                      children: people.take(4).map((person) {
                        return CircleAvatar(
                          backgroundImage: RemoteImageProvider(
                            url: getFaceThumbnailUrl(person.id, updatedAt: person.updatedAt),
                          ),
                        );
                      }).toList(),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text(
                  context.t.people,
                  style: context.textTheme.titleSmall?.copyWith(
                    color: context.colorScheme.onSurface,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PlacesCollectionCard extends StatelessWidget {
  const _PlacesCollectionCard();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.maxWidth.isFinite ? constraints.maxWidth : context.width * .5 - 20;
        final previewHeight = size.clamp(0.0, 224.0);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => context.pushRoute(libraryCardRoute(LibraryCardAction.places)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: previewHeight,
                width: size,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: const BorderRadius.all(Radius.circular(20)),
                    color: context.colorScheme.secondaryContainer.withAlpha(100),
                  ),
                  child: IgnorePointer(
                    child: MapThumbnail(
                      zoom: 8,
                      centre: const LatLng(21.44950, -157.91959),
                      showAttribution: false,
                      themeMode: context.isDarkTheme ? ThemeMode.dark : ThemeMode.light,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text(
                  context.t.places,
                  style: context.textTheme.titleSmall?.copyWith(
                    color: context.colorScheme.onSurface,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _LocalAlbumsCollectionCard extends ConsumerWidget {
  const _LocalAlbumsCollectionCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albums = ref.watch(localAlbumProvider);

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.maxWidth.isFinite ? constraints.maxWidth : context.width * .5 - 20;
        final previewHeight = size.clamp(0.0, 224.0);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => context.pushRoute(libraryCardRoute(LibraryCardAction.onDevice)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: previewHeight,
                width: size,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: const BorderRadius.all(Radius.circular(20)),
                    gradient: LinearGradient(
                      colors: [context.colorScheme.primary.withAlpha(30), context.colorScheme.primary.withAlpha(25)],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                  ),
                  child: GridView.count(
                    crossAxisCount: 2,
                    padding: const EdgeInsets.all(12),
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    physics: const NeverScrollableScrollPhysics(),
                    children: albums.when(
                      data: (data) {
                        return data.take(4).map((album) {
                          return LocalAlbumThumbnail(albumId: album.id);
                        }).toList();
                      },
                      error: (error, _) {
                        return [Center(child: Text(context.t.error_saving_image(error: error.toString())))];
                      },
                      loading: () {
                        return [const Center(child: CircularProgressIndicator())];
                      },
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text(
                  context.t.on_this_device,
                  style: context.textTheme.titleSmall?.copyWith(
                    color: context.colorScheme.onSurface,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MemoriesCollectionCard extends ConsumerWidget {
  const _MemoriesCollectionCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final memories = ref.watch(visibleAllMemoriesProvider(false));

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.maxWidth.isFinite ? constraints.maxWidth : context.width * .5 - 20;
        final previewHeight = size.clamp(0.0, 224.0);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => context.pushRoute(libraryCardRoute(LibraryCardAction.memories)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: previewHeight,
                width: size,
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.all(Radius.circular(20)),
                  gradient: LinearGradient(
                    colors: [context.colorScheme.primary.withAlpha(30), context.colorScheme.primary.withAlpha(25)],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
                child: memories.widgetWhen(
                  onLoading: () => const Center(child: CircularProgressIndicator()),
                  onData: (memories) {
                    return GridView.count(
                      crossAxisCount: 2,
                      padding: const EdgeInsets.all(12),
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                      physics: const NeverScrollableScrollPhysics(),
                      children: memories.where((memory) => memory.assets.isNotEmpty).take(4).map((memory) {
                        return ClipRRect(
                          borderRadius: const BorderRadius.all(Radius.circular(10)),
                          child: Thumbnail.remote(
                            remoteId: memory.assets[0].id,
                            thumbhash: memory.assets[0].thumbHash ?? "",
                            fit: BoxFit.cover,
                          ),
                        );
                      }).toList(),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text(
                  context.t.memories,
                  style: context.textTheme.titleSmall?.copyWith(
                    color: context.colorScheme.onSurface,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

@visibleForTesting
final sharedWithPartnerProvider = StreamProvider.autoDispose<Iterable<Partner>>((ref) {
  final currentUser = ref.watch(currentUserProvider);
  if (currentUser == null) {
    // TODO: Refactor with a route guard to avoid this check in every provider
    return const .empty();
  }

  return ref.watch(partnerServiceProvider).search(currentUser.id, .sharedWith);
});

/// Public Library Albums preview used by the route regression test.
@visibleForTesting
class AlbumsCollectionCard extends ConsumerWidget {
  const AlbumsCollectionCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final previews = ref.watch(libraryAlbumPreviewProvider);
    final syncing = ref.watch(syncStatusProvider.select((state) => state.isRemoteSyncing));

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.maxWidth.isFinite ? constraints.maxWidth : context.width * .5 - 20;
        final previewHeight = size.clamp(0.0, 224.0);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          key: const Key('library-albums-card'),
          onTap: () => context.pushRoute(libraryCardRoute(LibraryCardAction.albums)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: previewHeight,
                width: size,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: const BorderRadius.all(Radius.circular(20)),
                    gradient: LinearGradient(
                      colors: [context.colorScheme.primary.withAlpha(30), context.colorScheme.primary.withAlpha(25)],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                  ),
                  child: previews.when(
                    skipLoadingOnRefresh: false,
                    skipLoadingOnReload: false,
                    loading: () => const Center(key: Key('library-albums-loading'), child: CircularProgressIndicator()),
                    error: (_, _) => Center(
                      key: const Key('library-albums-error'),
                      child: IconButton(
                        tooltip: context.t.retry,
                        icon: const Icon(Icons.refresh),
                        onPressed: () => ref.invalidate(libraryAlbumPreviewProvider),
                      ),
                    ),
                    data: (albums) {
                      if (albums.isEmpty) {
                        if (syncing) {
                          return const Center(key: Key('library-albums-loading'), child: CircularProgressIndicator());
                        }
                        return Center(
                          key: const Key('library-albums-empty'),
                          child: Icon(Icons.photo_album_outlined, size: 48, color: context.colorScheme.primary),
                        );
                      }
                      return GridView.count(
                        key: const Key('library-albums-mosaic'),
                        crossAxisCount: 2,
                        padding: const EdgeInsets.all(12),
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                        physics: const NeverScrollableScrollPhysics(),
                        children: albums.map((album) {
                          Widget fallback({bool retry = false}) => DecoratedBox(
                            key: ValueKey('library-album-fallback-${album.albumId}'),
                            decoration: BoxDecoration(
                              color: context.colorScheme.surfaceContainerHigh,
                              borderRadius: const BorderRadius.all(Radius.circular(10)),
                            ),
                            child: retry
                                ? IconButton(
                                    tooltip: context.t.retry,
                                    icon: Icon(Icons.refresh, color: context.colorScheme.primary),
                                    onPressed: () => ref.invalidate(libraryAlbumPreviewProvider),
                                  )
                                : Icon(Icons.photo_album_outlined, color: context.colorScheme.primary),
                          );
                          final thumbnailId = album.thumbnailId;
                          if (thumbnailId == null) {
                            return fallback();
                          }
                          return ClipRRect(
                            key: ValueKey('library-album-preview-${album.albumId}-$thumbnailId'),
                            borderRadius: const BorderRadius.all(Radius.circular(10)),
                            child: Image(
                              image: RemoteImageProvider.thumbnail(
                                assetId: thumbnailId,
                                thumbhash: album.thumbHash ?? '',
                              ),
                              fit: BoxFit.cover,
                              frameBuilder: (_, child, frame, synchronous) => frame != null || synchronous
                                  ? child
                                  : const Center(child: CircularProgressIndicator()),
                              errorBuilder: (_, _, _) => fallback(retry: true),
                            ),
                          );
                        }).toList(),
                      );
                    },
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text(
                  context.t.albums,
                  style: context.textTheme.titleSmall?.copyWith(
                    color: context.colorScheme.onSurface,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _VisiblePartnerList extends ConsumerWidget {
  const _VisiblePartnerList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final partners = ref.watch(sharedWithPartnerProvider).valueOrNull ?? [];
    return _PartnerList(partners: partners.toList());
  }
}

class _PartnerList extends StatelessWidget {
  const _PartnerList({required this.partners});

  final List<Partner> partners;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: EdgeInsets.zero,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: partners.length,
      shrinkWrap: true,
      itemBuilder: (context, index) {
        final partner = partners[index];
        final isLastItem = index == partners.length - 1;
        return ListTile(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.only(
              bottomLeft: Radius.circular(isLastItem ? 20 : 0),
              bottomRight: Radius.circular(isLastItem ? 20 : 0),
            ),
          ),
          contentPadding: const EdgeInsets.only(left: 12.0, right: 18.0),
          leading: PartnerUserAvatar(userId: partner.id, name: partner.name),
          title: Text(
            context.t.partner_list_user_photos(user: partner.name),
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
          onTap: () => context.pushRoute(PartnerDetailRoute(partner: partner)),
        );
      },
    );
  }
}
