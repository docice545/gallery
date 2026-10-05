import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/platform/live_photo_save_api.g.dart',
    swiftOut: 'ios/Runner/Sync/LivePhotoSave.g.swift',
    swiftOptions: SwiftOptions(includeErrorClass: false),
    dartPackageName: 'immich_mobile',
  ),
)
enum LivePhotoSaveOutcome { livePhoto, imageOnly, failed, cancelled }

class LivePhotoSaveResult {
  final LivePhotoSaveOutcome outcome;
  final String? localIdentifier;
  // Stable, non-sensitive reason. Never includes media paths or pairing IDs.
  final String? errorCode;

  const LivePhotoSaveResult({required this.outcome, this.localIdentifier, this.errorCode});
}

@HostApi()
abstract class LivePhotoSaveApi {
  @async
  LivePhotoSaveResult saveLivePhoto({
    required String requestId,
    required String imagePath,
    required String videoPath,
    required String title,
    bool allowImageOnlyFallback = true,
  });

  // Resolves only after validation/PhotoKit has stopped reading the resources.
  // A submitted PhotoKit transaction cannot be undone by cancellation.
  @async
  void cancelSave(String requestId);
}
