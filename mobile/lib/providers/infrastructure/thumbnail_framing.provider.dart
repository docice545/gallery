import 'dart:ui';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';

/// Already synchronized upright-image face bounds, normalized independently of
/// thumbnail decode resolution. No networking or new face detection is needed.
final thumbnailFaceBoundsProvider = StreamProvider.autoDispose.family<List<Rect>, String>((ref, assetId) {
  return ref
      .watch(driftProvider)
      .peopleDatabaseRepository
      .watchAssetFaces(assetId)
      .map(
        (faces) => [
          for (final face in faces)
            if (face.imageWidth > 0 && face.imageHeight > 0)
              Rect.fromLTRB(
                face.boundingBoxX1 / face.imageWidth,
                face.boundingBoxY1 / face.imageHeight,
                face.boundingBoxX2 / face.imageWidth,
                face.boundingBoxY2 / face.imageHeight,
              ),
        ],
      );
});
