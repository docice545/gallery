import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:background_downloader/background_downloader.dart';
import 'package:drift/native.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/sqlite_health.dart';
import 'package:immich_mobile/data/db/sqlite_one_tap_recovery.dart';
import 'package:immich_mobile/data/db/sqlite_recovery.dart';
import 'package:immich_mobile/data/db/sqlite_recovery_platform.dart';
import 'package:immich_mobile/data/db/sqlite_recovery_server.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/services/recovery_server.service.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sql;

final class VerifiedRecoveryExport {
  final String token;
  final String zipHash;
  const VerifiedRecoveryExport(this.token, this.zipHash);
}

abstract interface class FreshStartHost {
  RecoveryHost get recovery;
  Future<VerifiedRecoveryExport?> exportVerified();
  Future<({File source, Directory root, String token})> beginFresh(String exportToken);
  Future<void> promoteFresh(String token, File candidate, String hash);
  Future<void> cancelOldUploads();
}

final class AndroidFreshStartHost implements FreshStartHost {
  const AndroidFreshStartHost();
  @override
  RecoveryHost get recovery => const AndroidRecoveryHost();
  @override
  Future<VerifiedRecoveryExport?> exportVerified() async {
    final value = await SqliteRecoveryPlatform.channel.invokeMapMethod<String, String>('exportForFreshStart');
    return value == null ? null : VerifiedRecoveryExport(value['token']!, value['zipHash']!);
  }

  @override
  Future<({File source, Directory root, String token})> beginFresh(String exportToken) async {
    final value = (await SqliteRecoveryPlatform.channel.invokeMapMethod<String, String>('beginFresh', {
      'exportToken': exportToken,
    }))!;
    return (source: File(value['source']!), root: Directory(value['root']!), token: value['token']!);
  }

  @override
  Future<void> promoteFresh(String token, File candidate, String hash) => SqliteRecoveryPlatform.channel.invokeMethod(
    'promoteFresh',
    {'token': token, 'path': candidate.path, 'hash': hash},
  );
  @override
  Future<void> cancelOldUploads() async {
    // Runs only AFTER export and explicit loss consent. Do not import plugin
    // queue records into the clean DB or let old scheduled uploads resume.
    for (final group in [kBackupGroup, kManualUploadGroup]) {
      await FileDownloader().reset(group: group);
      if ((await FileDownloader().allTasks(group: group)).isNotEmpty) {
        throw const RecoveryRefused('old_uploads_not_stopped');
      }
    }
  }
}

final class FreshStartPreparation {
  final VerifiedRecoveryExport export;
  final RecoveryServerCredentials? credentials;
  final UserDto? user;
  const FreshStartPreparation(this.export, {this.credentials, this.user});
  bool get needsLogin => credentials == null || user == null;
}

/// Independent of exact recovery: loss of local state is never labelled repair.
/// Native promotion requires a verified external ZIP capability. Originals and
/// all historical attempts stay in place after the new selector is committed.
final class FreshSqliteStart {
  final FreshStartHost host;
  final Future<void> Function(String)? checkpoint;
  bool _running = false;
  bool _committed = false;
  FreshSqliteStart(this.host, {this.checkpoint});

  Future<FreshStartPreparation?> prepare() async {
    RecoveryServerCredentials? credentials;
    UserDto? user;
    try {
      credentials = await captureRecoveryServerCredentials(host.recovery);
      final client = RecoveryServerClient(credentials);
      try {
        final profile = await client.account();
        if (profile['email'] is! String || profile['name'] is! String || profile['profileChangedAt'] is! String) {
          throw const RecoveryRefused('server_response_invalid');
        }
        user = UserDto(
          id: credentials.ownerId,
          email: profile['email'] as String,
          name: profile['name'] as String,
          profileChangedAt: DateTime.parse(profile['profileChangedAt'] as String),
          isAdmin: profile['isAdmin'] == true,
        );
      } finally {
        client.close();
      }
    } catch (_) {
      // No guessed/older identity. The warning explicitly offers normal login.
      credentials = null;
      user = null;
    }
    final proof = await host.exportVerified();
    return proof == null ? null : FreshStartPreparation(proof, credentials: credentials, user: user);
  }

