import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// The result of a user-mediated repair attempt against a captured snapshot.
///
/// A repaired candidate is never promoted by this API. The caller must show
/// the report to the user and perform a separate, explicitly approved restore
/// after an independent backup and validation.
enum SqliteRecoveryStatus { healthy, repairedIndex, requiresManualRecovery }

final class SqliteRecoveryReport {
  final SqliteRecoveryStatus status;
  final Directory snapshot;
  final Directory? candidate;
  final String sourceIntegrity;
  final String? candidateIntegrity;
  final List<String> foreignKeyErrors;
  final List<String> diagnostics;
  final Map<String, String> sourceTableFingerprints;
  final Map<String, String>? candidateTableFingerprints;

  const SqliteRecoveryReport({
    required this.status,
    required this.snapshot,
    required this.candidate,
    required this.sourceIntegrity,
    required this.candidateIntegrity,
    required this.foreignKeyErrors,
    required this.diagnostics,
    required this.sourceTableFingerprints,
    required this.candidateTableFingerprints,
  });

  /// A redacted receipt suitable for support export. It contains no paths to
  /// media and no row values, only hashes and health outcomes.
  Map<String, Object?> toJson() => {
        'status': status.name,
        'sourceIntegrity': sourceIntegrity,
        if (candidateIntegrity != null) 'candidateIntegrity': candidateIntegrity,
        // Foreign-key rows can include account and asset identifiers; export
        // only their count so support receipts remain free of user data.
        'foreignKeyErrorCount': foreignKeyErrors.length,
        'diagnostics': diagnostics,
        'tables': sourceTableFingerprints.keys.toList()..sort(),
        'tableFingerprintsMatch': candidateTableFingerprints == null
            ? null
            : _sameFingerprints(sourceTableFingerprints, candidateTableFingerprints!),
        'promotionAllowed': false,
      };
}

