import 'dart:io';

import 'package:mime/mime.dart';

/// Inspect a bounded header, never the whole original (which may be a large video).
Future<String> originalFileMimeType(File file, {String? fallback}) async {
  final handle = await file.open();
  try {
    final header = await handle.read(32);
    final inferred = lookupMimeType(file.path, headerBytes: header);
    if (inferred != null) {
      return inferred;
    }
    if (fallback != null && RegExp(r'^[a-zA-Z0-9.+-]+/[a-zA-Z0-9.+-]+$').hasMatch(fallback)) {
      return fallback;
    }
    return 'application/octet-stream';
  } finally {
    await handle.close();
  }
}
