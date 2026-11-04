import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/place.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_route_scope.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/place_names.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/utils/place_names.dart';
import 'package:immich_mobile/widgets/common/mesmerizing_sliver_app_bar.dart';

@RoutePage()
class PlaceDetailPage extends ConsumerWidget {
  final String place;
  final Place? selectedPlace;

  const PlaceDetailPage({super.key, required this.place, this.selectedPlace});

  static const timelineOverviewControlsEnabled = true;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = Place.resolveSelection(
      place,
      ref.watch(placeDetailsProvider).valueOrNull ?? const [],
      selectedPlace: selectedPlace,
    );
    // Intentional detail entry may enrich this one place. Presentation always
    // uses the same cache/fallback policy as the list, including while offline.
    if (source != null) {
      ref.watch(localizedPlaceLabelProvider((place: source, locale: context.locale)));
    }
    final title = source == null
        ? localizedPlaceNameFallback(Place(name: place, assetId: ''), context.locale.languageCode)
        : ref.watch(placeDisplayNamesProvider(context.locale)).label(source);
    return TimelineRouteScope(
      timelineServiceBuilder: (ref, scope, groupBy) {
        final user = ref.watch(currentUserProvider);
        if (user == null) {
          throw Exception('User must be logged in to access place');
        }
        final users = ref.watch(timelineUsersProvider).valueOrNull ?? [user.id];
        return ref
            .watch(timelineFactoryProvider)
            .place(place, users, user.id, selectedPlace: selectedPlace, groupBy: groupBy, temporalScope: scope);
      },
      child: Timeline(
        withGroupingPill: true,
        appBar: MesmerizingSliverAppBar(title: title, icon: Icons.location_on),
      ),
    );
  }
}
