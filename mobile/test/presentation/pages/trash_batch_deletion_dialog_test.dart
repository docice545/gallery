import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/deletion_result.model.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/pages/trash.page.dart';
import 'package:mocktail/mocktail.dart';

import '../../service.mocks.dart';
import '../../widget_tester_extensions.dart';

void main() {
  testWidgets('shows progress, cancels after batch id, and does not retry the selection', (tester) async {
    final service = MockAssetService();
    final operation = Completer<List<PermanentDeletionResult>>();
    const ids = ['asset-1', 'asset-2'];
    const active = PermanentDeletionBatchStatus(
      id: 'batch-1',
      state: 'active',
      total: 2,
      processed: 1,
      complete: 1,
      failed: 0,
      pending: 1,
      cancelRequested: false,
    );
    const cancelled = PermanentDeletionBatchStatus(
      id: 'batch-1',
      state: 'active',
      total: 2,
      processed: 1,
      complete: 1,
      failed: 0,
      pending: 1,
      cancelRequested: true,
    );
    when(() => service.deleteWithResults(any(), onBatchStatus: any(named: 'onBatchStatus'))).thenAnswer((invocation) {
      final onBatchStatus = invocation.namedArguments[#onBatchStatus] as void Function(PermanentDeletionBatchStatus);
      onBatchStatus(active);
      return operation.future;
    });
    when(() => service.cancelDeletionBatch('batch-1')).thenAnswer((_) async => cancelled);

    final controller = BatchDeletionController(service, ids)..start();
    await tester.pumpConsumerWidgetRaw(BatchDeletionDialog(controller: controller));

    final context = tester.element(find.byType(BatchDeletionDialog));
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(tester.widget<TextButton>(find.byType(TextButton)).onPressed, isNotNull);
    expect(find.text(context.t.canceled), findsNothing);

    await tester.tap(find.widgetWithText(TextButton, context.t.cancel));
    await tester.pump();

    expect(find.text(context.t.canceled), findsOneWidget);
    expect(tester.widget<TextButton>(find.byType(TextButton)).onPressed, isNull);
    expect(controller.ids, ids);
    verify(() => service.cancelDeletionBatch('batch-1')).called(1);
    verify(() => service.deleteWithResults(any(), onBatchStatus: any(named: 'onBatchStatus'))).called(1);
    expect(tester.takeException(), isNull);
  });
}
