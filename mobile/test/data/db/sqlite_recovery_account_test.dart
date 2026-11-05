import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/sqlite_one_tap_recovery.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';

import 'fixtures/sqlite_account_fixture.dart';
import 'sqlite_one_tap_recovery_test.dart' show FileRecoveryHost;

void main() {
  for (final checkpoint in [false, true]) {
    test('production Drift schema reloads existing login, settings and queues; checkpoint=$checkpoint', () async {
      final directory = await Directory.systemTemp.createTemp('foto23-account-');
      addTearDown(() => directory.delete(recursive: true));
      final source = await createAccountRecoveryFixture(directory, checkpoint: checkpoint);
      const endpoint = 'https://existing.example.test/api';
      final scope = 'sync.trash-reset.${sha256.convert(utf8.encode(endpoint))}/';
      final confirmed = jsonEncode({
        'id': 'confirmed-delete',
        'ownerId': 'existing-owner',
        'checksum': 'deleted-checksum',
        'deletedAt': 1,
        'endpoint': endpoint,
        'permanent': true,
        'permanentComplete': true,
        'localIds': ['deleted-local'],
      });
      final host = FileRecoveryHost(source, Directory('${directory.path}/recovery'));
      if (checkpoint) {
        final before = await recoveryFileHashes(source);
        await expectLater(
          OneTapSqliteRecovery(host).run(),
          throwsA(isA<RecoveryRefused>().having((e) => e.reason, 'reason', 'checkpoint_history_not_terminal')),
        );
        expect(host.selected.path, source.path);
        expect(await recoveryFileHashes(source), before);
        return;
      }
      await OneTapSqliteRecovery(host).run();
      final restored = Drift(NativeDatabase(host.selected));
      final store = await StoreService.create(storeRepository: StoreRepository(restored), listenUpdates: false);
      try {
        final tables =
            (await restored.customSelect("SELECT COUNT(*) AS n FROM sqlite_master WHERE type='table'").getSingle())
                .data['n'];
        final report = host.root
            .listSync(recursive: true)
            .whereType<File>()
            .singleWhere((file) => file.path.endsWith('/recovery-report.json'));
        expect(tables, 33); // Pinned production schema 39, excluding extra rowid/schema fingerprints.
        expect((jsonDecode(report.readAsStringSync()) as Map)['tablesChecked'], tables);
        // AuthGuard checks this exact StoreKey; no login/setup state is recreated.
        expect(store.get(StoreKey.currentUser).id, 'existing-owner');
        await restored.syncStreamRepository.recoverPendingTrashOperations();
        expect((await restored.syncStreamRepository.getPendingTrashOperations()).map((r) => r.id), ['pending-delete']);
        expect((await restored.backupRepository.getCandidates('existing-owner')).map((r) => r.id), ['pending-upload']);
        expect((await restored.backupRepository.getAllCounts('existing-owner')).remainder, 1);
        final receipt = await restored
            .customSelect("SELECT value FROM settings WHERE key='${scope}confirmed-delete'")
            .getSingle();
        expect(receipt.data['value'], confirmed); // acknowledged deletion remains suppressed

        expect(store.get(StoreKey.accessToken), 'synthetic-token-stays-private');
        expect(store.get(StoreKey.serverEndpoint), 'https://existing.example.test/api');
        expect(store.get(StoreKey.deviceId), 'same-device');
        expect(
          (await restored.customSelect("SELECT value FROM settings WHERE key='sync.cursor.regression'").getSingle())
              .data['value'],
          'ack-42',
        );
        expect(
          (await restored.customSelect('SELECT COUNT(*) AS n FROM trashed_local_asset_entity').getSingle()).data['n'],
          1,
        );
      } finally {
        await store.dispose();
        await restored.close();
      }
    });
  }
}
