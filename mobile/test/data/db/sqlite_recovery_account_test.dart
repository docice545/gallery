import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/sqlite_one_tap_recovery.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
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
