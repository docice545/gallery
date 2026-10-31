import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/place.model.dart';
import 'package:immich_mobile/domain/services/place_name.service.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail.widget.dart';
import 'package:immich_mobile/presentation/widgets/map/library_map_preview.widget.dart';
import 'package:immich_mobile/presentation/widgets/map/map.state.dart';
import 'package:immich_mobile/presentation/widgets/map/place_list_tile.widget.dart';
import 'package:immich_mobile/providers/infrastructure/map.provider.dart';
import 'package:immich_mobile/providers/place_names.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/place_names.dart';
import 'package:immich_mobile/widgets/common/search_field.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

@RoutePage()
class PlacePage extends HookWidget {
  const PlacePage({super.key, this.currentLocation});

  final LatLng? currentLocation;

  @override
  Widget build(BuildContext context) {
    final search = useValueNotifier<String?>(null);

    return Scaffold(
      body: ValueListenableBuilder(
        valueListenable: search,
        builder: (context, searchValue, child) {
          return CustomScrollView(
            slivers: [
              _PlaceSliverAppBar(search: search),
              _Map(search: search, currentLocation: currentLocation),
              _PlaceList(query: searchValue),
            ],
          );
        },
      ),
    );
  }
}

class _PlaceSliverAppBar extends HookConsumerWidget {
  const _PlaceSliverAppBar({required this.search});

  final ValueNotifier<String?> search;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final searchFocusNode = useFocusNode();

    return SliverAppBar(
      floating: true,
      pinned: true,
      snap: false,
      backgroundColor: context.colorScheme.surfaceContainer,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(5))),
      automaticallyImplyLeading: search.value == null,
      centerTitle: true,
      title: search.value != null
          ? SearchField(
              focusNode: searchFocusNode,
              onTapOutside: (_) => searchFocusNode.unfocus(),
              onChanged: (value) => search.value = value,
              filled: true,
              hintText: context.t.filter_places,
              autofocus: true,
            )
          : Text(context.t.places),
      actions: [
        IconButton(
          tooltip: context.t.refresh,
          icon: const Icon(Icons.refresh),
          onPressed: () async {
            await ref.read(placeNameServiceProvider).retryFailures();
            if (!context.mounted) {
              return;
            }
            ref.invalidate(localizedPlaceLabelProvider);
            ref.invalidate(placeDetailsProvider);
            ref.invalidate(initialMapViewportProvider);
            ref.invalidate(mapMarkerProvider(null));
          },
        ),
        IconButton(
          icon: Icon(search.value != null ? Icons.close : Icons.search),
          onPressed: () {
            search.value = search.value == null ? '' : null;
          },
        ),
      ],
    );
  }
}

class _Map extends StatelessWidget {
  const _Map({required this.search, this.currentLocation});

  final ValueNotifier<String?> search;
  final LatLng? currentLocation;

  @override
  Widget build(BuildContext context) {
    return search.value == null
        ? SliverPadding(
            padding: const EdgeInsets.all(16.0),
            sliver: SliverToBoxAdapter(
              child: SizedBox(
                height: 200,
                width: context.width,
                child: LibraryMapPreview(
                  initialLocation: currentLocation,
                  onTap: (centre) => context.pushRoute(MapRoute(initialLocation: centre)),
                ),
              ),
            ),
          )
        : const SliverToBoxAdapter(child: SizedBox.shrink());
  }
}

class _PlaceList extends ConsumerWidget {
  const _PlaceList({required this.query});

  final String? query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final places = ref.watch(placeDetailsProvider);
    final persisted = ref.watch(persistedPlaceLabelsProvider).valueOrNull ?? const <String, String>{};
    final labels = {...persisted, ...ref.watch(resolvedPlaceLabelsProvider)};
    final locale = context.locale;
    final aliases = query != null && query!.trim().runes.length >= 2
        ? ref.watch(placeSearchAliasesProvider(query!)).valueOrNull ?? const []
        : const [];

    String stableLabel(Place place) => localizedPlaceNameFallback(place, locale.languageCode);
    String label(Place place) => labels[PlaceNameService.key(place, locale.toLanguageTag())] ?? stableLabel(place);

    return places.when(
      // Preserve the existing sliver during sync refresh, instead of replacing
      // it with a small spinner and clamping the scroll offset back to zero.
      skipLoadingOnRefresh: true,
      skipLoadingOnReload: true,
      skipError: true,
      loading: () => const SliverToBoxAdapter(
        child: Center(
          child: Padding(padding: EdgeInsets.all(20.0), child: CircularProgressIndicator()),
        ),
      ),
      error: (error, stack) => SliverToBoxAdapter(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: TextButton.icon(
              onPressed: () => ref.invalidate(placeDetailsProvider),
              icon: const Icon(Icons.refresh),
              label: Text(context.t.filter_sheet_load_error_retry),
            ),
          ),
        ),
      ),
      data: (places) {
        final aliasScopes = {
          for (final alias in aliases)
            if (nearestPlaceForAlias(places, alias.name, alias.latitude, alias.longitude) case final place?)
              place.scopeIdentity,
        };
        final filtered =
            places.where((place) {
              if (place.name.trim().isEmpty) {
                return false;
              }
              return matchesPlaceName(place, label(place), query ?? '') ||
                  foldPlaceName(place.sourceRegion).contains(foldPlaceName(query ?? '')) ||
                  aliasScopes.contains(place.scopeIdentity);
            }).toList()..sort((a, b) {
              final comparison = comparePlaceNames(stableLabel(a), stableLabel(b), languageCode: locale.languageCode);
              if (comparison != 0) {
                return comparison;
              }
              final sourceComparison = a.name.compareTo(b.name);
              return sourceComparison != 0 ? sourceComparison : a.sourceRegion.compareTo(b.sourceRegion);
            });

        if (filtered.isEmpty) {
          return SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text(query?.trim().isNotEmpty ?? false ? context.t.no_results : context.t.no_places),
              ),
            ),
          );
        }

        return SliverSafeArea(
          top: false,
          sliver: SliverList.builder(
            itemCount: filtered.length,
            findChildIndexCallback: (key) {
              final index = filtered.indexWhere((place) => ValueKey(place.scopeIdentity) == key);
              return index < 0 ? null : index;
            },
            itemBuilder: (context, index) {
              final place = filtered[index];
              return _PlaceTile(key: ValueKey(place.scopeIdentity), place: place, cachedLabel: label(place));
            },
          ),
        );
      },
    );
  }
}

class _PlaceTile extends ConsumerWidget {
  const _PlaceTile({super.key, required this.place, required this.cachedLabel});

  final Place place;
  final String cachedLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final localized = ref.watch(localizedPlaceLabelProvider((place: place, locale: context.locale)));
    final nativeLabel = localized.valueOrNull;
    final label = nativeLabel != null && nativeLabel.trim() != place.name.trim() ? nativeLabel : cachedLabel;
    return PlaceListTile(
      name: label,
      sourceName: place.name,
      regionName: localizedPlaceRegion(place, context.locale.languageCode),
      onTap: () => context.pushRoute(PlaceDetailRoute(place: place.name, selectedPlace: place)),
      thumbnail: Thumbnail.remote(remoteId: place.assetId, fit: BoxFit.cover, thumbhash: ''),
    );
  }
}
