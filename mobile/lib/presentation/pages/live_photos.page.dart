import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/images/face_aware_thumbnail_scope.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/live_photo_scope.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_route_scope.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/widgets/common/mesmerizing_sliver_app_bar.dart';

@RoutePage()
class LivePhotosPage extends StatelessWidget {
  const LivePhotosPage({super.key});

  static const timelineOverviewControlsEnabled = true;

  @override
  Widget build(BuildContext context) {
    return TimelineRouteScope(
      timelineServiceBuilder: (ref, scope, groupBy) {
        final user = ref.watch(currentUserProvider);
        if (user == null) {
          throw StateError('User must be logged in to access live photos');
        }
        final users = ref.watch(timelineUsersProvider).valueOrNull ?? [user.id];
        return ref.watch(timelineFactoryProvider).livePhotos(users, user.id, groupBy: groupBy, temporalScope: scope);
      },
      child: TimelineLivePhotoScope(
        child: FaceAwareThumbnailScope(
          child: Timeline(
            denseLayout: true,
            withStack: true,
            withGroupingPill: true,
            appBar: MesmerizingSliverAppBar(title: context.t.library_live_photos),
          ),
        ),
      ),
    );
  }
}
