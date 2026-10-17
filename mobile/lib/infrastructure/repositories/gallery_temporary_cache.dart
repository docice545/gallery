// ignore_for_file: avoid_slow_async_io

import 'dart:io';

import 'package:path/path.dart' as p;

/// The only filesystem subtree that [StorageRepository.clearCache] may purge
/// on iOS. Files put here must be disposable; originals and handoff resources
/// belong to their operation's own lifecycle, not this cache.
///
/// In particular this excludes PhotoManager exports in systemTemp, SQLite
/// temporary files, device-downloads, outgoing_share (receiver retention), and
/// the Share Extension's App Group container. These directories cannot be
/// safely made disposable merely by waiting for one upload queue to finish.
class GalleryTemporaryCache {
  static const directoryName = 'gallery_disposable_cache';
  static const _activePrefix = 'active-';
  final Directory _temporaryDirectory;

  GalleryTemporaryCache(this._temporaryDirectory);

  Directory get directory => Directory(p.join(_temporaryDirectory.path, directoryName));

  /// An active directory is a lease visible to other isolates/processes too.
  /// Create the directory with its active name atomically, before writing any
  /// resources. Keep all members of a Live Photo in the same lease directory.
  Future<GalleryTemporaryCacheLease> createLease() async {
    final root = directory;
    await root.create(recursive: true);
    if (await FileSystemEntity.type(root.path, followLinks: false) != FileSystemEntityType.directory) {
      throw const FileSystemException('Gallery cache root is not an owned directory');
    }
    final active = await root.createTemp(_activePrefix);
    return GalleryTemporaryCacheLease._(active);
  }

  /// Never follow a root or child symlink. Active directories are excluded as
  /// a unit, so cleanup cannot remove only one resource of an in-use pair.
  /// A lease is not expired based on age: a slow import/export may still need it.
  Future<void> clear() async {
    final root = directory;
    if (await FileSystemEntity.type(root.path, followLinks: false) != FileSystemEntityType.directory) {
      return;
    }
    await for (final entity in root.list(followLinks: false)) {
      if (p.basename(entity.path).startsWith(_activePrefix)) {
        continue;
      }
      try {
        await entity.delete(recursive: true);
      } on FileSystemException {
        // Concurrent cleanup/OS eviction can remove an already listed entry.
        // Propagate real errors rather than claiming the cache was cleared.
        if (await FileSystemEntity.type(entity.path, followLinks: false) != FileSystemEntityType.notFound) {
          rethrow;
        }
      }
    }
  }
}

class GalleryTemporaryCacheLease {
  final Directory directory;
  Future<void>? _release;

  GalleryTemporaryCacheLease._(this.directory);

  /// Call only after every reader/writer (including native work) has drained.
  /// The rename makes the whole operation disposable atomically. Cache clear
  /// may subsequently remove it; this does not touch library originals.
  Future<void> release() => _release ??= _releaseDirectory();

  Future<void> _releaseDirectory() async {
    final basename = p.basename(directory.path);
    final suffix = basename.substring(GalleryTemporaryCache._activePrefix.length);
    final destination = p.join(directory.parent.path, 'disposable-$suffix');
    if (await directory.exists()) {
      await directory.rename(destination);
    }
  }
}
