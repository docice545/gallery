import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/models/upload/share_intent_attachment.model.dart';
import 'package:immich_mobile/repositories/share_handler.repository.dart';
import 'package:share_handler/share_handler.dart';

class _SharePlatform extends ShareHandlerPlatform {
  final initial = Completer<SharedMedia?>();
  final events = StreamController<SharedMedia>.broadcast();
  var initialReads = 0;

  Future<void> dispose() => events.close();

  @override
  Future<SharedMedia?> getInitialSharedMedia() {
    initialReads++;
    return initial.future;
  }

  @override
  Stream<SharedMedia> get sharedMediaStream => events.stream;
}

void main() {
  for (final state in ['malformed', 'missing']) {
    test('owned Live Photo $state manifest is rejected and retained without ordinary-image fallback', () async {
      final original = ShareHandlerPlatform.instance;
      final platform = _SharePlatform();
      ShareHandlerPlatform.instance = platform;
      final root = Directory.systemTemp.createTempSync('gallery-share-manifest-test-');
      final directory = Directory('${root.path}/live_photo_imports/pair')..createSync(recursive: true);
      final image = File('${directory.path}/still.heic')..writeAsBytesSync([1]);
      final motion = File('${directory.path}/motion.mov')..writeAsBytesSync([2]);
      File('${directory.path}/.complete').writeAsStringSync('{}');
      if (state == 'malformed') {
        File('${directory.path}/.live-photo.json').writeAsStringSync('{');
      }
      final repository = ShareHandlerRepository();
      final payloads = <List<ShareIntentAttachment>>[];
      repository.onSharedMedia = payloads.add;
      try {
        final initialization = repository.init();
        platform.initial.complete(
          SharedMedia(
            attachments: [SharedAttachment(path: image.path, type: SharedAttachmentType.image)],
          ),
        );
        await initialization;
        expect(payloads.single, isEmpty);
        expect(image.existsSync(), isTrue);
        expect(motion.existsSync(), isTrue);
      } finally {
        repository.dispose();
        await platform.dispose();
        root.deleteSync(recursive: true);
        ShareHandlerPlatform.instance = original;
      }
    });
  }
  for (final completePair in [true, false]) {
    test('native file-URI Live Photo import retains one attachment; completePair=$completePair', () async {
      final original = ShareHandlerPlatform.instance;
      final platform = _SharePlatform();
      ShareHandlerPlatform.instance = platform;
      final root = Directory.systemTemp.createTempSync('gallery-share-pair-test-');
      final directory = Directory('${root.path}/live_photo_imports/pair')..createSync(recursive: true);
      final image = File('${directory.path}/still.heic')..writeAsBytesSync([1, 2]);
      final video = File('${directory.path}/motion.mov');
      if (completePair) {
        video.writeAsBytesSync([3, 4]);
      }
      File(
        '${directory.path}/.live-photo.json',
      ).writeAsStringSync(jsonEncode({'version': 1, 'image': 'still.heic', 'video': 'motion.mov'}));
      File('${directory.path}/.complete').writeAsStringSync('{}');
      final repository = ShareHandlerRepository();
      final payloads = <List<ShareIntentAttachment>>[];
      repository.onSharedMedia = payloads.add;
      try {
        final initialization = repository.init();
        platform.initial.complete(
          SharedMedia(
            attachments: [SharedAttachment(path: image.uri.toString(), type: SharedAttachmentType.image)],
          ),
        );
        await initialization;
        if (completePair) {
          expect(payloads.single, hasLength(1));
          expect(payloads.single.single.path, image.path);
          expect(payloads.single.single.pairedVideoPath, video.path);
        } else {
          expect(payloads.single, isEmpty);
        }
      } finally {
        repository.dispose();
        await platform.dispose();
        root.deleteSync(recursive: true);
        ShareHandlerPlatform.instance = original;
      }
    });
  }
  test('imports accessible photos once and skips unsupported or revoked attachments', () async {
    final original = ShareHandlerPlatform.instance;
    final platform = _SharePlatform();
    ShareHandlerPlatform.instance = platform;
    final directory = await Directory.systemTemp.createTemp('gallery-share-test-');
    final photo = await File('${directory.path}/photo.jpg').writeAsBytes([1, 2, 3]);
    final repository = ShareHandlerRepository();
    final payloads = <List<ShareIntentAttachment>>[];
    repository.onSharedMedia = payloads.add;
    try {
      final first = repository.init();
      final second = repository.init();
      platform.initial.complete(
        SharedMedia(
          attachments: [
            SharedAttachment(path: photo.path, type: SharedAttachmentType.image),
            SharedAttachment(path: '${directory.path}/missing.jpg', type: SharedAttachmentType.image),
            SharedAttachment(path: photo.path, type: SharedAttachmentType.file),
            null,
          ],
        ),
      );
      await Future.wait([first, second]);
      expect(platform.initialReads, 1);
      expect(payloads.single.single.path, photo.path);
      expect(payloads.single.single.fileLength, 3);
      repository.dispose();
      expect(platform.events.hasListener, isFalse);
    } finally {
      repository.dispose();
      await platform.dispose();
      await directory.delete(recursive: true);
      ShareHandlerPlatform.instance = original;
    }
  });

  test('dispose during initialization does not register a late stream listener', () async {
    final original = ShareHandlerPlatform.instance;
    final platform = _SharePlatform();
    ShareHandlerPlatform.instance = platform;
    final repository = ShareHandlerRepository();
    try {
      final initialization = repository.init();
      repository.dispose();
      platform.initial.complete(null);
      await initialization;
      expect(platform.events.hasListener, isFalse);
    } finally {
      repository.dispose();
      await platform.dispose();
      ShareHandlerPlatform.instance = original;
    }
  });
}
