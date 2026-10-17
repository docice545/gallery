import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

bool isOwnedLivePhotoImport(String imagePath) => p.basename(File(imagePath).parent.parent.path) == 'live_photo_imports';

/// Only our atomically published App Group handoff may describe a paired import.
/// A same-basename JPEG/MOV elsewhere is never sufficient evidence of a pair.
String? pairedVideoForSharedImage(String imagePath) {
  final directory = File(imagePath).parent;
  if (!isOwnedLivePhotoImport(imagePath)) {
    return null;
  }
  try {
    final manifest = File(p.join(directory.path, '.live-photo.json'));
    if (!File(p.join(directory.path, '.complete')).existsSync() || manifest.lengthSync() > 4096) {
      return null;
    }
    final data = jsonDecode(manifest.readAsStringSync());
    if (data is! Map<String, dynamic> || data['version'] != 1 || data['image'] != p.basename(imagePath)) {
      return null;
    }
    final videoName = data['video'];
    if (videoName is! String || videoName != p.basename(videoName) || videoName.contains('\\') || videoName == '..') {
      return null;
    }
    final videoPath = p.join(directory.path, videoName);
    if (FileSystemEntity.typeSync(imagePath, followLinks: false) != FileSystemEntityType.file ||
        FileSystemEntity.typeSync(videoPath, followLinks: false) != FileSystemEntityType.file ||
        File(imagePath).lengthSync() == 0 ||
        File(videoPath).lengthSync() == 0) {
      return null;
    }
    return videoPath;
  } on Object {
    return null;
  }
}

/// Mark the complete directory, never one component, as consumed. Cleanup only
/// removes consumed, inactive handoffs after the same seven-day share retention.
void markSharedImportConsumed(String imagePath) {
  final directory = File(imagePath).parent;
  if (!{'live_photo_imports', 'gallery_share_imports'}.contains(p.basename(directory.parent.path))) {
    return;
  }
  try {
    File(p.join(directory.path, '.consumed')).writeAsStringSync('{}', flush: true);
  } on FileSystemException {
    // Keep resources if the handoff has been evicted or the marker cannot persist.
  }
}

bool setSharedImportActive(String imagePath, {required bool active}) {
  final directory = File(imagePath).parent;
  if (!{'live_photo_imports', 'gallery_share_imports'}.contains(p.basename(directory.parent.path))) {
    return true;
  }
  final marker = File(p.join(directory.path, '.active'));
  try {
    if (active) {
      marker.writeAsStringSync('{}', flush: true);
    } else if (marker.existsSync()) {
      marker.deleteSync();
    }
    return true;
  } on FileSystemException {
    return false;
  }
}

void cleanupConsumedShareImports(Directory appGroupRoot, {DateTime? now}) {
  final cutoff = (now ?? DateTime.now()).subtract(const Duration(days: 7));
  for (final name in ['live_photo_imports', 'gallery_share_imports']) {
    final root = Directory(p.join(appGroupRoot.path, name));
    if (!root.existsSync()) {
      continue;
    }
    for (final entity in root.listSync(followLinks: false)) {
      if (entity is! Directory || File(p.join(entity.path, '.active')).existsSync()) {
        continue;
      }
      final consumed = File(p.join(entity.path, '.consumed'));
      if (consumed.existsSync() && consumed.lastModifiedSync().isBefore(cutoff)) {
        entity.deleteSync(recursive: true);
      }
    }
  }
}
