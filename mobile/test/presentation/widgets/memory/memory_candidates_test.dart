import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/memory.model.dart';
import 'package:immich_mobile/presentation/widgets/memory/memory_candidates.widget.dart';
import 'package:immich_mobile/providers/infrastructure/memory.provider.dart';
import 'package:immich_mobile/repositories/memory_api.repository.dart';
import 'package:mocktail/mocktail.dart';

import '../../../unit/presentation/presentation_context.dart';

class _MemoryApi extends Mock implements MemoryApiRepository {}

void main() {
  for (final (action, label) in [('save', 'Save'), ('dismiss', 'Do not save'), ('later', 'Later')]) {
    testWidgets('$action waits for server acknowledgement before removing the card', (tester) async {
      final context = await PresentationContext.create();
      final api = _MemoryApi();
      final acknowledgement = Completer<void>();
      var pending = true;
      final memory = Memory(
        id: 'memory',
        ownerId: context.currentUser.id,
        type: MemoryTypeEnum.rule,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        memoryAt: DateTime(2025),
        isSaved: false,
        data: const MemoryData({'title': 'A day by the sea', 'subtitle': 'Together', 'candidateState': 'pending'}),
        assets: const [],
      );
      when(() => api.decideCandidate('candidate', action)).thenAnswer((_) async {
        await acknowledgement.future;
        pending = false;
      });
      try {
        await tester.pumpTestWidget(
          context,
          const MemoryCandidates(),
          overrides: [
            memoryCandidatesProvider.overrideWith((ref) async => pending ? [(id: 'candidate', memory: memory)] : []),
            memoryApiRepositoryProvider.overrideWithValue(api),
          ],
        );
        expect(find.text('A day by the sea'), findsOneWidget);
        await tester.tap(find.text(label));
        await tester.pump();
        verify(() => api.decideCandidate('candidate', action)).called(1);
        expect(find.text('A day by the sea'), findsOneWidget);
        expect(tester.widget<TextButton>(find.widgetWithText(TextButton, label)).onPressed, isNull);
        acknowledgement.complete();
        await tester.pumpAndSettle();
        expect(find.text('A day by the sea'), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await context.dispose();
      }
    });
  }
}
