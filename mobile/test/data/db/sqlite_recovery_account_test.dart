import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/sqlite_one_tap_recovery.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:sqlite3/sqlite3.dart';

import 'sqlite_one_tap_recovery_test.dart' show FileRecoveryHost, corruptAlbumIndex;

void main() {
  test('production Drift schema reloads existing login, settings and queues after promotion', () async {
    final directory = await Directory.systemTemp.createTemp('foto23-account-');
    addTearDown(() => directory.delete(recursive: true));
    final live = File('${directory.path}/live.sqlite');
    final drift = Drift(NativeDatabase(live));
    // Real migrations and real StoreRepository encoding used by Bootstrap.
    await StoreRepository(drift).upsert(
      StoreKey.currentUser,
      UserDto(
        id: 'existing-owner',
        email: 'owner@example.test',
        name: 'Existing owner',
        profileChangedAt: DateTime.utc(2026, 10, 30),
      ),
    );
    await StoreRepository(drift).upsert(StoreKey.accessToken, 'synthetic-token-stays-private');
    await StoreRepository(drift).upsert(StoreKey.serverEndpoint, 'https://existing.example.test/api');
    await StoreRepository(drift).upsert(StoreKey.deviceId, 'same-device');
    await drift.customStatement(
      "INSERT INTO trashed_local_asset_entity (id,album_id,name,type,created_at,updated_at,width,height,duration_ms,source) VALUES ('asset-1','local-album','photo.jpg',1,1,1,100,100,0,2)",
    );
    await drift.close();
    await corruptAlbumIndex(live);
    final raw = sqlite3.open(live.path);
    raw.execute('PRAGMA wal_autocheckpoint=0');
    raw.execute(
      "INSERT INTO settings(key,value) VALUES ('sync.cursor.regression','ack-42'),('sync.pending.regression','upload-and-delete')",
    );
    raw.execute("INSERT INTO local_album_entity(id,name,backup_selection) VALUES ('local-album','Unsynced album',0)");
    raw.execute(
      "INSERT INTO local_asset_entity(id,name,type,checksum) VALUES ('pending-upload','pending.jpg',1,'pending-checksum'),('deleted-local','deleted.jpg',1,'deleted-checksum')",
    );
    raw.execute(
      "INSERT INTO local_album_asset_entity(asset_id,album_id) VALUES ('pending-upload','local-album'),('deleted-local','local-album')",
    );
    const endpoint = 'https://existing.example.test/api';
    final scope = 'sync.trash-reset.${sha256.convert(utf8.encode(endpoint))}/';
    final pending = jsonEncode({
      'id': 'pending-delete',
      'ownerId': 'existing-owner',
      'checksum': 'pending-delete-checksum',
      'deletedAt': 1,
      'endpoint': endpoint,
      'operation': 'trash',
      'phase': 'inFlight',
    });
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
    raw.execute('INSERT INTO settings(key,value) VALUES (?,?),(?,?)', [
      '${scope}pending-delete',
      pending,
      '${scope}confirmed-delete',
      confirmed,
    ]);
    final source = File('${directory.path}/immich.sqlite');
    for (final suffix in ['', '-wal', '-shm']) {
      final file = File('${live.path}$suffix');
      if (file.existsSync()) {
        await file.copy('${source.path}$suffix');
      }
    }
    raw.close();
    final host = FileRecoveryHost(source, Directory('${directory.path}/recovery'));
    await OneTapSqliteRecovery(host).run();
    final restored = Drift(NativeDatabase(host.selected));
    final store = await StoreService.create(storeRepository: StoreRepository(restored), listenUpdates: false);
    try {
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
