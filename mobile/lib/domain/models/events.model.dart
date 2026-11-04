import 'package:immich_mobile/domain/utils/event_stream.dart';

// Timeline Events
class TimelineReloadEvent extends Event {
  const TimelineReloadEvent();
}

class ScrollToTopEvent extends Event {
  const ScrollToTopEvent();
}

/// Emitted only after verified OS removal and the corresponding cache commit.
/// Empty/loading Timeline emissions are deliberately not deletion evidence.
class DeviceTrashAcknowledgedEvent extends Event {
  final Set<String> albumIds;
  final Set<String> assetIds;

  const DeviceTrashAcknowledgedEvent({required this.albumIds, required this.assetIds});
}

// Asset Viewer Events
class ViewerShowDetailsEvent extends Event {
  const ViewerShowDetailsEvent();
}

class ViewerReloadAssetEvent extends Event {
  const ViewerReloadAssetEvent();
}

class ViewerStackAssetDeletedEvent extends Event {
  final int stackIndex;
  final String assetId;
  final String stackId;

  const ViewerStackAssetDeletedEvent({required this.stackIndex, required this.assetId, required this.stackId});
}

// Multi-Select Events
class MultiSelectToggleEvent extends Event {
  final bool isEnabled;
  const MultiSelectToggleEvent(this.isEnabled);
}

// Map Events
class MapMarkerReloadEvent extends Event {
  const MapMarkerReloadEvent();
}
