import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/memory.model.dart';
import 'package:immich_mobile/domain/services/memory.service.dart';
import 'package:immich_mobile/presentation/widgets/memory/memory_actions.widget.dart';
import 'package:immich_mobile/providers/infrastructure/memory.provider.dart';
import 'package:mocktail/mocktail.dart';

import '../../../unit/presentation/presentation_context.dart';

class _MemoryService extends Mock implements MemoryService {}

class _MemorySurface extends ConsumerWidget {
  const _MemorySurface({required this.memory, required this.onRemoved, required this.onPausedChanged});

  final Memory memory;
  final VoidCallback onRemoved;
  final ValueChanged<bool> onPausedChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lane = ref.watch(visibleMemoryLaneProvider).value ?? const [];
    final list = ref.watch(visibleAllMemoriesProvider(false)).value ?? const [];
    return Column(
      children: [
        Text('lane:${lane.map((memory) => memory.id).join(',')}'),
        Text('list:${list.map((memory) => memory.id).join(',')}'),
        MemoryActions(memory: memory, onRemoved: onRemoved, onPausedChanged: onPausedChanged),
      ],
    );
  }
}

void main() {
  Memory memory(String ownerId, {bool ai = false}) => Memory(
    id: ai ? 'highlight' : 'two-years-ago',
    ownerId: ownerId,
    type: ai ? MemoryTypeEnum.rule : MemoryTypeEnum.onThisDay,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
    memoryAt: DateTime.utc(2024),
    isSaved: false,
    data: ai ? const MemoryData({'ruleId': 'gallery_ai_highlight'}) : const MemoryData({'year': 2024}),
    assets: [
      RemoteAsset(
        id: 'original-photo',
        ownerId: ownerId,
        name: 'photo.jpg',
        checksum: 'original',
        type: AssetType.image,
        createdAt: DateTime.utc(2024),
        updatedAt: DateTime.utc(2024),
        isEdited: false,
      ),
    ],
  );

  for (final ai in [false, true]) {
    for (final action in ['hide', 'delete']) {
      testWidgets('$action ${ai ? 'AI highlight' : 'two-years-ago'} waits for acknowledgement and removes lane/list', (
        tester,
      ) async {
        final context = await PresentationContext.create();
        final service = _MemoryService();
        final selected = memory(context.currentUser.id, ai: ai);
        final acknowledgement = Completer<void>();
        final pauses = <bool>[];
        var removed = 0;
        when(() => service.hide(selected.id)).thenAnswer((_) => acknowledgement.future);
        when(() => service.delete(selected.id)).thenAnswer((_) => acknowledgement.future);
        try {
          await tester.pumpTestWidget(
            context,
            _MemorySurface(memory: selected, onRemoved: () => removed++, onPausedChanged: pauses.add),
            overrides: [
              memoryManagementServiceProvider.overrideWithValue(service),
              // A stale server response stays stale even after invalidation: confirmed
              // session tombstones must still hide it on both surfaces immediately.
              memoryLaneProvider.overrideWith((ref) async => [selected]),
              allMemoriesProvider.overrideWith((ref, onlyFavorites) async => [selected]),
            ],
          );
          expect(find.text('lane:${selected.id}'), findsOneWidget);
          expect(find.text('list:${selected.id}'), findsOneWidget);
          await tester.tap(find.byIcon(Icons.more_vert));
          await tester.pumpAndSettle();
          expect(pauses.last, isTrue);
          final label = action == 'hide' ? 'Do not show this memory' : 'Delete memory';
          await tester.tap(find.text(label));
          if (action == 'delete') {
            await tester.pumpAndSettle();
            expect(find.text('Delete this memory?'), findsOneWidget);
            expect(find.text('Photos and videos in your library will not be deleted.'), findsOneWidget);
            verifyNever(() => service.delete(any()));
            expect(pauses.last, isTrue);
            await tester.tap(find.widgetWithText(TextButton, 'Delete memory'));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
          } else {
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 350));
          }
          if (action == 'hide') {
            verify(() => service.hide(selected.id)).called(1);
            verifyNever(() => service.delete(any()));
          } else {
            verify(() => service.delete(selected.id)).called(1);
            verifyNever(() => service.hide(any()));
          }
          expect(removed, 0);
          expect(find.text('lane:${selected.id}'), findsOneWidget);
          expect(find.text('list:${selected.id}'), findsOneWidget);
          expect(pauses.last, isTrue);
          acknowledgement.complete();
          await tester.pumpAndSettle();
          expect(removed, 1);
          expect(find.text('lane:'), findsOneWidget);
          expect(find.text('list:'), findsOneWidget);
          expect(pauses.last, isTrue, reason: 'The removed viewer must stay paused through its pop animation');
          expect(selected.assets.single.id, 'original-photo');
        } finally {
          await tester.pumpWidget(const SizedBox());
          await context.dispose();
        }
      });
    }
  }

  testWidgets('cancel deletion keeps the memory and resumes playback', (tester) async {
    final context = await PresentationContext.create();
    final service = _MemoryService();
    final selected = memory(context.currentUser.id);
    final pauses = <bool>[];
    var removed = 0;
    try {
      await tester.pumpTestWidget(
        context,
        MemoryActions(memory: selected, onRemoved: () => removed++, onPausedChanged: pauses.add),
        overrides: [memoryManagementServiceProvider.overrideWithValue(service)],
      );
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete memory'));
      await tester.pumpAndSettle();
      expect(pauses.last, isTrue);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      verifyNever(() => service.delete(any()));
      expect(removed, 0);
      expect(pauses, [true, false]);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await context.dispose();
    }
  });

  testWidgets('dismissing the menu resumes without making a request', (tester) async {
    final context = await PresentationContext.create();
    final service = _MemoryService();
    final pauses = <bool>[];
    try {
      await tester.pumpTestWidget(
        context,
        MemoryActions(memory: memory(context.currentUser.id), onRemoved: () {}, onPausedChanged: pauses.add),
        overrides: [memoryManagementServiceProvider.overrideWithValue(service)],
      );
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(5, 500));
      await tester.pumpAndSettle();
      expect(pauses, [true, false]);
      verifyNever(() => service.hide(any()));
      verifyNever(() => service.delete(any()));
    } finally {
      await tester.pumpWidget(const SizedBox());
      await context.dispose();
    }
  });

  testWidgets('failed request preserves lane/list and shows an error', (tester) async {
    final context = await PresentationContext.create();
    final service = _MemoryService();
    final selected = memory(context.currentUser.id);
    final pauses = <bool>[];
    var removed = 0;
    when(() => service.hide(selected.id)).thenThrow(Exception('offline'));
    try {
      await tester.pumpTestWidget(
        context,
        _MemorySurface(memory: selected, onRemoved: () => removed++, onPausedChanged: pauses.add),
        overrides: [
          memoryManagementServiceProvider.overrideWithValue(service),
          memoryLaneProvider.overrideWith((ref) async => [selected]),
          allMemoriesProvider.overrideWith((ref, onlyFavorites) async => [selected]),
        ],
      );
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Do not show this memory'));
      await tester.pumpAndSettle();
      expect(find.text('lane:${selected.id}'), findsOneWidget);
      expect(find.text('list:${selected.id}'), findsOneWidget);
      expect(find.text('Could not update this memory. Please try again.'), findsOneWidget);
      expect(removed, 0);
      expect(pauses.last, isFalse);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await context.dispose();
    }
  });

  testWidgets('shared Space memories do not expose owner-only destructive actions', (tester) async {
    final context = await PresentationContext.create();
    try {
      await tester.pumpTestWidget(context, MemoryActions(memory: memory('space-owner'), onRemoved: () {}));
      expect(find.byIcon(Icons.more_vert), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await context.dispose();
    }
  });
}
