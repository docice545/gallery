import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:drift/native.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/sqlite_health.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:sqlite3/sqlite3.dart';

import '../sqlite_one_tap_recovery_test.dart' show corruptAlbumIndex;

Future<File> createAccountRecoveryFixture(
  Directory directory, {
  bool checkpoint = false,
  String endpoint = 'https://existing.example.test/api',
}) async {
  final liveDirectory = await Directory('${directory.path}/live').create();
  final live = File('${liveDirectory.path}/immich.sqlite');
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
  await StoreRepository(drift).upsert(StoreKey.serverEndpoint, endpoint);
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
  if (checkpoint) {
    await captureSqliteRecoverySnapshot(
      database: live,
      outputDirectory: Directory('${directory.path}/sqlite-recovery'),
    );
    raw.select('PRAGMA wal_checkpoint(TRUNCATE)');
  }
  final source = File('${directory.path}/immich.sqlite');
  for (final suffix in ['', '-wal', '-shm']) {
    final file = File('${live.path}$suffix');
    if (file.existsSync()) {
      await file.copy('${source.path}$suffix');
    }
  }
  raw.close();
  return source;
}
