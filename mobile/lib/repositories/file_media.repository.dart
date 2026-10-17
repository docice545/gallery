import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/platform/live_photo_save_api.g.dart';
import 'package:immich_mobile/utils/original_file.dart';
import 'package:photo_manager/photo_manager.dart' hide AssetType;

final fileMediaRepositoryProvider = Provider((ref) => const FileMediaRepository());

class FileMediaRepository {
  static const _localFiles = MethodChannel('file_trash');
  final bool? isAndroid;
  final LivePhotoSaveApi? livePhotoApi;
  const FileMediaRepository({this.isAndroid, this.livePhotoApi});

  Future<AssetEntity?> saveImageWithFile(String filePath, {String? title, String? relativePath}) async {
    final mimeType = await _originalMimeType(File(filePath), 'image/');
    final entity = await PhotoManager.editor.saveImageWithPath(filePath, title: title, relativePath: relativePath);
    await _setOriginalMimeType(entity, mimeType);
    return entity;
  }

  Future<LivePhotoSaveResult> saveLivePhoto({
    required String requestId,
    required File image,
    required File video,
    required String title,
    bool allowImageOnlyFallback = true,
  }) async {
    try {
      final result = await (livePhotoApi ?? LivePhotoSaveApi()).saveLivePhoto(
        requestId: requestId,
        imagePath: image.path,
        videoPath: video.path,
        title: title,
        allowImageOnlyFallback: allowImageOnlyFallback,
      );
      if ((result.outcome == LivePhotoSaveOutcome.livePhoto || result.outcome == LivePhotoSaveOutcome.imageOnly) &&
          (result.localIdentifier == null || result.localIdentifier!.isEmpty)) {
        return LivePhotoSaveResult(outcome: LivePhotoSaveOutcome.failed, errorCode: 'MISSING_LOCAL_IDENTIFIER');
      }
      return result;
    } on PlatformException {
      return LivePhotoSaveResult(outcome: LivePhotoSaveOutcome.failed, errorCode: 'PLATFORM_FAILURE');
    }
  }

  Future<void> cancelLivePhotoSave(String requestId) => (livePhotoApi ?? LivePhotoSaveApi()).cancelSave(requestId);

  Future<AssetEntity?> saveVideo(File file, {required String title, String? relativePath}) async {
    final mimeType = await _originalMimeType(file, 'video/');
    final entity = await PhotoManager.editor.saveVideo(file, title: title, relativePath: relativePath);
    await _setOriginalMimeType(entity, mimeType);
    return entity;
  }

  Future<void> _setOriginalMimeType(AssetEntity entity, String? mimeType) async {
    if (mimeType == null) {
      return;
    }
    try {
      final updated = await _localFiles.invokeMethod<bool>('updateDownloadedAssetMimeType', {
        'mediaId': entity.id,
        'type': entity.type.index,
        'mimeType': mimeType,
      });
      if (updated != true) {
        throw StateError('Unable to set the MIME type of the saved original');
      }
    } catch (_) {
      // Only this newly imported media item is rolled back; never leave a failed import for a retry to duplicate.
      await PhotoManager.editor.deleteWithIds([entity.id]);
      rethrow;
    }
  }

  Future<String?> _originalMimeType(File file, String expectedPrefix) async {
    if (!(isAndroid ?? Platform.isAndroid)) {
      return null;
    }
    final mimeType = await originalFileMimeType(file);
    if (!mimeType.startsWith(expectedPrefix)) {
      throw StateError('The original file is not a supported $expectedPrefix media type');
    }
    return mimeType;
  }
}
