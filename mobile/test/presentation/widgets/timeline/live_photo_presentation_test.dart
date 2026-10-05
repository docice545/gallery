import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail_framing.dart';
import 'package:immich_mobile/presentation/widgets/images/timeline_thumbnail_request.dart';
import 'package:immich_mobile/presentation/widgets/timeline/live_photo_presentation.dart';

const _viewport = Size.square(180);
const _sourceImage = Size(4096, 8192);
const _video = Size(1024, 2048);

Size _plannedSize(Size imageSize, {List<Rect> faces = const []}) => buildTimelineThumbnailRequest(
  viewportSize: _viewport,
  devicePixelRatio: 3,
  imageSize: imageSize,
  faces: faces,
).requiredSize;

void main() {
  group('canPresentTimelineMotion', () {
    for (final example in [
      (name: 'portrait', image: const Size(4000, 6000), video: const Size(1080, 1620)),
      (name: 'landscape', image: const Size(6000, 4000), video: const Size(1620, 1080)),
    ]) {
      test('accepts ${example.name} video with enough pixels for the planned high-DPR cover presentation', () {
        final requiredSize = _plannedSize(example.image);
        expect(requiredSize.shortestSide, greaterThanOrEqualTo(_viewport.shortestSide * 3));
        expect(
          canPresentTimelineMotion(imageSize: example.image, videoSize: example.video, requiredSize: requiredSize),
          isTrue,
        );
      });

      test('rejects ${example.name} video with swapped orientation despite enough source pixels', () {
        final videoSize = Size(example.image.height, example.image.width);
        final requiredSize = _plannedSize(example.image);
        expect(videoSize.width, greaterThan(requiredSize.width));
        expect(videoSize.height, greaterThan(requiredSize.height));
        expect(
          canPresentTimelineMotion(imageSize: example.image, videoSize: videoSize, requiredSize: requiredSize),
          isFalse,
        );
      });
    }

    test('accepts the smaller contain presentation requirement when separated faces cannot fit the cover crop', () {
      const imageSize = Size(4000, 6000);
      const videoSize = Size(512, 768);
      const faces = [Rect.fromLTRB(0.32, 0.02, 0.64, 0.20), Rect.fromLTRB(0.32, 0.90, 0.64, 0.99)];
      final framing = faceAwareThumbnailFraming(imageSize: imageSize, viewportSize: _viewport, faces: faces);
      expect(framing.fit, BoxFit.contain);

      final containRequirement = _plannedSize(imageSize, faces: faces);
      final coverRequirement = _plannedSize(imageSize);
      expect(containRequirement.width, lessThan(coverRequirement.width));
      expect(containRequirement.height, lessThan(coverRequirement.height));
      expect(
        canPresentTimelineMotion(imageSize: imageSize, videoSize: videoSize, requiredSize: containRequirement),
        isTrue,
      );
      expect(
        canPresentTimelineMotion(imageSize: imageSize, videoSize: videoSize, requiredSize: coverRequirement),
        isFalse,
      );
    });

    // A binary-exact aspect ratio makes the one-pixel boundary independent of
    // floating-point subtraction noise.
    for (final pixelDifference in [-1.0, 1.0]) {
      test('accepts $pixelDifference codec pixel of aspect rounding', () {
        expect(
          canPresentTimelineMotion(
            imageSize: _sourceImage,
            videoSize: Size(_video.width + pixelDifference, _video.height),
            requiredSize: const Size(512, 1024),
          ),
          isTrue,
        );
      });
    }

    for (final pixelDifference in [-2.0, 2.0]) {
      test('rejects $pixelDifference codec pixels of aspect mismatch', () {
        expect(
          canPresentTimelineMotion(
            imageSize: _sourceImage,
            videoSize: Size(_video.width + pixelDifference, _video.height),
            requiredSize: const Size(512, 1024),
          ),
          isFalse,
        );
      });
    }

    test('accepts source pixels exactly equal to both physical presentation axes', () {
      expect(canPresentTimelineMotion(imageSize: _sourceImage, videoSize: _video, requiredSize: _video), isTrue);
    });

    test('accepts codec-rounded 1080p motion that satisfies the actual presentation requirement', () {
      expect(
        canPresentTimelineMotion(
          imageSize: const Size(4032, 2268),
          videoSize: const Size(1080, 608),
          requiredSize: const Size(1080, 607.5),
        ),
        isTrue,
      );
      const imageSize = Size(2128, 1197);
      final request = buildTimelineThumbnailRequest(
        viewportSize: const Size(360, 202.5),
        devicePixelRatio: 3,
        imageSize: imageSize,
      );
      expect(request.requiredSize.width, closeTo(1080, 1e-9));
      expect(
        canPresentTimelineMotion(
          imageSize: imageSize,
          videoSize: const Size(1080, 608),
          requiredSize: request.requiredSize,
        ),
        isTrue,
        reason: 'floating-point scale noise must not reject an adequate native source',
      );
    });

    for (final axis in ['width', 'height']) {
      test('rejects a video one source pixel below the requested presentation $axis', () {
        final requiredSize = Size(_video.width + (axis == 'width' ? 1 : 0), _video.height + (axis == 'height' ? 1 : 0));
        expect(
          canPresentTimelineMotion(imageSize: _sourceImage, videoSize: _video, requiredSize: requiredSize),
          isFalse,
        );
      });
    }

    for (final position in ['imageSize', 'videoSize', 'requiredSize']) {
      for (final axis in ['width', 'height']) {
        for (final invalid in const [
          (name: 'zero', value: 0.0),
          (name: 'negative', value: -1.0),
          (name: 'NaN', value: double.nan),
          (name: 'positive infinity', value: double.infinity),
          (name: 'negative infinity', value: double.negativeInfinity),
        ]) {
          test('rejects ${invalid.name} $position $axis', () {
            final invalidSize = Size(
              axis == 'width' ? invalid.value : _video.width,
              axis == 'height' ? invalid.value : _video.height,
            );
            expect(
              canPresentTimelineMotion(
                imageSize: position == 'imageSize' ? invalidSize : _sourceImage,
                videoSize: position == 'videoSize' ? invalidSize : _video,
                requiredSize: position == 'requiredSize' ? invalidSize : const Size(512, 1024),
              ),
              isFalse,
            );
          });
        }
      }
    }
  });
}
