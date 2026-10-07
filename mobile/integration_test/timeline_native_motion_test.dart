import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/platform/network_api.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/video_viewer.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/live_photo_scope.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:integration_test/integration_test.dart';
import 'package:logging/logging.dart';
import 'package:mocktail/mocktail.dart';

import '../test/service.mocks.dart';
import '../test/unit/factories/remote_asset_factory.dart';
import 'test_utils/native_motion_fixture.dart';

/// Real Android ExoPlayer + HTTP + PlatformView, with only the asset lookup
/// replaced. No production credentials/media/server, no mocked native channels.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('native timeline motion decodes, advances and ends once without cascading', (tester) async {
    final bytes = base64Decode(nativeMotionFixtureBase64);
    final db = Drift(drift.DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await SettingsRepository.ensureInitialized(db);
    await StoreService.init(storeRepository: StoreRepository(db), listenUpdates: false);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final endpoint = 'http://127.0.0.1:${server.port}/api';
    const token = 'synthetic-native-smoke-token';
    await Store.put(StoreKey.serverEndpoint, endpoint);
    await Store.put(StoreKey.accessToken, token);
    await SettingsRepository.instance.write(SettingsKey.timelineAutoplayLivePhotos, true);
    await NetworkApi().setRequestHeaders({'X-Gallery-Smoke': 'true'}, [endpoint], token);
    var authorizedReads = 0;
    final serving = server.listen((request) async {
      if (!request.uri.path.endsWith('/video/playback') ||
          request.headers.value('X-Gallery-Smoke') != 'true' ||
          !(request.headers.value('Cookie') ?? '').contains('immich_access_token=$token')) {
        request.response.statusCode = 403;
        await request.response.close();
        return;
      }
      authorizedReads++;
      var start = 0;
      var end = bytes.length - 1;
      final range = request.headers.value('Range');
      if (range != null) {
        final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
        if (match != null) {
          start = int.parse(match[1]!);
          if (match[2]!.isNotEmpty) {
            end = int.parse(match[2]!).clamp(start, bytes.length - 1);
          }
          request.response.statusCode = 206;
          request.response.headers.set('Content-Range', 'bytes $start-$end/${bytes.length}');
        }
      }
      request.response.headers.contentType = ContentType('video', 'mp4');
      request.response.headers.set('Accept-Ranges', 'bytes');
      request.response.contentLength = end - start + 1;
      request.response.add(bytes.sublist(start, end + 1));
      await request.response.close();
    });
    final assets = [
      for (var i = 0; i < 2; i++)
        RemoteAssetFactory.create(id: 'native-$i').copyWith(livePhotoVideoId: 'motion-$i', width: 4000, height: 3000),
    ];
    final lookup = MockAssetService();
    registerFallbackValue(assets.first);
    when(() => lookup.getAsset(any())).thenAnswer((call) async => call.positionalArguments.first as BaseAsset);
    final container = ProviderContainer(overrides: [assetServiceProvider.overrideWithValue(lookup)]);
    final stages = <String>[];
    final previousLevel = Logger.root.level;
    Logger.root.level = Level.INFO;
    final events = Logger('NativeVideoViewer').onRecord.listen((record) => stages.add(record.message));
    var advanced = false;
    try {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: TimelineLivePhotoScope(
                child: ListView(
                  children: [
                    for (final asset in assets)
                      SizedBox(
                        height: 240,
                        child: Stack(
                          children: [
                            const Positioned.fill(child: ColoredBox(color: Colors.grey)),
                            Positioned.fill(
                              child: TimelineLivePhotoTile(
                                asset: asset,
                                framingImageSize: const Size(4000, 3000),
                                requireMatchingFraming: true,
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 500),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 150 && !stages.contains('Timeline motion: finished:ended'); i++) {
        await tester.pump(const Duration(milliseconds: 100));
        for (final asset in assets) {
          final state = container.read(timelinePreviewVideoPlayerProvider(asset.id));
          advanced = advanced || state.position > Duration.zero;
        }
      }
      expect(authorizedReads, greaterThan(0), reason: 'the authenticated native HTTP media source must actually open');
      expect(
        advanced,
        isTrue,
        reason: 'native decoded playback position must advance, not just a mocked ready callback',
      );
      expect(stages.where((stage) => stage == 'Timeline motion: selected'), hasLength(1));
      expect(stages.where((stage) => stage == 'Timeline motion: finished:ended'), hasLength(1));
      expect(stages, isNot(contains('Timeline motion: finished:timeout')));
      expect(find.byType(NativeVideoViewer), findsNothing);
      await tester.pump(const Duration(seconds: 2));
      expect(
        stages.where((stage) => stage == 'Timeline motion: selected'),
        hasLength(1),
        reason: 'ending a clip cannot cascade to the second visible Live Photo',
      );
      expect(stages.where((stage) => stage == 'Timeline motion: finished:ended'), hasLength(1));
    } finally {
      await tester.pumpWidget(const SizedBox());
      await events.cancel();
      Logger.root.level = previousLevel;
      container.dispose();
      await serving.cancel();
      await server.close(force: true);
      await NetworkApi().setRequestHeaders({}, [], null);
      await SettingsRepository.reset();
      await Store.clear();
      await db.close();
    }
  });
}
