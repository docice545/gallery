import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/data/db/sqlite_health.dart';
import 'package:immich_mobile/data/db/sqlite_recovery_platform.dart';
import 'package:sqlite3/common.dart';
import 'package:sqlite_async/sqlite_async.dart';

/// Photo Picker reads use the already admitted Flutter pool and its SQLite
/// library. Android's independent SQLiteDatabase must never open this WAL file.
/// No mirror, extra pool, file copy, checkpoint or source-file descriptor.
final class SqliteCloudReader {
  final SqliteConnection connection;
  final Set<Future<Object?>> _pending = {};
  bool _closing = false;
  final int schemaVersion;
  SqliteCloudReader(this.connection, {required this.schemaVersion});

  Future<Object?> read(Map<String, Object?> request) {
    if (_closing) {
      throw PlatformException(code: 'cloud_reader_closed');
    }
    SqliteRecoveryGate.throwIfRequired('cloud_reader');
    final pending = _readInPool(connection, request, schemaVersion);
    _pending.add(pending);
    return pending.whenComplete(() => _pending.remove(pending));
  }

  Future<void> close() async {
    _closing = true;
    await Future.wait(_pending.map((f) => f.catchError((_) => null)));
  }
}

// Top-level closure: never send a MethodChannel or the owning reader to SQLite's isolate.
Future<Object?> _readInPool(SqliteConnection connection, Map<String, Object?> request, int schemaVersion) =>
    connection.readTransaction((tx) => tx.computeWithDatabase((db) async => _readSnapshot(db, request, schemaVersion)));

CommonPreparedStatement _prepareSelect(CommonDatabase db, String sql) {
  if (!RegExp(r'^\s*(SELECT|WITH)\b', caseSensitive: false).hasMatch(sql)) {
    throw const FormatException('cloud_reader_select_only');
  }
  final statement = db.prepare(sql, checkNoTail: true);
  if (!statement.isReadOnly) {
    statement.close();
    throw const FormatException('cloud_reader_select_only');
  }
  return statement;
}

Object _readSnapshot(CommonDatabase db, Map<String, Object?> request, int schemaVersion) {
  if (db.select('PRAGMA user_version').single.values.single != schemaVersion) {
    throw const FormatException('cloud_reader_schema_not_ready');
  }
  if (request['operation'] == 'digest') {
    final statements = (request['queries']! as List).cast<Map>();
    if (statements.length > 16) {
      throw const FormatException('cloud_reader_query_limit');
    }
    final result = _DigestResult();
    final sink = sha256.startChunkedConversion(result);
    sink.add(utf8.encode(jsonEncode(request['scope'])));
    for (final query in statements) {
      final statement = _prepareSelect(db, query['sql'] as String);
      try {
        final cursor = statement.selectCursor((query['args'] as List).cast<Object?>());
        sink.add(utf8.encode(jsonEncode(cursor.columnNames)));
        while (cursor.moveNext()) {
          sink.add(utf8.encode(jsonEncode(cursor.current.values.toList())));
          sink.add(const [10]);
        }
      } finally {
        statement.close();
      }
    }
    sink.close();
    return result.value!.toString();
  }
  final statement = _prepareSelect(db, request['sql']! as String);
  try {
    final cursor = statement.selectCursor((request['args']! as List).cast<Object?>());
    final rows = <List<Object?>>[];
    var bytes = 0;
    while (cursor.moveNext()) {
      final row = cursor.current.values.toList();
      bytes += utf8.encode(jsonEncode(row)).length;
      if (rows.length >= 201 || bytes > 4 * 1024 * 1024) {
        throw const FormatException('cloud_reader_result_limit');
      }
      rows.add(row);
    }
    return <String, Object?>{'columns': cursor.columnNames, 'rows': rows};
  } finally {
    statement.close();
  }
}

final class _DigestResult implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

abstract final class SqliteCloudBridge {
  static const channel = MethodChannel('foto/cloud_sqlite_reader');
  static SqliteCloudReader? _reader;

  static Future<void> attach(SqliteConnection connection, {required int schemaVersion}) async {
    if (!Platform.isAndroid) {
      return;
    }
    // Foreground and background engines have separate bridges. Native binds a
    // reader only after successful schema/Store/bootstrap initialization.
    final previous = _reader;
    if (previous != null) {
      if (identical(previous.connection, connection)) {
        return;
      }
      throw StateError('Cloud SQLite reader is already attached');
    }
    final reader = SqliteCloudReader(connection, schemaVersion: schemaVersion);
    _reader = reader;
    channel.setMethodCallHandler((call) async {
      if (call.method != 'read' || !identical(_reader, reader)) {
        throw PlatformException(code: 'cloud_reader_unavailable');
      }
      try {
        return await reader.read((call.arguments as Map).cast<String, Object?>());
      } on SqliteException catch (error) {
        if (isUnsafeToWrite(error)) {
          SqliteRecoveryGate.markRequired(check: 'cloud_reader', resultCode: error.extendedResultCode);
          await SqliteRecoveryPlatform.halt(
            reason: 'cloud_reader_sqlite_failure',
            sqliteCode: error.extendedResultCode,
          );
        }
        throw PlatformException(code: 'cloud_sqlite_error', details: {'sqliteCode': error.extendedResultCode});
      } on SqliteDatabaseUnhealthy {
        throw PlatformException(code: 'cloud_recovery_blocked');
      } on FormatException catch (error) {
        throw PlatformException(code: error.message);
      } on PlatformException {
        rethrow;
      } catch (_) {
        throw PlatformException(code: 'cloud_reader_unavailable');
      }
    });
    try {
      await channel.invokeMethod<void>('ready');
    } catch (_) {
      _reader = null;
      channel.setMethodCallHandler(null);
      await reader.close();
      rethrow;
    }
  }

  static Future<void> detach(SqliteConnection? connection) async {
    final reader = _reader;
    if (reader == null || !identical(reader.connection, connection)) {
      return;
    }
    _reader = null;
    // Stop native admission, then drain callbacks before the owning pool closes.
    await channel.invokeMethod<void>('closing');
    await reader.close();
    channel.setMethodCallHandler(null);
  }
}
