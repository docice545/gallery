import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail_framing.dart';

Rect _visibleSource(ThumbnailFraming framing, Size imageSize, Size viewportSize) {
  final fitted = applyBoxFit(framing.fit, imageSize, viewportSize);
  final source = framing.alignment.inscribe(fitted.source, Offset.zero & imageSize);
  return Rect.fromLTRB(
    source.left / imageSize.width,
    source.top / imageSize.height,
    source.right / imageSize.width,
    source.bottom / imageSize.height,
  );
}

void _expectFacesVisible(Rect source, List<Rect> faces) {
  for (final face in faces) {
    expect(source.left, lessThanOrEqualTo(face.left + 1e-12));
    expect(source.top, lessThanOrEqualTo(face.top + 1e-12));
    expect(source.right, greaterThanOrEqualTo(face.right - 1e-12));
    expect(source.bottom, greaterThanOrEqualTo(face.bottom - 1e-12));
  }
}

void main() {
  const portrait = Size(900, 1600);
  const square = Size(300, 300);

  test('portrait face near the top remains fully visible in the square preview', () {
    const faces = [Rect.fromLTRB(0.32, 0.02, 0.64, 0.20)];
    final framing = faceAwareThumbnailFraming(imageSize: portrait, viewportSize: square, faces: faces);

    expect(framing.fit, BoxFit.cover);
    expect(framing.alignment.y, -1);
    _expectFacesVisible(_visibleSource(framing, portrait, square), faces);
  });

  test('portrait face near the bottom shifts the cover window down', () {
    const faces = [Rect.fromLTRB(0.34, 0.78, 0.65, 0.98)];
    final framing = faceAwareThumbnailFraming(imageSize: portrait, viewportSize: square, faces: faces);

    expect(framing.fit, BoxFit.cover);
    expect(framing.alignment.y, 1);
    _expectFacesVisible(_visibleSource(framing, portrait, square), faces);
  });

  test('landscape faces at either horizontal edge shift the cover crop', () {
    const landscape = Size(1600, 900);
    for (final face in [const Rect.fromLTRB(0.01, 0.2, 0.19, 0.65), const Rect.fromLTRB(0.81, 0.2, 0.99, 0.65)]) {
      final framing = faceAwareThumbnailFraming(imageSize: landscape, viewportSize: square, faces: [face]);

      expect(framing.fit, BoxFit.cover);
      expect(framing.alignment.x, face.left < 0.5 ? -1 : 1);
      _expectFacesVisible(_visibleSource(framing, landscape, square), [face]);
    }
  });

  test('cover crop preserves the union of multiple faces', () {
    const faces = [Rect.fromLTRB(0.2, 0.31, 0.42, 0.50), Rect.fromLTRB(0.58, 0.61, 0.81, 0.83)];
    final framing = faceAwareThumbnailFraming(imageSize: portrait, viewportSize: square, faces: faces);

    expect(framing.fit, BoxFit.cover);
    _expectFacesVisible(_visibleSource(framing, portrait, square), faces);
  });

  test('faces spread beyond the cover window use contain without dropping a face', () {
    const faces = [Rect.fromLTRB(0.2, 0.03, 0.42, 0.24), Rect.fromLTRB(0.58, 0.76, 0.81, 0.98)];
    final framing = faceAwareThumbnailFraming(imageSize: portrait, viewportSize: square, faces: faces);

    expect(framing.fit, BoxFit.contain);
    expect(framing.alignment, Alignment.center);
    _expectFacesVisible(_visibleSource(framing, portrait, square), faces);
  });

  test('one face larger than the cover window also uses contain', () {
    const faces = [Rect.fromLTRB(0.2, 0.1, 0.8, 0.9)];
    final framing = faceAwareThumbnailFraming(imageSize: portrait, viewportSize: square, faces: faces);

    expect(framing.fit, BoxFit.contain);
    _expectFacesVisible(_visibleSource(framing, portrait, square), faces);
  });

  test('a face exactly filling a crop remains visible despite decimal rounding', () {
    const cropHeight = 0.7123429878269185;
    const faces = [Rect.fromLTRB(0.2, 0.24157428297121517, 0.8, 0.9539172707981337)];
    const imageSize = Size(1, 1 / cropHeight);
    final framing = faceAwareThumbnailFraming(imageSize: imageSize, viewportSize: square, faces: faces);

    _expectFacesVisible(_visibleSource(framing, imageSize, square), faces);
    expect(framing.alignment.x.isFinite, isTrue);
    expect(framing.alignment.y.isFinite, isTrue);
  });

  test('normalized framing is invariant to decoded image and viewport scaling', () {
    const faces = [Rect.fromLTRB(0.31, 0.63, 0.67, 0.84)];
    final original = faceAwareThumbnailFraming(imageSize: portrait, viewportSize: square, faces: faces);
    final decoded = faceAwareThumbnailFraming(
      imageSize: const Size(225, 400),
      viewportSize: const Size(150, 150),
      faces: faces,
    );

    expect(decoded.fit, original.fit);
    expect(decoded.alignment, original.alignment);
    expect(
      _visibleSource(decoded, const Size(225, 400), const Size(150, 150)),
      _visibleSource(original, portrait, square),
    );
  });

  test('partially out of image face coordinates are clipped to the image boundary', () {
    const clippedFaces = [Rect.fromLTRB(0.2, 0, 0.7, 0.2)];
    final framing = faceAwareThumbnailFraming(
      imageSize: portrait,
      viewportSize: square,
      faces: const [Rect.fromLTRB(0.2, -0.1, 0.7, 0.2)],
    );

    expect(framing.fit, BoxFit.cover);
    _expectFacesVisible(_visibleSource(framing, portrait, square), clippedFaces);
  });

  test('invalid, inverted, empty and wholly outside faces are ignored', () {
    const validFace = Rect.fromLTRB(0.32, 0.02, 0.64, 0.20);
    const invalidFaces = [
      Rect.fromLTRB(double.nan, 0.2, 0.8, 0.5),
      Rect.fromLTRB(0.2, 0.1, double.infinity, 0.5),
      Rect.fromLTRB(0.8, 0.2, 0.2, 0.5),
      Rect.fromLTRB(0.2, 0.6, 0.8, 0.1),
      Rect.fromLTRB(0.2, 0.2, 0.2, 0.5),
      Rect.fromLTRB(-0.5, 0.1, -0.1, 0.5),
      Rect.fromLTRB(0.1, 1.1, 0.8, 1.5),
    ];
    final framing = faceAwareThumbnailFraming(
      imageSize: portrait,
      viewportSize: square,
      faces: const [validFace, ...invalidFaces],
    );
    final expected = faceAwareThumbnailFraming(imageSize: portrait, viewportSize: square, faces: const [validFace]);

    expect(framing.fit, expected.fit);
    expect(framing.alignment, expected.alignment);
    _expectFacesVisible(_visibleSource(framing, portrait, square), const [validFace]);
    final empty = faceAwareThumbnailFraming(imageSize: portrait, viewportSize: square, faces: invalidFaces);
    expect(empty.fit, BoxFit.cover);
    expect(empty.alignment, Alignment.center);
  });

  test('no faces preserves the requested fit and centered alignment', () {
    for (final fit in BoxFit.values) {
      final framing = faceAwareThumbnailFraming(imageSize: portrait, viewportSize: square, faces: const [], fit: fit);

      expect(framing.fit, fit);
      expect(framing.alignment, Alignment.center);
    }
  });

  test('non-cover fits preserve their existing centered behavior with known faces', () {
    for (final fit in BoxFit.values.where((fit) => fit != BoxFit.cover)) {
      final framing = faceAwareThumbnailFraming(
        imageSize: portrait,
        viewportSize: square,
        faces: const [Rect.fromLTRB(0.2, 0.02, 0.8, 0.20)],
        fit: fit,
      );

      expect(framing.fit, fit);
      expect(framing.alignment, Alignment.center);
    }
  });

  test('invalid source and viewport sizes fall back to the requested fit', () {
    const invalidSizes = [Size.zero, Size(-1, 100), Size(100, -1), Size(double.nan, 100), Size(100, double.infinity)];
    for (final size in invalidSizes) {
      for (final sizes in [(size, square), (portrait, size)]) {
        final framing = faceAwareThumbnailFraming(
          imageSize: sizes.$1,
          viewportSize: sizes.$2,
          faces: const [Rect.fromLTRB(0.2, 0.02, 0.8, 0.20)],
        );

        expect(framing.fit, BoxFit.cover);
        expect(framing.alignment, Alignment.center);
      }
    }
  });
}
