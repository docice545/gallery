import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';

/// A real deletion ACK arms a fresh membership check. A loading/empty bucket,
/// initial empty album or unrelated deletion can never pop this route.
class LocalAlbumDeletionListener extends ConsumerStatefulWidget {
  const LocalAlbumDeletionListener({super.key, required this.albumId, required this.child});
  final String albumId;
  final Widget child;

  @override
  ConsumerState<LocalAlbumDeletionListener> createState() => _LocalAlbumDeletionListenerState();
}

class _LocalAlbumDeletionListenerState extends ConsumerState<LocalAlbumDeletionListener> {
  late final StreamSubscription<DeviceTrashAcknowledgedEvent> _subscription;
  RouteData? _route;
  StackRouter? _router;
  bool _pending = false;
  bool _checking = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _subscription = EventStream.shared.listen<DeviceTrashAcknowledgedEvent>((event) {
      if (event.assetIds.isEmpty || !event.albumIds.contains(widget.albumId)) {
        return;
      }
      _pending = true;
      _generation++;
      _onRouteChanged();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = context.findAncestorWidgetOfExactType<RouteDataScope>()?.routeData;
    final router = _route?.router.root;
    if (!identical(router, _router)) {
      _router?.removeListener(_onRouteChanged);
      _router = router;
      _router?.addListener(_onRouteChanged);
    }
    if (_pending) {
      _onRouteChanged();
    }
  }

  bool get _isCurrent =>
      mounted &&
      _route != null &&
      (_router?.currentSegments.any((match) => match.id == _route!.matchId) ?? false) &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  void _onRouteChanged() {
    unawaited(_check());
    // Router notifications can precede ModalRoute's transition update.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_check());
      }
    });
  }

  Future<void> _check() async {
    if (!_pending || _checking || !_isCurrent) {
      return;
    }
    final generation = _generation;
    final userId = ref.read(currentUserProvider)?.id;
    final endpoint = ref.read(storeServiceProvider).tryGet(StoreKey.serverEndpoint);
    _checking = true;
    try {
      final assets = await ref.read(driftProvider).localAlbumRepository.getAssets(widget.albumId);
      if (!mounted || generation != _generation || !_isCurrent) {
        return;
      }
      _pending = false;
      if (ref.read(currentUserProvider)?.id != userId ||
          ref.read(storeServiceProvider).tryGet(StoreKey.serverEndpoint) != endpoint) {
        return;
      }
      if (assets.isEmpty) {
        await context.router.maybePop();
      }
    } catch (_) {
      // A failed membership read is not evidence of an empty album. A later
      // confirmed operation or route activation can retry the check.
    } finally {
      _checking = false;
      if (mounted && generation != _generation) {
        _onRouteChanged();
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    _router?.removeListener(_onRouteChanged);
    unawaited(_subscription.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