  Future<void> run(FreshStartPreparation preparation, {required bool consent}) async {
    if (_committed) {
      throw const RecoveryRefused('already_committed');
    }
    if (!consent) {
      throw const RecoveryRefused('fresh_start_consent_required');
    }
    if (_running) {
      throw const RecoveryRefused('already_running');
    }
    _running = true;
    String? token;
    var promoted = false;
    try {
      final session = await host.beginFresh(preparation.export.token);
      token = session.token;
      final before = await recoveryFileHashes(session.source);
      if (await host.recovery.availableBytes() < 64 * 1024 * 1024) {
        throw const RecoveryRefused('insufficient_space');
      }
      await host.cancelOldUploads();
      await checkpoint?.call('uploads_stopped');
      final attempt = await session.root.createTemp('attempt-fresh-');
      final candidate = File(
        p.join((await Directory(p.join(attempt.path, 'candidate')).create()).path, 'immich.sqlite'),
      );
      final fingerprints = await _seedInWorker(candidate.path, preparation.credentials, preparation.user);
      await checkpoint?.call('candidate_ready');
      if (!_same(before, await recoveryFileHashes(session.source))) {
        throw const RecoveryRefused('source_or_backup_changed');
      }
      final receipt = {
        'format': 24,
        'mode': 'fresh_start',
        'outcome': 'validated_new_database',
        'externalZipSha256': preparation.export.zipHash,
        'sourceChecksums': before,
        'explicitLossConsent': true,
        'localStateTransferred': false,
        'sessionVerified': !preparation.needsLogin,
        'backupEnabled': false,
        'localMediaManagementEnabled': false,
      };
      await File(p.join(attempt.path, 'fresh-start-report.json')).writeAsString(jsonEncode(receipt), flush: true);
      await host.recovery.sync(attempt);
      await checkpoint?.call('before_promotion');
      await _validateInWorker(candidate.path, fingerprints);
      await host.promoteFresh(token, candidate, await recoveryFileHash(candidate));
      promoted = true;
      _committed = true;
      SqliteRecoveryGate.clearAfterValidatedRecovery();
    } finally {
      if (token != null && !promoted) {
        await host.recovery.finish(token);
      }
      _running = false;
    }
  }
}

bool _same(Map<String, String> a, Map<String, String> b) =>
    a.length == b.length && a.entries.every((e) => b[e.key] == e.value);
Future<Map<String, String>> _seedInWorker(String file, RecoveryServerCredentials? credentials, UserDto? user) =>
    Isolate.run(() => seedFreshSqliteCandidate(File(file), credentials: credentials, user: user));
Future<void> _validateInWorker(String path, Map<String, String> fingerprints) =>
    Isolate.run(() => validateRecoveredSqlite(File(path), fingerprints));

/// A new generation ONLY. Never passed the source database path by the coordinator.
Future<Map<String, String>> seedFreshSqliteCandidate(
  File file, {
  RecoveryServerCredentials? credentials,
  UserDto? user,
}) async {
  if (file.existsSync()) {
    throw const RecoveryRefused('candidate_already_exists');
  }
  final db = Drift(NativeDatabase(file));
  try {
    final store = StoreRepository(db);
    await store.upsert(StoreKey.manageLocalMediaAndroid, false);
    await store.upsert(StoreKey.recoveryFreshStartReview, true);
    await store.upsert(StoreKey.recoveryFreshStartNeedsSync, true);
    await store.upsert(StoreKey.recoveryFreshStartLibraryReady, false);
    if (credentials != null && user != null) {
      if (credentials.ownerId != user.id) {
        throw const RecoveryRefused('server_owner_mismatch');
      }
      await store.upsert(StoreKey.currentUser, user);
      await store.upsert(StoreKey.accessToken, credentials.token);
      await store.upsert(StoreKey.serverEndpoint, credentials.endpoint.toString());
      await store.upsert(
        StoreKey.serverUrl,
        credentials.endpoint.replace(path: credentials.endpoint.path.replaceFirst(RegExp(r'/api/?$'), '')).toString(),
      );
    }
    for (final key in [SettingsKey.backupEnabled, SettingsKey.backupSyncAlbums]) {
      await db.customStatement('INSERT INTO settings(key,value) VALUES (?,?)', [key.name, key.encode(false)]);
    }
  } finally {
    await db.close();
  }
  final raw = sql.sqlite3.open(file.path);
  late Map<String, String> fingerprints;
  try {
    raw.execute('PRAGMA synchronous=FULL');
    if (raw.select('PRAGMA wal_checkpoint(TRUNCATE)').single.values.first != 0) {
      throw const RecoveryRefused('candidate_checkpoint_busy');
    }
    fingerprints = fingerprintSqliteTables(raw);
  } finally {
    raw.close();
  }
  validateRecoveredSqlite(file, fingerprints);
  return fingerprints;
}
