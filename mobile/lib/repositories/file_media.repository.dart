import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/utils/original_file.dart';
import 'package:photo_manager/photo_manager.dart' hide AssetType;

final fileMediaRepositoryProvider = Provider((ref) => const FileMediaRepository());

class FileMediaRepository {
  static const _localFiles = MethodChannel('file_trash');
  final bool? isAndroid;
  const FileMediaRepository({this.isAndroid});

  Future<AssetEntity?> saveImageWithFile(String filePath, {String? title, String? relativePath}) async {
    final mimeType = await _originalMimeType(File(filePath), 'image/');
    final entity = await PhotoManager.editor.saveImageWithPath(filePath, title: title, relativePath: relativePath);
    await _setOriginalMimeType(entity, mimeType);
    return entity;
  }

  Future<AssetEntity?> saveLivePhoto({required File image, required File video, required String title}) async {
    final entity = await PhotoManager.editor.darwin.saveLivePhoto(imageFile: image, videoFile: video, title: title);
    return entity;
  }

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
