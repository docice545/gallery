import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/sqlite_one_tap_recovery.dart';
import 'package:immich_mobile/data/db/sqlite_recovery_server.dart';
import 'package:immich_mobile/services/recovery_server.service.dart';
import 'package:sqlite3/sqlite3.dart';

import 'fixtures/recovery_http_server.dart';
import 'fixtures/sqlite_account_fixture.dart';
import 'sqlite_one_tap_recovery_test.dart' show FileRecoveryHost;

void main() {
  for (final emptyWal in [false, true]) {
    test('saved production account; server GETs only, no source writes; empty WAL=$emptyWal', () async {
      final directory = await Directory.systemTemp.createTemp('foto24-server-');
      addTearDown(() => directory.delete(recursive: true));
      final server = await RecoveryHttpServer.start();
      addTearDown(server.close);
      final source = await createAccountRecoveryFixture(directory, checkpoint: emptyWal, endpoint: server.endpoint);
      if (emptyWal) {
        // Actual Build 23 read-only probe discards the checkpoint SHM witness.
        final probe = sqlite3.open(source.path, mode: OpenMode.readOnly);
        probe.select('PRAGMA quick_check(1)');
        probe.close();
        expect(
          await recoveryFileHash(File('${source.path}-shm')),
          'fd4c9fda9cd3f9ae7c962b0ddf37232294d55580e1aa165aa06129b8549389eb',
        );
      }
      final before = await recoveryFileHashes(source);
      final host = FileRecoveryHost(source, Directory('${directory.path}/recovery'));
      final credentials = await captureRecoveryServerCredentials(host);
      expect(credentials.ownerId, 'existing-owner');
      expect(credentials.toString(), isNot(contains('synthetic-token')));
      final client = RecoveryServerClient(credentials);
      addTearDown(client.close);
      final buckets = await client.buckets();
      final photos = await client.photos(buckets.single);
      expect(photos.map((p) => p.id), [RecoveryHttpServer.photoId]);
      expect(await client.image(photos.single), isNotEmpty);
      expect(await client.image(photos.single, preview: true), isNotEmpty);
      await expectLater(
        client.image(const RecoveryServerPhoto(RecoveryHttpServer.otherId, true)),
        throwsA(isA<RecoveryRefused>()),
      );
      expect(server.requests.every((r) => r.method == 'GET' && r.authenticated), true);
      final query = server.requests.firstWhere((r) => r.uri.path.endsWith('/buckets')).uri.queryParameters;
      expect(query, containsPair('bucketSize', 'month'));
      expect(query, containsPair('order', 'desc'));
      expect(query, containsPair('userId', 'existing-owner'));
      expect(await recoveryFileHashes(source), before);
      expect(host.blocked, true);
      expect(host.selected.path, source.path);
      final report = host.root
          .listSync(recursive: true)
          .whereType<File>()
          .singleWhere((f) => f.path.endsWith('server-view-report.json'));
      expect(report.readAsStringSync(), isNot(contains('synthetic-token')));
      expect(jsonDecode(report.readAsStringSync())['primaryPromoted'], false);
    });
  }

  for (final mode in ['unauthorized', 'redirect', 'wrong_owner']) {
    test('server $mode fails closed without redirect, account substitution or sync', () async {
      final server = await RecoveryHttpServer.start();
      addTearDown(server.close);
      server.mode = mode;
      final client = RecoveryServerClient(
        RecoveryServerCredentials('existing-owner', 'synthetic-token-stays-private', Uri.parse(server.endpoint)),
      );
      addTearDown(client.close);
      await expectLater(client.buckets(), throwsA(isA<RecoveryRefused>()));
      await expectLater(client.photos('2026-10-01'), throwsA(isA<RecoveryRefused>()));
      expect(server.requests.length, 1);
      expect(server.requests.single.uri.path, '/api/users/me');
    });
  }
  test('session unavailable or insufficient space never creates a replacement database', () async {
    final directory = await Directory.systemTemp.createTemp('foto24-no-session-');
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/immich.sqlite');
    final db = sqlite3.open(source.path);
    db.execute('CREATE TABLE unrelated(id INTEGER)');
    db.close();
    final before = await recoveryFileHashes(source);
    final host = FileRecoveryHost(source, Directory('${directory.path}/recovery'));
    await expectLater(
      captureRecoveryServerCredentials(host),
      throwsA(isA<RecoveryRefused>().having((e) => e.reason, 'reason', 'server_credentials_unavailable')),
    );
    host.space = 0;
    await expectLater(
      captureRecoveryServerCredentials(host),
      throwsA(isA<RecoveryRefused>().having((e) => e.reason, 'reason', 'insufficient_space')),
    );
    expect(await recoveryFileHashes(source), before);
    expect(host.selection.existsSync(), false);
    expect(host.blocked, true);
  });
}
