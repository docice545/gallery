import 'dart:async';
import 'dart:io';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/models/upload/share_intent_attachment.model.dart';
import 'package:immich_mobile/utils/live_photo_import.dart';
import 'package:path/path.dart' as p;
import 'package:share_handler/share_handler.dart';

final shareHandlerRepositoryProvider = Provider((ref) {
  final repository = ShareHandlerRepository();
  ref.onDispose(repository.dispose);
  return repository;
});

class ShareHandlerRepository {
  ShareHandlerRepository();

  void Function(List<ShareIntentAttachment> attachments)? onSharedMedia;
  StreamSubscription<SharedMedia>? _subscription;
  Future<void>? _initialization;
  bool _disposed = false;

  Future<void> init() => _initialization ??= _init();

  Future<void> _init() async {
    final handler = ShareHandlerPlatform.instance;
    final media = await handler.getInitialSharedMedia();
    if (_disposed) {
      return;
    }

    if (media != null && media.attachments != null) {
      onSharedMedia?.call(_buildPayload(media.attachments!));
    }

    _subscription = handler.sharedMediaStream.listen((SharedMedia media) {
      if (media.attachments != null) {
        onSharedMedia?.call(_buildPayload(media.attachments!));
      }
    });
  }

  void dispose() {
    _disposed = true;
    unawaited(_subscription?.cancel());
    onSharedMedia = null;
  }

  List<ShareIntentAttachment> _buildPayload(List<SharedAttachment?> attachments) {
    final payload = <ShareIntentAttachment>[];

    for (final attachment in attachments) {
      if (attachment == null ||
          (attachment.type != SharedAttachmentType.image && attachment.type != SharedAttachmentType.video)) {
        continue;
      }

      final type = attachment.type == SharedAttachmentType.image
          ? ShareIntentAttachmentType.image
          : ShareIntentAttachmentType.video;

      // A share source may revoke access or remove its temporary file. Skip that
      // attachment rather than crashing import for every other selected photo.
      final int fileLength;
      final path = attachment.path.startsWith('file:') ? Uri.parse(attachment.path).toFilePath() : attachment.path;
      try {
        final directory = File(path).parent;
        if (p.basename(directory.parent.path) == 'live_photo_imports') {
          if (pairedVideoForSharedImage(path) == null) {
            continue; // A broken requested pair is never imported as just a still.
          }
          cleanupConsumedShareImports(directory.parent.parent);
        } else if (p.basename(directory.parent.path) == 'gallery_share_imports') {
          cleanupConsumedShareImports(directory.parent.parent);
        }
        fileLength = File(path).lengthSync();
      } on FileSystemException {
        continue;
      }

      payload.add(
        ShareIntentAttachment(
          path: path,
          type: type,
          status: UploadStatus.enqueued,
          uploadProgress: 0.0,
          fileLength: fileLength,
        ),
      );
    }

    return payload;
  }
}
