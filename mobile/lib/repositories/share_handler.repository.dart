import 'dart:async';
import 'dart:io';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/models/upload/share_intent_attachment.model.dart';
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

  Future<void> init() => _initialization ??= _init();

  Future<void> _init() async {
    final handler = ShareHandlerPlatform.instance;
    final media = await handler.getInitialSharedMedia();

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
      try {
        fileLength = File(attachment.path).lengthSync();
      } on FileSystemException {
        continue;
      }

      payload.add(
        ShareIntentAttachment(
          path: attachment.path,
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
