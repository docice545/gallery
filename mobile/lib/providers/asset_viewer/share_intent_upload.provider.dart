import 'dart:async';
import 'dart:io';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/models/upload/share_intent_attachment.model.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:immich_mobile/services/share_intent_service.dart';
import 'package:immich_mobile/utils/live_photo_import.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final shareIntentUploadProvider = StateNotifierProvider<ShareIntentUploadStateNotifier, List<ShareIntentAttachment>>(
  (ref) => ShareIntentUploadStateNotifier(
    ref.watch(appRouterProvider),
    ref.read(foregroundUploadServiceProvider),
    ref.read(shareIntentServiceProvider),
  ),
);

class ShareIntentUploadStateNotifier extends StateNotifier<List<ShareIntentAttachment>> {
  final AppRouter router;
  final ForegroundUploadService _foregroundUploadService;
  final ShareIntentService _shareIntentService;
  final Logger _logger = Logger('ShareIntentUploadStateNotifier');

  ShareIntentUploadStateNotifier(this.router, this._foregroundUploadService, this._shareIntentService) : super([]);

  void init() {
    _shareIntentService.onSharedMedia = onSharedMedia;
    _shareIntentService.init();
  }

  void onSharedMedia(List<ShareIntentAttachment> attachments) {
    router.removeWhere((route) => route.name == "ShareIntentRoute");
    clearAttachments();
    addAttachments(attachments);
    unawaited(router.push(ShareIntentRoute(attachments: attachments)));
  }

  void addAttachments(List<ShareIntentAttachment> attachments) {
    if (attachments.isEmpty) {
      return;
    }
    state = [...state, ...attachments];
  }

  void removeAttachment(ShareIntentAttachment attachment) {
    final updatedState = state.where((element) => element != attachment).toList();
    if (updatedState.length != state.length) {
      state = updatedState;
    }
  }

  void clearAttachments() {
    if (state.isEmpty) {
      return;
    }

    state = [];
  }

  Future<void> uploadAll(List<File> files) async {
    for (final file in files) {
      final fileId = p.hash(file.path).toString();
      _updateStatus(fileId, UploadStatus.running);
    }

    final protectedFiles = <File>[];
    for (final file in files) {
      if (setSharedImportActive(file.path, active: true)) {
        protectedFiles.add(file);
      } else {
        _updateStatus(p.hash(file.path).toString(), UploadStatus.failed);
      }
    }
    try {
      await _foregroundUploadService.uploadShareIntent(
        protectedFiles,
        pairedVideoPaths: {for (final attachment in state) attachment.path: ?attachment.pairedVideoPath},
        onProgress: (fileId, bytes, totalBytes) {
          final progress = totalBytes > 0 ? bytes / totalBytes : 0.0;
          _updateProgress(fileId, progress);
        },
        onSuccess: (fileId, _) {
          _updateStatus(fileId, UploadStatus.complete, progress: 1.0);
          for (final attachment in state.where((attachment) => attachment.id.toString() == fileId)) {
            markSharedImportConsumed(attachment.path);
          }
        },
        onError: (fileId, errorMessage) {
          _logger.warning("Upload failed for file: $fileId, error: $errorMessage");
          _updateStatus(fileId, UploadStatus.failed);
        },
      );
    } finally {
      for (final file in protectedFiles) {
        setSharedImportActive(file.path, active: false);
      }
    }
  }

  void _updateStatus(String fileId, UploadStatus status, {double? progress}) {
    final id = int.parse(fileId);
    state = [
      for (final attachment in state)
        if (attachment.id == id)
          attachment.copyWith(status: status, uploadProgress: progress ?? attachment.uploadProgress)
        else
          attachment,
    ];
  }

  void _updateProgress(String fileId, double progress) {
    final id = int.parse(fileId);
    state = [
      for (final attachment in state)
        if (attachment.id == id) attachment.copyWith(uploadProgress: progress) else attachment,
    ];
  }
}