/// Diagnose and, only for a proven index-only failure, repair a captured
/// snapshot. The primary database is never opened or modified by this method.
/// Page, WAL, I/O and malformed-database failures return
/// [SqliteRecoveryStatus.requiresManualRecovery] with no candidate promotion.
Future<SqliteRecoveryReport> diagnoseAndRepairSqliteSnapshot({
  required Directory snapshot,
  required Directory outputDirectory,
  DateTime Function()? now,
}) async {
  final sourceDir = await _copySnapshot(
    snapshot: snapshot,
    destinationRoot: outputDirectory,
    prefix: 'diagnostic',
    now: now,
  );
  late final String databaseName;
  try {
    databaseName = await _databaseName(sourceDir);
  } on Object catch (error) {
    final diagnostics = ['snapshot manifest is invalid: ${error.runtimeType}'];
    await _writeReceipt(sourceDir, {
      'status': SqliteRecoveryStatus.requiresManualRecovery.name,
      'promotionAllowed': false,
      'diagnostics': diagnostics,
    });
    return SqliteRecoveryReport(
      status: SqliteRecoveryStatus.requiresManualRecovery,
      snapshot: snapshot,
      candidate: null,
      sourceIntegrity: 'unavailable',
      candidateIntegrity: null,
      foreignKeyErrors: const [],
      diagnostics: diagnostics,
      sourceTableFingerprints: const {},
      candidateTableFingerprints: null,
    );
  }
  final sourceDatabase = File(p.join(sourceDir.path, databaseName));

  Database? source;
  try {
    // Open the captured source read-only. A diagnostic pass must not create a
    // journal, checkpoint a WAL, or otherwise mutate the evidence it is
    // inspecting.
    source = sqlite3.open(sourceDatabase.path, mode: OpenMode.readOnly);
    source.execute('PRAGMA query_only = ON');
    final sourceIntegrity = _integrityCheck(source);
    final sourceForeignKeys = _foreignKeyErrors(source);
    final sourceTables = _tableFingerprints(source);

    if (sourceIntegrity == 'ok' && sourceForeignKeys.isEmpty) {
      await _writeReceipt(sourceDir, const {
        'status': 'healthy',
        'promotionAllowed': false,
      });
      return SqliteRecoveryReport(
        status: SqliteRecoveryStatus.healthy,
        snapshot: snapshot,
        candidate: null,
        sourceIntegrity: sourceIntegrity,
        candidateIntegrity: null,
        foreignKeyErrors: sourceForeignKeys,
        diagnostics: const [],
        sourceTableFingerprints: sourceTables,
        candidateTableFingerprints: null,
      );
    }

    final diagnostics = <String>[
      if (sourceIntegrity != 'ok') 'integrity_check: $sourceIntegrity',
      if (sourceForeignKeys.isNotEmpty) 'foreign_key_check: ${sourceForeignKeys.length} row(s)',
    ];
    final indexOnly = sourceIntegrity != 'ok' && _isIndexOnlyFailure(sourceIntegrity, source);
    if (!indexOnly || sourceForeignKeys.isNotEmpty) {
      await _writeReceipt(sourceDir, {
        'status': SqliteRecoveryStatus.requiresManualRecovery.name,
        'promotionAllowed': false,
        'diagnostics': diagnostics,
      });
      return SqliteRecoveryReport(
        status: SqliteRecoveryStatus.requiresManualRecovery,
        snapshot: snapshot,
        candidate: null,
        sourceIntegrity: sourceIntegrity,
        candidateIntegrity: null,
        foreignKeyErrors: sourceForeignKeys,
        diagnostics: diagnostics,
        sourceTableFingerprints: sourceTables,
        candidateTableFingerprints: null,
      );
    }

    final candidate = await _copySnapshot(
      snapshot: snapshot,
      destinationRoot: outputDirectory,
      prefix: 'candidate',
      now: now,
    );
    final candidateDatabase = File(p.join(candidate.path, databaseName));
    Database? repaired;
    try {
      repaired = sqlite3.open(candidateDatabase.path);
      final indexes = _corruptIndexes(sourceIntegrity, source);
      if (indexes.isEmpty) {
        diagnostics.add('index-only diagnosis had no named index');
        await _writeReceipt(candidate, {
          'status': SqliteRecoveryStatus.requiresManualRecovery.name,
          'promotionAllowed': false,
          'diagnostics': diagnostics,
        });
        return SqliteRecoveryReport(
          status: SqliteRecoveryStatus.requiresManualRecovery,
          snapshot: snapshot,
          candidate: candidate,
          sourceIntegrity: sourceIntegrity,
          candidateIntegrity: null,
          foreignKeyErrors: sourceForeignKeys,
          diagnostics: diagnostics,
          sourceTableFingerprints: sourceTables,
          candidateTableFingerprints: null,
        );
      }
      for (final index in indexes) {
        repaired.execute('REINDEX ${_quoteIdentifier(index)}');
      }
      repaired.execute('PRAGMA wal_checkpoint(TRUNCATE)');
      final candidateIntegrity = _integrityCheck(repaired);
      final candidateForeignKeys = _foreignKeyErrors(repaired);
      final candidateTables = _tableFingerprints(repaired);
      final matches = candidateIntegrity == 'ok' &&
          candidateForeignKeys.isEmpty &&
          _sameFingerprints(sourceTables, candidateTables);
      diagnostics.addAll([
        'reindexed: ${indexes.join(', ')}',
        if (candidateForeignKeys.isNotEmpty) 'candidate foreign_key_check failed',
        if (!_sameFingerprints(sourceTables, candidateTables)) 'candidate table fingerprints differ',
      ]);
      final status = matches ? SqliteRecoveryStatus.repairedIndex : SqliteRecoveryStatus.requiresManualRecovery;
      await _writeReceipt(candidate, {
        'status': status.name,
        'promotionAllowed': false,
        'diagnostics': diagnostics,
        'sourceIntegrity': sourceIntegrity,
        'candidateIntegrity': candidateIntegrity,
      });
      return SqliteRecoveryReport(
        status: status,
        snapshot: snapshot,
        candidate: candidate,
        sourceIntegrity: sourceIntegrity,
        candidateIntegrity: candidateIntegrity,
        foreignKeyErrors: candidateForeignKeys,
        diagnostics: diagnostics,
        sourceTableFingerprints: sourceTables,
        candidateTableFingerprints: candidateTables,
      );
    } on Object catch (error) {
      diagnostics.add('candidate repair failed: ${error.runtimeType}');
      await _writeReceipt(candidate, {
        'status': SqliteRecoveryStatus.requiresManualRecovery.name,
        'promotionAllowed': false,
        'diagnostics': diagnostics,
      });
      return SqliteRecoveryReport(
        status: SqliteRecoveryStatus.requiresManualRecovery,
        snapshot: snapshot,
        candidate: candidate,
        sourceIntegrity: sourceIntegrity,
        candidateIntegrity: null,
        foreignKeyErrors: sourceForeignKeys,
        diagnostics: diagnostics,
        sourceTableFingerprints: sourceTables,
        candidateTableFingerprints: null,
      );
    } finally {
      repaired?.dispose();
    }
  } on Object catch (error) {
    final diagnostics = ['snapshot could not be read safely: ${error.runtimeType}'];
    await _writeReceipt(sourceDir, {
      'status': SqliteRecoveryStatus.requiresManualRecovery.name,
      'promotionAllowed': false,
      'diagnostics': diagnostics,
    });
    return SqliteRecoveryReport(
      status: SqliteRecoveryStatus.requiresManualRecovery,
      snapshot: snapshot,
      candidate: null,
      sourceIntegrity: 'unavailable',
      candidateIntegrity: null,
      foreignKeyErrors: const [],
      diagnostics: diagnostics,
      sourceTableFingerprints: const {},
      candidateTableFingerprints: null,
    );
  } finally {
    source?.dispose();
  }
}

