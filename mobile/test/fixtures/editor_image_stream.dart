import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:immich_mobile/widgets/common/transparent_image.dart';

/// Displays a normal preview until a test intercepts the next source load.
class EditorTestImageProvider extends MemoryImage {
  EditorTestImageProvider({Uint8List? bytes}) : super(bytes ?? kTransparentImage);

  final sources = <EditorTestImageCompleter>[];

  @override
  void resolveStreamForKey(
    ImageConfiguration configuration,
    ImageStream stream,
    MemoryImage key,
    ImageErrorListener handleError,
  ) {
    if (sources.isEmpty) {
      super.resolveStreamForKey(configuration, stream, key, handleError);
    } else {
      stream.setCompleter(sources.removeAt(0));
    }
  }
}

class EditorTestImageCompleter extends ImageStreamCompleter {
  bool get isObserved => hasListeners;

  void emitImage(ImageInfo info) => setImage(info);

  void emitError(Object error) => reportError(exception: error, stack: StackTrace.current);
}
