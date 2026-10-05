import 'dart:async';
import 'dart:convert';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';
import 'package:immich_mobile/services/background_upload.service.dart';
import 'package:mocktail/mocktail.dart';

import '../infrastructure/repository.mock.dart';
import '../repository.mocks.dart';

class _CallbackUploadRepository extends Mock implements UploadRepository {
  @override
  void Function(TaskStatusUpdate)? onUploadStatus;
  @override
  void Function(TaskProgressUpdate)? onTaskProgress;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _CallbackUploadRepository uploads;
  late MockStorageRepository storage;
  late MockLocalAssetRepository assets;
  late BackgroundUploadService service;

  setUp(() {
    uploads = _CallbackUploadRepository();
    storage = MockStorageRepository();
    assets = MockLocalAssetRepository();
    service = BackgroundUploadService(uploads, storage, assets, MockBackupRepository(), MockAssetMediaRepository());
  });

  tearDown(() async => service.stopAndDrain());

  TaskStatusUpdate livePhotoComplete() => TaskStatusUpdate(
    UploadTask(
      url: 'https://gallery.invalid/api/assets',
      filename: 'motion.mov',
      metaData: jsonEncode(
        const UploadTaskMetadata(localAssetId: 'local-live', isLivePhotos: true, livePhotoVideoId: '').toMap(),
      ),
    ),
    TaskStatus.complete,
    null,
    jsonEncode({'id': 'remote-motion'}),
  );

  test('shutdown drains active paired-upload DB callback and rejects follow-up work', () async {
    final dbRead = Completer<LocalAsset?>();
    when(() => assets.getById('local-live')).thenAnswer((_) => dbRead.future);
    uploads.onUploadStatus!(livePhotoComplete());
    await Future<void>.delayed(Duration.zero);
    verify(() => assets.getById('local-live')).called(1);
    var drained = false;
    final shutdown = service.stopAndDrain().then((_) => drained = true);
    await Future<void>.delayed(Duration.zero);
    expect(drained, isFalse);
    expect(uploads.onUploadStatus, isNull);
    expect(uploads.onTaskProgress, isNull);
    dbRead.complete(null);
    await shutdown;
    expect(drained, isTrue);
    verifyNever(() => storage.getFileForAsset(any()));
    verifyNever(() => uploads.enqueueBackgroundAll(any()));
    verifyNever(() => storage.clearCache());
    verifyNever(() => uploads.reset(any()));
  });

  test('a retained late native callback cannot access DB after shutdown', () async {
    final lateNativeCallback = uploads.onUploadStatus!;
    await service.stopAndDrain();
    lateNativeCallback(livePhotoComplete());
    await Future<void>.delayed(Duration.zero);
    verifyNever(() => assets.getById(any()));
    verifyNever(() => uploads.enqueueBackgroundAll(any()));
  });

  test('shutdown is idempotent and does not cancel independent URLSession transfers', () async {
    await Future.wait([service.stopAndDrain(), service.stopAndDrain()]);
    service.dispose();
    expect(await service.enqueueTasks([]), isEmpty);
    await service.resume();
    verifyNever(() => uploads.enqueueBackgroundAll(any()));
    verifyNever(() => uploads.reset(any()));
    verifyNever(() => uploads.deleteDatabaseRecords(any()));
    verifyNever(() => uploads.start());
    verifyNever(() => storage.clearCache());
  });
}
