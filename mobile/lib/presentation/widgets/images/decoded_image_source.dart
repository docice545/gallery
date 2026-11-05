/// A custom render object that already paints decoded image pixels.
///
/// Capture effects can recognize it without taking ownership of its image or
/// treating an unloaded gradient as a photo. Standard RenderImage is supported
/// separately by the capture coordinator.
abstract interface class DecodedImageSource {
  bool get hasDecodedImage;
}
