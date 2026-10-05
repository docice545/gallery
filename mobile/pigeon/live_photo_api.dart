import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/platform/live_photo_api.g.dart',
    swiftOut: 'ios/Runner/LivePhotos/LivePhotoMessages.g.swift',
    swiftOptions: SwiftOptions(includeErrorClass: false),
    dartPackageName: 'immich_mobile',
  ),
)
class LivePhotoResourcePair {
  final String imagePath;
  final String videoPath;

  const LivePhotoResourcePair({required this.imagePath, required this.videoPath});
}

class LivePhotoShareItem {
  final String imagePath;
  final String? videoPath;

  const LivePhotoShareItem({required this.imagePath, this.videoPath});
}

/// Apple-only resource transfer. Android keeps its existing original-file share.
@HostApi()
abstract class LivePhotoApi {
  @async
  LivePhotoResourcePair? exportLivePhoto(String localId);

  void cancelLivePhotoExport(String localId);

  @async
  bool shareLivePhotos(List<LivePhotoShareItem> items, double x, double y, double width, double height);

  void cancelLivePhotoShare();
}
