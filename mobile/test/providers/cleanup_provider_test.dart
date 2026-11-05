import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/deletion_result.model.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/providers/cleanup.provider.dart';
import 'package:immich_mobile/services/cleanup.service.dart';
import 'package:mocktail/mocktail.dart';

import '../infrastructure/repository.mock.dart';
import '../unit/factories/local_asset_factory.dart';

class _Cleanup extends Mock implements CleanupService {}

void main() {
  final photo = LocalAssetFactory.create(id: 'photo', remoteId: 'remote').copyWith(checksum: 'hash');
  final video = photo.copyWith(id: 'video');
  final candidates = RemovalCandidatesResult(
    assets: [photo, video],
    totalBytes: 300,
    bytesByAssetId: {photo.id: 100, video.id: 200},
  );
  late _Cleanup service;
  late CleanupNotifier notifier;
  late MockSettingsRepository settings;
  var current = true;
  var disposed = false;

  setUpAll(() {
    registerFallbackValue(DateTime(2026));
    registerFallbackValue(AssetKeepType.none);
    registerFallbackValue(() => true);
  });
  setUp(() {
    settings = MockSettingsRepository();
    when(() => settings.appConfig).thenReturn(const AppConfig());
    when(() => settings.write(.cleanupCutoffDaysAgo, any<int>())).thenAnswer((_) async {});
    when(() => settings.write(.cleanupKeepFavorites, any<bool>())).thenAnswer((_) async {});
    when(() => settings.write(.cleanupKeepAlbumIds, any<List<String>>())).thenAnswer((_) async {});
    service = _Cleanup();
    when(
      () => service.getRemovalCandidates(
        any(),
        any(),
        keepMediaType: any(named: 'keepMediaType'),
        keepFavorites: any(named: 'keepFavorites'),
        keepAlbumIds: any(named: 'keepAlbumIds'),
      ),
    ).thenAnswer((_) async => candidates);
    current = true;
    disposed = false;
    notifier = CleanupNotifier(service, 'owner', settings, isCurrent: () => current);
    notifier.setSelectedDate(DateTime(2026));
  });
  tearDown(() {
    if (!disposed) {
      notifier.dispose();
    }
  });

  void stubDeletion(Future<LocalDeletionResult> Function(Invocation) answer) {
    when(
      () => service.deleteVerifiedBackups(
        any(),
        any(),
        any(),
        canContinue: any(named: 'canContinue'),
        keepMediaType: any(named: 'keepMediaType'),
        keepFavorites: any(named: 'keepFavorites'),
        keepAlbumIds: any(named: 'keepAlbumIds'),
      ),
    ).thenAnswer(answer);
  }

  test('late scan cannot overwrite newly chosen exclusions', () async {
    final response = Completer<RemovalCandidatesResult>();
    when(
      () => service.getRemovalCandidates(
        any(),
        any(),
        keepMediaType: any(named: 'keepMediaType'),
        keepFavorites: any(named: 'keepFavorites'),
        keepAlbumIds: any(named: 'keepAlbumIds'),
      ),
    ).thenAnswer((_) => response.future);
    final scan = notifier.scanAssets();
    expect(notifier.state.isScanning, isTrue);
    notifier.setKeepFavorites(false);
    response.complete(candidates);
    await scan;
    expect(notifier.state.keepFavorites, isFalse);
    expect(notifier.state.assetsToDelete, isEmpty);
    expect(notifier.state.isScanning, isFalse);
  });
  test('confirmation of an older preview cannot delete a new selection', () async {
    await notifier.scanAssets();
    final approved = notifier.state;
    notifier.toggleKeepAlbum('protected');
    await notifier.scanAssets();
    expect(await notifier.deleteAssets(expected: approved), 0);
    verifyNever(
      () => service.deleteVerifiedBackups(
        any(),
        any(),
        any(),
        canContinue: any(named: 'canContinue'),
        keepMediaType: any(named: 'keepMediaType'),
        keepFavorites: any(named: 'keepFavorites'),
        keepAlbumIds: any(named: 'keepAlbumIds'),
      ),
    );
  });
  test('partial native receipt retains exact remaining files and their bytes', () async {
    await notifier.scanAssets();
    stubDeletion((_) async => LocalDeletionResult(deletedIds: [photo.id], remainingIds: [video.id]));
    expect(await notifier.deleteAssets(expected: notifier.state), 1);
    expect(notifier.state.assetsToDelete.map((a) => a.id), [video.id]);
    expect(notifier.state.totalBytes, 200);
    expect(notifier.state.isDeleting, isFalse);
  });
  for (final boundary in ['filters', 'account/server', 'dispose', 'reset']) {
    test('$boundary invalidates an in-flight verification before native removal', () async {
      await notifier.scanAssets();
      final response = Completer<LocalDeletionResult>();
      late bool Function() canContinue;
      stubDeletion((call) {
        canContinue = call.namedArguments[#canContinue] as bool Function();
        return response.future;
      });
      final deletion = notifier.deleteAssets();
      expect(canContinue(), isTrue);
      switch (boundary) {
        case 'filters':
          notifier.setKeepFavorites(false);
        case 'account/server':
          current = false;
        case 'dispose':
          notifier.dispose();
          disposed = true;
        case 'reset':
          notifier.reset();
      }
      expect(canContinue(), isFalse);
      if (!disposed) {
        // Reset must not let a second OS request begin while the first is pending.
        notifier.setSelectedDate(DateTime(2026));
        await notifier.scanAssets();
        expect(await notifier.deleteAssets(), 0);
      }
      response.complete(LocalDeletionResult(deletedIds: [], remainingIds: [photo.id, video.id]));
      await deletion;
    });
  }
  test('a failed native/cache operation retains the reviewed files', () async {
    await notifier.scanAssets();
    stubDeletion((_) async => throw StateError('synthetic failure'));
    await expectLater(notifier.deleteAssets(), throwsStateError);
    expect(notifier.state.assetsToDelete.length, 2);
    expect(notifier.state.isDeleting, isFalse);
  });
}
