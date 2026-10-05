import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/utils/live_photo_import.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late File image;
  late File video;
  late File manifest;

  setUp(() {
    root = Directory.systemTemp.createTempSync('gallery-live-import-');
    final directory = Directory(p.join(root.path, 'live_photo_imports', 'pair'))..createSync(recursive: true);
    image = File(p.join(directory.path, 'still.heic'))..writeAsBytesSync([1, 2]);
    video = File(p.join(directory.path, 'motion.mov'))..writeAsBytesSync([3, 4]);
    manifest = File(p.join(directory.path, '.live-photo.json'))
      ..writeAsStringSync(jsonEncode({'version': 1, 'image': 'still.heic', 'video': 'motion.mov'}));
    File(p.join(directory.path, '.complete')).writeAsStringSync('{}');
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('native complete pair is one image with a preserved original motion resource', () {
    expect(pairedVideoForSharedImage(image.path), video.path);
    expect(image.readAsBytesSync(), [1, 2]);
    expect(video.readAsBytesSync(), [3, 4]);
  });

  test('same filenames outside Gallery-owned handoff never establish a pair', () {
    final outside = File(p.join(root.path, 'still.heic'))..writeAsBytesSync([1]);
    expect(pairedVideoForSharedImage(outside.path), isNull);
  });

  test('missing motion rejects the pair rather than a silent image-only import', () {
    video.deleteSync();
    expect(pairedVideoForSharedImage(image.path), isNull);
  });

  test('atomic publish marker is required', () {
    File(p.join(image.parent.path, '.complete')).deleteSync();
    expect(pairedVideoForSharedImage(image.path), isNull);
  });

  test('manifest traversal and symlink resources are rejected', () {
    manifest.writeAsStringSync(jsonEncode({'version': 1, 'image': 'still.heic', 'video': '../motion.mov'}));
    expect(pairedVideoForSharedImage(image.path), isNull);
    manifest.writeAsStringSync(jsonEncode({'version': 1, 'image': 'still.heic', 'video': 'motion.mov'}));
    video.deleteSync();
    Link(video.path).createSync(image.path);
    expect(pairedVideoForSharedImage(image.path), isNull);
  });

  test('unconsumed and recent handoffs retain both resources', () {
    cleanupConsumedShareImports(root, now: DateTime.now().add(const Duration(days: 30)));
    expect(image.existsSync(), isTrue);
    markSharedImportConsumed(image.path);
    cleanupConsumedShareImports(root);
    expect(image.existsSync(), isTrue);
    expect(video.existsSync(), isTrue);
  });

  test('active import survives expiry; inactive expired consumed pair is removed atomically', () {
    markSharedImportConsumed(image.path);
    setSharedImportActive(image.path, active: true);
    final future = DateTime.now().add(const Duration(days: 8));
    cleanupConsumedShareImports(root, now: future);
    expect(image.existsSync(), isTrue);
    expect(video.existsSync(), isTrue);
    setSharedImportActive(image.path, active: false);
    cleanupConsumedShareImports(root, now: future);
    expect(image.parent.existsSync(), isFalse);
    cleanupConsumedShareImports(root, now: future);
  });

  test('missing handoff directory cannot acquire a lease and is never uploaded unprotected', () {
    image.parent.deleteSync(recursive: true);
    expect(setSharedImportActive(image.path, active: true), isFalse);
    expect(setSharedImportActive(image.path, active: false), isTrue);
  });
}
