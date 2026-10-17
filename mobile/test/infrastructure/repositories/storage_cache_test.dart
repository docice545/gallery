// ignore_for_file: avoid_slow_async_io

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/repositories/gallery_temporary_cache.dart';
import 'package:immich_mobile/infrastructure/repositories/storage.repository.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory systemTemp;
  late Directory cacheBase;
  late GalleryTemporaryCache cache;
  late StorageRepository repository;
  late int pluginClearCalls;

  File write(String path) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('original resource bytes');
    return file;
  }

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    systemTemp = Directory.systemTemp.createTempSync('gallery-cache-test-');
    cacheBase = Directory(p.join(systemTemp.path, 'Library', 'Caches'))..createSync(recursive: true);
    cache = GalleryTemporaryCache(cacheBase);
    pluginClearCalls = 0;
    repository = StorageRepository(
      temporaryDirectory: () async => cacheBase,
      clearPhotoManagerCache: () async => pluginClearCalls++,
    );
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await systemTemp.delete(recursive: true);
  });

  test('iOS cleanup preserves unrelated systemTemp and caches files', () async {
    final unrelated = write(p.join(systemTemp.path, 'other-plugin', 'in-flight.tmp'));
    final sqlite = write(p.join(cacheBase.path, 'etilqs-active-database-temp'));
    final disposable = write(p.join(cache.directory.path, 'decoded-image.tmp'));

    await repository.clearCache();

    expect(await systemTemp.exists(), isTrue);
    expect(await cacheBase.exists(), isTrue);
    expect(await unrelated.exists(), isTrue);
    expect(await sqlite.exists(), isTrue);
    expect(await disposable.exists(), isFalse);
    expect(pluginClearCalls, 0);
  });

  test('cleans only explicitly owned disposable cache descendants', () async {
    final disposable = write(p.join(cache.directory.path, 'finished', 'nested', 'preview.tmp'));
    final otherGalleryFile = write(p.join(cacheBase.path, 'Immich_log.log'));

    await repository.clearCache();

    expect(await disposable.exists(), isFalse);
    expect(await cache.directory.exists(), isTrue);
    expect(await otherGalleryFile.exists(), isTrue);
  });

  test('active PhotoManager upload originals survive without purging plugin caches', () async {
    final image = write(p.join(systemTemp.path, '.image', 'upload.heic'));
    final video = write(p.join(systemTemp.path, '.video', 'upload.mov'));
    final fullImage = write(p.join(systemTemp.path, '.full', 'upload-exif.jpg'));

    await repository.clearCache();

    expect(await image.exists(), isTrue);
    expect(await video.exists(), isTrue);
    expect(await fullImage.exists(), isTrue);
    expect(pluginClearCalls, 0);
  });

  test('active download and import/export sources are outside disposable ownership', () async {
    final download = write(p.join(cacheBase.path, 'device-downloads', 'asset', 'attempt', 'original.mov'));
    final import = write(p.join(systemTemp.path, 'gallery-import', 'original.heic'));
    final export = write(p.join(systemTemp.path, 'gallery-export', 'original.heic'));

    await repository.clearCache();

    expect(await download.exists(), isTrue);
    expect(await import.exists(), isTrue);
    expect(await export.exists(), isTrue);
  });

  test('outgoing Share files retain their receiver retention contract', () async {
    final share = write(p.join(cacheBase.path, 'outgoing_share', 'completed', 'original.jpg'));
    final complete = write(p.join(share.parent.path, '.complete'));
    await complete.setLastModified(DateTime.now().subtract(const Duration(days: 6)));

    await repository.clearCache();

    expect(await share.exists(), isTrue);
    expect(await complete.exists(), isTrue);
    // Even after expiry the owner (AssetMediaRepository) decides when it is
    // safe to retire the share. StorageRepository must not race that manager.
    await complete.setLastModified(DateTime.now().subtract(const Duration(days: 8)));
    await repository.clearCache();
    expect(await share.exists(), isTrue);
  });

  test('Share Extension App Group and both retained Live Photo resources survive', () async {
    final photo = write(p.join(systemTemp.path, 'AppGroup', 'incoming-share', 'pair', 'original.heic'));
    final motion = write(p.join(photo.parent.path, 'paired.mov'));
    final metadata = write(p.join(photo.parent.path, 'handoff.json'));

    await repository.clearCache();

    expect(await photo.exists(), isTrue);
    expect(await motion.exists(), isTrue);
    expect(await metadata.exists(), isTrue);
  });

  test('active disposable lease protects upload/import/export files until drained', () async {
    final lease = await cache.createLease();
    final upload = write(p.join(lease.directory.path, 'upload.jpg'));
    final import = write(p.join(lease.directory.path, 'import.heic'));
    final export = write(p.join(lease.directory.path, 'export.mov'));

    // A distinct cleanup instance models a background engine/isolate: the
    // protection is the directory contract rather than an in-memory flag.
    await GalleryTemporaryCache(cacheBase).clear();

    expect(await upload.exists(), isTrue);
    expect(await import.exists(), isTrue);
    expect(await export.exists(), isTrue);
    await lease.release();
    await repository.clearCache();
    expect(await cache.directory.list().isEmpty, isTrue);
  });

  test('Live Photo lease retains both resources as a unit until release', () async {
    final lease = await cache.createLease();
    final photo = write(p.join(lease.directory.path, 'original.heic'));
    final motion = write(p.join(lease.directory.path, 'paired.mov'));

    await repository.clearCache();

    expect(await photo.exists(), isTrue);
    expect(await motion.exists(), isTrue);
    await lease.release();
    await lease.release();
    await repository.clearCache();
    expect(await cache.directory.list().isEmpty, isTrue);
  });

  test('cleanup and released leases are idempotent', () async {
    await repository.clearCache();
    final lease = await cache.createLease();
    write(p.join(lease.directory.path, 'completed.tmp'));
    await lease.release();
    await repository.clearCache();
    await repository.clearCache();
    await lease.release();
    expect(await cache.directory.list().isEmpty, isTrue);
    expect(pluginClearCalls, 0);
  });

  test('does not follow symlink entries outside owned cache', () async {
    final unrelated = write(p.join(systemTemp.path, 'plugin', 'original.jpg'));
    await cache.directory.create(recursive: true);
    final link = Link(p.join(cache.directory.path, 'disposable-link'));
    await link.create(unrelated.parent.path);

    await repository.clearCache();

    expect(await link.exists(), isFalse);
    expect(await unrelated.exists(), isTrue);
  });

  test('does not follow a symlink replacing the owned cache root', () async {
    final unrelated = write(p.join(systemTemp.path, 'plugin', 'original.jpg'));
    final link = Link(cache.directory.path);
    await link.create(unrelated.parent.path);

    await repository.clearCache();

    expect(await link.exists(), isTrue);
    expect(await unrelated.exists(), isTrue);
    await expectLater(cache.createLease(), throwsA(isA<FileSystemException>()));
  });

  test('Android cache clearing retains existing PhotoManager behavior', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final disposable = write(p.join(cache.directory.path, 'completed.tmp'));

    await repository.clearCache();

    expect(pluginClearCalls, 1);
    expect(await disposable.exists(), isTrue);
  });
}