Future<String> _databaseName(Directory snapshot) async {
  final manifest = File(p.join(snapshot.path, 'manifest.json'));
  if (!await manifest.exists()) {
    throw const FormatException('SQLite recovery manifest is missing');
  }
  final value = jsonDecode(await manifest.readAsString());
  if (value is! Map || value['database'] is! String) {
    throw const FormatException('SQLite recovery manifest has no database name');
  }
  final name = value['database'] as String;
  if (name.isEmpty || p.basename(name) != name || name.contains('..')) {
    throw const FormatException('SQLite recovery manifest has an unsafe database name');
  }
  if (!await File(p.join(snapshot.path, name)).exists()) {
    throw const FormatException('SQLite recovery database is missing');
  }
  return name;
}

Future<Directory> _copySnapshot({
  required Directory snapshot,
  required Directory destinationRoot,
  required String prefix,
  DateTime Function()? now,
}) async {
  await destinationRoot.create(recursive: true);
  final stamp = (now ?? DateTime.now)().toUtc().microsecondsSinceEpoch;
  final base = p.join(destinationRoot.path, 'sqlite-$prefix-$stamp');
  var destination = Directory(base);
  var suffix = 0;
  while (await destination.exists()) {
    suffix++;
    destination = Directory('$base-$suffix');
  }
  final staging = Directory('${destination.path}.staging');
  await staging.create(recursive: true);
  await for (final entity in snapshot.list(followLinks: false)) {
    if (entity is! File || p.basename(entity.path) == 'manifest.json') continue;
    await entity.copy(p.join(staging.path, p.basename(entity.path)));
  }
  final manifest = File(p.join(snapshot.path, 'manifest.json'));
  await manifest.copy(p.join(staging.path, 'manifest.json'));
  await staging.rename(destination.path);
  return destination;
}

String _integrityCheck(Database db) {
  final rows = db.select('PRAGMA integrity_check');
  if (rows.isEmpty) return 'no result';
  return rows.map((row) => row[0].toString()).join('; ');
}

List<String> _foreignKeyErrors(Database db) => [
      for (final row in db.select('PRAGMA foreign_key_check')) row.values.join(':'),
    ];

Map<String, String> _tableFingerprints(Database db) {
  final tables = db.select(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
  );
  final result = <String, String>{};
  for (final row in tables) {
    final name = row[0].toString();
    final rows = db.select('SELECT * FROM ${_quoteIdentifier(name)}');
    final encoded = [
      for (final value in rows)
        [for (final cell in value.values) _jsonCell(cell)],
    ];
    // SELECT without an ORDER BY is allowed to return rows in a different
    // order after a repair. Fingerprint the row set rather than an incidental
    // traversal order so the comparison detects data loss without producing
    // false differences.
    encoded.sort((a, b) => jsonEncode(a).compareTo(jsonEncode(b)));
    result[name] = sha256.convert(utf8.encode(jsonEncode(encoded))).toString();
  }
  return result;
}

Object? _jsonCell(Object? value) {
  if (value is Uint8List) return base64Encode(value);
  if (value is List<int>) return base64Encode(value);
  return value;
}

bool _isIndexOnlyFailure(String integrity, Database db) {
  final indexes = _allIndexes(db);
  if (indexes.isEmpty) return false;
  final lines = integrity.split(';').map((line) => line.trim()).where((line) => line.isNotEmpty);
  var namedIndexError = false;
  for (final line in lines) {
    if (indexes.any(line.contains)) {
      namedIndexError = true;
      continue;
    }
    // Removing an index cell leaves a small free fragment on the index page.
    // SQLite reports that alongside the named index errors; it is still safe
    // to rebuild the named index on the isolated candidate copy.
    if (line.toLowerCase().contains('fragmentation')) continue;
    return false;
  }
  return namedIndexError;
}

List<String> _corruptIndexes(String integrity, Database db) {
  final indexes = _allIndexes(db);
  return [for (final index in indexes) if (integrity.contains(index)) index];
}

List<String> _allIndexes(Database db) {
  final tables = db.select("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'");
  final indexes = <String>[];
  for (final row in tables) {
    final table = row[0].toString();
    for (final index in db.select('PRAGMA index_list(${_quoteIdentifier(table)})')) {
      final name = index[1]?.toString();
      if (name != null && name.isNotEmpty) indexes.add(name);
    }
  }
  return indexes;
}

String _quoteIdentifier(String value) => '"${value.replaceAll('"', '""')}"';

bool _sameFingerprints(Map<String, String> first, Map<String, String> second) {
  if (first.length != second.length) return false;
  for (final entry in first.entries) {
    if (second[entry.key] != entry.value) return false;
  }
  return true;
}

Future<void> _writeReceipt(Directory directory, Map<String, Object?> data) async {
  await File(p.join(directory.path, 'recovery-receipt.json')).writeAsString(
    const JsonEncoder.withIndent('  ').convert(data),
  );
}
