import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/sqlite_fresh_start.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/presentation/widgets/backup/backup_toggle_button.widget.dart';

void main() {
  testWidgets('fresh library must finish downloading and be separately reviewed before backup', (tester) async {
    await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp('foto24-review-');
      final file = File('${directory.path}/immich.sqlite');
      await seedFreshSqliteCandidate(file);
      final db = Drift(NativeDatabase(file));
      final store = StoreRepository(db);
      addTearDown(() async {
        await db.close();
        await directory.delete(recursive: true);
      });
      Future<bool>? decision;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => decision = confirmFreshBackupReview(context, store),
              child: const Text('Enable'),
            ),
          ),
        ),
      );
      Future<void> openReview() async {
        await tester.tap(find.text('Enable'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pumpAndSettle();
      }

      await openReview();
      expect(find.text('sqlite_fresh_wait_library'), findsOneWidget);
      await tester.tap(find.text('ok'));
      await tester.pumpAndSettle();
      expect(await decision!, false);
      expect(await store.tryGet(StoreKey.recoveryFreshStartReview), true);
      await store.upsert(StoreKey.recoveryFreshStartLibraryReady, true);
      await openReview();
      expect(find.text('sqlite_fresh_review_warning'), findsOneWidget);
      await tester.tap(find.text('cancel'));
      await tester.pumpAndSettle();
      expect(await decision!, false);
      expect(await store.tryGet(StoreKey.recoveryFreshStartReview), true);
      await openReview();
      await tester.tap(find.text('sqlite_fresh_review_confirm'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(await decision!, true);
      expect(await store.tryGet(StoreKey.recoveryFreshStartReview), false);
    });
  });
}
