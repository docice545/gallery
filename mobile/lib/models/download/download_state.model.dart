import 'package:background_downloader/background_downloader.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:immich_mobile/platform/live_photo_save_api.g.dart';

part 'download_state.model.freezed.dart';

@freezed
abstract class DownloadInfo with _$DownloadInfo {
  const factory DownloadInfo({
    required String fileName,
    required double progress,
    required TaskStatus status,
    LivePhotoSaveOutcome? livePhotoOutcome,
  }) = _DownloadInfo;
}

@freezed
abstract class DownloadState with _$DownloadState {
  const factory DownloadState({
    required TaskStatus downloadStatus,
    required Map<String, DownloadInfo> taskProgress,
    required bool showProgress,
  }) = _DownloadState;
}
