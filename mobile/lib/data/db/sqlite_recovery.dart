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
  Set<String>? allowedIndexes,
  Future<void> Function(String step)? repairCheckpoint,
}) async {
  final sourceDir = await _copySnapshot(
    snapshot: snapshot,
    destinationRoot: outputDirectory,
    prefix: 'diagnostic',
    now: now,
  );
  late final String databaseName;
  try {
    databaseName = await _databaseName(sourceDir, requireWalIndex: allowedIndexes != null);
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
      await _writeReceipt(sourceDir, const {'status': 'healthy', 'promotionAllowed': false});
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
    final permitted =
        allowedIndexes == null ||
        (_corruptIndexes(sourceIntegrity, source).every(allowedIndexes.contains) &&
            sourceIntegrity
                .split(';')
                .every(
                  (line) => allowedIndexes.any(
                    (index) =>
                        line.trim() == 'wrong # of entries in index $index' ||
                        RegExp('^row [0-9]+ missing from index ${RegExp.escape(index)}\$').hasMatch(line.trim()),
                  ),
                ));
    if (!indexOnly || !permitted || sourceForeignKeys.isNotEmpty) {
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
      await repairCheckpoint?.call('before_reindex');
      for (final index in indexes) {
        repaired.execute('REINDEX ${_quoteIdentifier(index)}');
      }
      await repairCheckpoint?.call('after_reindex');
      final checkpoint = repaired.select('PRAGMA wal_checkpoint(TRUNCATE)');
      if (checkpoint.single.values.first != 0) {
        throw StateError('candidate checkpoint busy');
      }
      final candidateIntegrity = _integrityCheck(repaired);
      final candidateForeignKeys = _foreignKeyErrors(repaired);
      final candidateTables = _tableFingerprints(repaired);
      final matches =
          candidateIntegrity == 'ok' &&
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
      repaired?.close();
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
    source?.close();
  }
}

Future<String> _databaseName(Directory snapshot, {bool requireWalIndex = false}) async {
  final manifest = File(p.join(snapshot.path, 'manifest.json'));
  if (!manifest.existsSync()) {
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
  if (!File(p.join(snapshot.path, name)).existsSync()) {
    throw const FormatException('SQLite recovery database is missing');
  }
  // SQLite can open a checkpointed primary without its WAL and report "ok"
  // while committed pending operations exist only in the missing WAL. A
  // best-effort evidence capture is not necessarily a complete recovery copy.
  final omitted = value['omittedSidecars'];
  if (omitted != null && (omitted is! List || omitted.isNotEmpty)) {
    throw const FormatException('SQLite recovery snapshot omitted sidecars');
  }
  final files = value['files'];
  if (value['format'] != 1 || files is! List || files.isEmpty) {
    throw const FormatException('SQLite recovery file manifest is invalid');
  }
  final expectedNames = {name, '$name-wal', '$name-shm'};
  final recordedNames = <String>{};
  for (final entry in files) {
    if (entry is! Map || entry['name'] is! String || entry['bytes'] is! int) {
      throw const FormatException('SQLite recovery file entry is invalid');
    }
    final fileName = entry['name'] as String;
    final bytes = entry['bytes'] as int;
    if (!expectedNames.contains(fileName) || !recordedNames.add(fileName) || bytes < 0) {
      throw const FormatException('SQLite recovery file entry is invalid');
    }
    final file = File(p.join(snapshot.path, fileName));
    if (!file.existsSync() || await file.length() != bytes) {
      throw const FormatException('SQLite recovery file is missing or truncated');
    }
  }
  if (!recordedNames.contains(name) ||
      expectedNames.any(
        (fileName) => File(p.join(snapshot.path, fileName)).existsSync() && !recordedNames.contains(fileName),
      )) {
    throw const FormatException('SQLite recovery snapshot has unrecorded files');
  }
  final wal = File(p.join(snapshot.path, '$name-wal'));
  await _validateSnapshotWal(wal);
  if (requireWalIndex && wal.existsSync() && wal.lengthSync() > 0) {
    await _validateWalIndex(wal, File(p.join(snapshot.path, '$name-shm')), File(p.join(snapshot.path, name)));
  }
  return name;
}

/// Startup must not let SQLite silently discard a malformed WAL before the
/// user gets the recovery screen. This does not repair or checkpoint anything.
Future<void> validateStartupSqliteFiles(File primary) async {
  if (primary.lengthSync() < 100 || File('${primary.path}-journal').existsSync()) {
    throw const FormatException('Primary header incomplete or rollback journal present');
  }
  await _validateSnapshotWal(File('${primary.path}-wal'));
}

/// Require the captured WAL-index to confirm the last committed frame. CRCs
/// alone cannot detect a WAL truncated exactly at an earlier commit boundary.
Future<void> _validateWalIndex(File wal, File shm, File primary) async {
  Future<Uint8List> header(File file, int count) async {
    final input = await file.open();
    try {
      return await input.read(count);
    } finally {
      await input.close();
    }
  }

  final walBytes = await header(wal, 32);
  final index = await header(shm, 100);
  final database = await header(primary, 100);
  if (index.length != 100 || database.length != 100 || !index.take(48).indexed.every((e) => e.$2 == index[e.$1 + 48])) {
    throw const FormatException('WAL-index headers incomplete or inconsistent');
  }
  final data = ByteData.sublistView(index);
  final walHeader = ByteData.sublistView(walBytes);
  final pageSize = walHeader.getUint32(8);
  final dbSize = ByteData.sublistView(database).getUint16(16);
  final indexPageSize = data.getUint16(14, Endian.host);
  final checksum = _walChecksum(Uint8List.sublistView(index, 0, 40), Endian.host, (0, 0));
  final frames = (await wal.length() - 32) ~/ (24 + pageSize);
  if (data.getUint32(0, Endian.host) != 3007000 ||
      index[12] != 1 ||
      (indexPageSize == 1 ? 65536 : indexPageSize) != pageSize ||
      (dbSize == 1 ? 65536 : dbSize) != pageSize ||
      data.getUint32(16, Endian.host) != frames ||
      frames == 0 ||
      checksum != (data.getUint32(40, Endian.host), data.getUint32(44, Endian.host)) ||
      !walBytes.skip(16).take(8).indexed.every((e) => e.$2 == index[e.$1 + 32])) {
    throw const FormatException('WAL-index does not prove the committed WAL extent');
  }
  final input = await wal.open();
  try {
    await input.setPosition(32 + (frames - 1) * (24 + pageSize));
    final last = ByteData.sublistView(await input.read(24));
    if (last.getUint32(4) != data.getUint32(20, Endian.host) ||
        last.getUint32(16) != data.getUint32(24, Endian.host) ||
        last.getUint32(20) != data.getUint32(28, Endian.host) ||
        data.getUint32(96, Endian.host) > frames) {
      throw const FormatException('WAL-index commit differs from WAL');
    }
  } finally {
    await input.close();
  }
}

/// SQLite deliberately ignores an invalid WAL header or frame suffix. That is
/// useful for ordinary crash recovery, but integrity_check can then report
/// "ok" for an older database missing pending operations. Do not certify that
/// partial view. Ambiguous/recycled tails also require manual review; preserve
/// all captured evidence instead of guessing which frames can be discarded.
Future<void> _validateSnapshotWal(File wal) async {
  if (!wal.existsSync() || await wal.length() == 0) {
    return;
  }
  final input = await wal.open();
  try {
    final header = await input.read(32);
    if (header.length != 32) {
      throw const FormatException('SQLite recovery WAL header is truncated');
    }
    final data = ByteData.sublistView(header);
    final magic = data.getUint32(0);
    final pageSize = data.getUint32(8);
    if ((magic != 0x377f0682 && magic != 0x377f0683) ||
        data.getUint32(4) != 3007000 ||
        pageSize < 512 ||
        pageSize > 65536 ||
        (pageSize & (pageSize - 1)) != 0) {
      throw const FormatException('SQLite recovery WAL header is invalid');
    }
    // WAL fields/checksums are stored big-endian; only checksum input words
    // use the byte order selected by the magic. See sqlite.org/fileformat2.html.
    final order = magic == 0x377f0682 ? Endian.little : Endian.big;
    var checksum = _walChecksum(Uint8List.sublistView(header, 0, 24), order, (0, 0));
    if (checksum != (data.getUint32(24), data.getUint32(28))) {
      throw const FormatException('SQLite recovery WAL header checksum failed');
    }
    var hasFrames = false;
    var endsWithCommit = false;
    while (true) {
      final frame = await input.read(24 + pageSize);
      if (frame.isEmpty) {
        break;
      }
      if (frame.length != 24 + pageSize) {
        throw const FormatException('SQLite recovery WAL frame is truncated');
      }
      hasFrames = true;
      final frameData = ByteData.sublistView(frame);
      if (frameData.getUint32(0) == 0 ||
          frameData.getUint32(8) != data.getUint32(16) ||
          frameData.getUint32(12) != data.getUint32(20)) {
        throw const FormatException('SQLite recovery WAL frame is ambiguous');
      }
      checksum = _walChecksum(Uint8List.sublistView(frame, 0, 8), order, checksum);
      checksum = _walChecksum(Uint8List.sublistView(frame, 24), order, checksum);
      if (checksum != (frameData.getUint32(16), frameData.getUint32(20))) {
        throw const FormatException('SQLite recovery WAL frame checksum failed');
      }
      endsWithCommit = frameData.getUint32(4) != 0;
    }
    if (hasFrames && !endsWithCommit) {
      throw const FormatException('SQLite recovery WAL has an uncommitted tail');
    }
  } finally {
    await input.close();
  }
}

(int, int) _walChecksum(Uint8List bytes, Endian order, (int, int) seed) {
  final data = ByteData.sublistView(bytes);
  var (first, second) = seed;
  for (var offset = 0; offset < bytes.length; offset += 8) {
    first = (first + data.getUint32(offset, order) + second) & 0xffffffff;
    second = (second + data.getUint32(offset + 4, order) + first) & 0xffffffff;
  }
  return (first, second);
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
  while (destination.existsSync()) {
    suffix++;
    destination = Directory('$base-$suffix');
  }
  final staging = Directory('${destination.path}.staging');
  await staging.create(recursive: true);
  await for (final entity in snapshot.list(followLinks: false)) {
    if (entity is! File || p.basename(entity.path) == 'manifest.json') {
      continue;
    }
    await entity.copy(p.join(staging.path, p.basename(entity.path)));
  }
  final manifest = File(p.join(snapshot.path, 'manifest.json'));
  await manifest.copy(p.join(staging.path, 'manifest.json'));
  await staging.rename(destination.path);
  return destination;
}

String _integrityCheck(Database db) {
  final rows = db.select('PRAGMA integrity_check');
  if (rows.isEmpty) {
    return 'no result';
  }
  return rows.map((row) => row.values.first.toString()).join('; ');
}

List<String> _foreignKeyErrors(Database db) => [
  for (final row in db.select('PRAGMA foreign_key_check')) row.values.join(':'),
];

Map<String, String> _tableFingerprints(Database db) {
  final tables = db.select(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND (name NOT LIKE 'sqlite_%' OR name = 'sqlite_sequence') ORDER BY name",
  );
  final result = <String, String>{};
  for (final row in tables) {
    final name = row.values.first.toString();
    final rows = db.select('SELECT * FROM ${_quoteIdentifier(name)} NOT INDEXED');
    final encoded = [
      for (final value in rows) [for (final cell in value.values) _jsonCell(cell)],
    ];
    // SELECT without an ORDER BY is allowed to return rows in a different
    // order after a repair. Fingerprint the row set rather than an incidental
    // traversal order so the comparison detects data loss without producing
    // false differences.
    encoded.sort((a, b) => jsonEncode(a).compareTo(jsonEncode(b)));
    result[name] = sha256.convert(utf8.encode(jsonEncode(encoded))).toString();
    final definition = db
        .select('SELECT sql FROM sqlite_master WHERE name = ?', [name])
        .single
        .values
        .single
        .toString();
    if (definition.toUpperCase().contains('CREATE VIRTUAL TABLE')) {
      throw StateError('Virtual tables need manual recovery');
    }
    if (!definition.toUpperCase().contains('WITHOUT ROWID')) {
      final columns = db
          .select('PRAGMA table_info(${_quoteIdentifier(name)})')
          .map((r) => r['name'].toString().toLowerCase())
          .toSet();
      final alias = ['rowid', '_rowid_', 'oid'].where((v) => !columns.contains(v)).firstOrNull;
      if (alias == null) {
        throw StateError('Hidden rowid cannot be verified');
      }
      final identities = db.select('SELECT $alias, * FROM ${_quoteIdentifier(name)} NOT INDEXED ORDER BY $alias');
      result['@rowid:$name'] = sha256
          .convert(
            utf8.encode(
              jsonEncode([
                for (final row in identities) [for (final value in row.values) _jsonCell(value)],
              ]),
            ),
          )
          .toString();
    }
  }
  final schema = db.select("SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name");
  result['@schema'] = sha256
      .convert(utf8.encode(jsonEncode([for (final row in schema) row.values.toList()])))
      .toString();
  for (final pragma in ['user_version', 'application_id']) {
    result['@$pragma'] = db.select('PRAGMA $pragma').single.values.single.toString();
  }
  return result;
}

/// Independent final-file check used only by the explicit promotion coordinator.
void validateRecoveredSqlite(File candidate, Map<String, String> expected) {
  final wal = File('${candidate.path}-wal');
  if ((wal.existsSync() && wal.lengthSync() != 0) || File('${candidate.path}-journal').existsSync()) {
    throw StateError('Candidate still has a journal');
  }
  final db = sqlite3.open(candidate.path, mode: OpenMode.readOnly);
  try {
    if (_integrityCheck(db) != 'ok' ||
        _foreignKeyErrors(db).isNotEmpty ||
        !_sameFingerprints(expected, _tableFingerprints(db))) {
      throw StateError('Candidate failed independent validation');
    }
  } finally {
    db.close();
  }
}

Object? _jsonCell(Object? value) {
  if (value is Uint8List) {
    return {'blob': base64Encode(value)};
  }
  if (value is List<int>) {
    return {'blob': base64Encode(value)};
  }
  return value;
}

bool _isIndexOnlyFailure(String integrity, Database db) {
  final indexes = _allIndexes(db);
  if (indexes.isEmpty) {
    return false;
  }
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
    if (line.toLowerCase().contains('fragmentation')) {
      continue;
    }
    return false;
  }
  return namedIndexError;
}

List<String> _corruptIndexes(String integrity, Database db) {
  final indexes = _allIndexes(db);
  return [
    for (final index in indexes)
      if (integrity.contains(index)) index,
  ];
}

List<String> _allIndexes(Database db) {
  final tables = db.select("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'");
  final indexes = <String>[];
  for (final row in tables) {
    final table = row.values.first.toString();
    for (final index in db.select('PRAGMA index_list(${_quoteIdentifier(table)})')) {
      final name = index.values.elementAt(1)?.toString();
      if (name != null && name.isNotEmpty) {
        indexes.add(name);
      }
    }
  }
  return indexes;
}

String _quoteIdentifier(String value) => '"${value.replaceAll('"', '""')}"';

bool _sameFingerprints(Map<String, String> first, Map<String, String> second) {
  if (first.length != second.length) {
    return false;
  }
  for (final entry in first.entries) {
    if (second[entry.key] != entry.value) {
      return false;
    }
  }
  return true;
}

Future<void> _writeReceipt(Directory directory, Map<String, Object?> data) async {
  await File(
    p.join(directory.path, 'recovery-receipt.json'),
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(data));
}
