import 'dart:async';
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
