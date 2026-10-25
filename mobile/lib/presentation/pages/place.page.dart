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
import 'package:immich_mobile/presentation/widgets/map/place_list_tile.widget.dart';
import 'package:immich_mobile/providers/place_names.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/place_names.dart';
import 'package:immich_mobile/widgets/common/search_field.dart';
import 'package:immich_mobile/widgets/map/map_thumbnail.dart';
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

class _PlaceSliverAppBar extends HookWidget {
  const _PlaceSliverAppBar({required this.search});

  final ValueNotifier<String?> search;

  @override
  Widget build(BuildContext context) {
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
                child: MapThumbnail(
                  onTap: (_, _) => context.pushRoute(MapRoute(initialLocation: currentLocation)),
                  zoom: 8,
                  centre: currentLocation ?? const LatLng(21.44950, -157.91959),
                  showAttribution: false,
                  themeMode: context.isDarkTheme ? ThemeMode.dark : ThemeMode.light,
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

    String label(Place place) => labels[PlaceNameService.key(place, locale.toLanguageTag())] ?? place.name.trim();

    return places.when(
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
        final filtered =
            places.where((place) {
              if (place.name.trim().isEmpty) {
                return false;
              }
              return matchesPlaceName(place, label(place), query ?? '') ||
                  aliases.any(
                    (alias) =>
                        foldPlaceName(alias.name) == foldPlaceName(place.name) &&
                        isNearbyPlace(place, alias.latitude, alias.longitude),
                  );
            }).toList()..sort((a, b) {
              final comparison = comparePlaceNames(label(a), label(b), languageCode: locale.languageCode);
              return comparison != 0 ? comparison : a.name.compareTo(b.name);
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
              final index = filtered.indexWhere((place) => ValueKey(place.name) == key);
              return index < 0 ? null : index;
            },
            itemBuilder: (context, index) {
              final place = filtered[index];
              return _PlaceTile(key: ValueKey(place.name), place: place, cachedLabel: label(place));
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
    final label = localized.valueOrNull ?? cachedLabel;
    return PlaceListTile(
      name: label,
      sourceName: place.name,
      onTap: () => context.pushRoute(PlaceDetailRoute(place: place.name)),
      thumbnail: Thumbnail.remote(remoteId: place.assetId, fit: BoxFit.cover, thumbhash: ''),
    );
  }
}
