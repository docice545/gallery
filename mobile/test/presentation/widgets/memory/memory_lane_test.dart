import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/memory.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/presentation/widgets/memory/memory_lane.widget.dart';
import 'package:immich_mobile/providers/infrastructure/memory.provider.dart';

import '../../../test_utils.dart';

Memory _memory(String id) => Memory(
  id: id,
  createdAt: DateTime(2024),
  updatedAt: DateTime(2024),
  ownerId: 'owner',
  type: MemoryTypeEnum.onThisDay,
  data: const MemoryData({'title': 'A long memory title that wraps safely'}),
  isSaved: false,
  memoryAt: DateTime(2024),
  assets: [TestUtils.createRemoteAsset(id: 'asset-$id')],
);

Memory _emptyMemory() => Memory(
  id: 'empty',
  createdAt: DateTime(2024),
  updatedAt: DateTime(2024),
  ownerId: 'owner',
  type: MemoryTypeEnum.onThisDay,
  data: const MemoryData({'title': 'A long memory title that wraps safely'}),
  isSaved: false,
  memoryAt: DateTime(2024),
  assets: const [],
);

void main() {
  late Drift db;
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestUtils.init();
    db = Drift(drift.DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await StoreService.init(storeRepository: StoreRepository(db), listenUpdates: false);
    // MemoryCard creates a RemoteImageProvider synchronously. Give the URL
    // builder the same deterministic endpoint used by other widget tests;
    // TestUtils' HTTP override then supplies the transparent fixture.
    await Store.put(StoreKey.serverEndpoint, 'http://localhost:0');
  });

  tearDownAll(() async {
    await Store.clear();
    await db.close();
  });

  testWidgets('uses a stable portrait card size and exposes adjacent cards', (tester) async {
    for (final width in [320.0, 390.0, 600.0]) {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            visibleMemoryLaneProvider.overrideWithValue(
              AsyncData([_memory('one'), _memory('two'), _memory('three'), _memory('four'), _memory('five')]),
            ),
            memoryCandidatesProvider.overrideWith((ref) async => const []),
          ],
          child: MaterialApp(
            home: SizedBox(
              width: width,
              child: MemoryLane(
                thumbnailBuilder: (_) => const ColoredBox(color: Colors.blue),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final laneFinder = find.byType(ListView);
      final lane = tester.widget<ListView>(laneFinder);
      expect(lane.scrollDirection, Axis.horizontal);
      expect(tester.getSize(laneFinder).height, memoryLaneMaxHeight);

      final cards = find.byType(MemoryCard);
      expect(cards, findsAtLeastNWidgets(2));
      final firstSize = tester.getSize(cards.at(0));
      expect(firstSize.width / firstSize.height, closeTo(MemoryCard.aspectRatio, 0.01));
      expect(firstSize.height, lessThanOrEqualTo(memoryLaneMaxHeight));
      expect(tester.getSize(cards.at(1)), firstSize);

      final firstBeforeScroll = tester.getRect(cards.at(0));
      await tester.drag(laneFinder, const Offset(-80, 0));
      await tester.pumpAndSettle();
      expect(tester.getRect(cards.at(0)).left, lessThan(firstBeforeScroll.left));
      expect(tester.getSize(cards.at(0)), firstSize);
    }
  });

  testWidgets('long titles remain inside the rounded card', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 148,
          height: 200,
          child: MemoryCard(memory: _emptyMemory()),
        ),
      ),
    );
    await tester.pump();

    final title = tester.widget<Text>(find.text('A long memory title that wraps safely'));
    expect(title.maxLines, 3);
    expect(title.overflow, TextOverflow.ellipsis);
    expect(tester.takeException(), isNull);
  });
}
