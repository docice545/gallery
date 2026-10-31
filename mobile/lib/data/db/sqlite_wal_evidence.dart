import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:immich_mobile/data/db/sqlite_recovery.dart';
import 'package:path/path.dart' as p;

/// A past snapshot alone is NOT evidence that no newer WAL transactions were
/// lost. Empty-WAL promotion additionally requires the CURRENT, non-rebuilt
/// checkpoint header, its last commit identity, and exact primary page images.
final class SqliteWalEvidence {
  final bool complete;
  final String code;
  final Map<String, Object?> details;
  const SqliteWalEvidence(this.complete, this.code, [this.details = const {}]);
  Map<String, Object?> toJson() => {'complete': complete, 'code': code, ...details};
}

Future<String> _hash(File file) async => (await sha256.bind(file.openRead()).first).toString();

Future<Uint8List> _header(File file, int size) async {
  final input = await file.open();
  try {
    return await input.read(size);
  } finally {
    await input.close();
  }
}

(int, int) _checksum(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  var first = 0;
  var second = 0;
  for (var i = 0; i < bytes.length; i += 8) {
    first = (first + data.getUint32(i, Endian.host) + second) & 0xffffffff;
    second = (second + data.getUint32(i + 4, Endian.host) + first) & 0xffffffff;
  }
  return (first, second);
}

bool _validIndex(Uint8List header) {
  if (header.length != 136 || !header.take(48).indexed.every((e) => e.$2 == header[e.$1 + 48])) {
    return false;
  }
  final data = ByteData.sublistView(header);
  return data.getUint32(0, Endian.host) == 3007000 &&
      header[12] == 1 &&
      _checksum(Uint8List.sublistView(header, 0, 40)) ==
          (data.getUint32(40, Endian.host), data.getUint32(44, Endian.host));
}

Future<SqliteWalEvidence> assessSqliteWalEvidence({
  required Directory snapshot,
  required List<Directory> historyRoots,
  required Directory excludedAttempt,
}) async {
  final primary = File(p.join(snapshot.path, 'immich.sqlite'));
  final header = await _header(primary, 100);
  if (header.length != 100) {
    return const SqliteWalEvidence(false, 'primary_header_incomplete');
  }
  final wal = File('${primary.path}-wal');
  if (wal.existsSync() && wal.lengthSync() > 0) {
    try {
      await validateSqliteRecoverySnapshotFiles(snapshot);
      return const SqliteWalEvidence(true, 'complete_wal_and_index');
    } catch (_) {
      return const SqliteWalEvidence(false, 'wal_or_index_invalid');
    }
  }
  if (header[18] != 2 && header[19] != 2) {
    return const SqliteWalEvidence(true, 'rollback_journal_mode');
  }
  final shm = File('${primary.path}-shm');
  if (!shm.existsSync()) {
    return const SqliteWalEvidence(false, 'empty_wal_evidence_missing');
  }
  final index = await _header(shm, 136);
  if (!_validIndex(index)) {
    return const SqliteWalEvidence(false, 'wal_or_index_invalid');
  }
  final data = ByteData.sublistView(index);
  final frames = data.getUint32(16, Endian.host);
  final pages = data.getUint32(20, Endian.host);
  final rawSize = data.getUint16(14, Endian.host);
  final pageSize = rawSize == 1 ? 65536 : rawSize;
  final details = <String, Object?>{
    'walBytes': wal.existsSync() ? wal.lengthSync() : null,
    'indexFrames': frames,
    'indexPages': pages,
    'indexChange': data.getUint32(8, Endian.host),
    'indexBackfill': data.getUint32(96, Endian.host),
    'indexBackfillAttempted': data.getUint32(128, Endian.host),
  };
  // This includes the EXACT canonical empty SHM supplied from Samsung. SQLite
  // produces it after both a clean close and loss of an uncheckpointed WAL.
  // Even a matching old snapshot cannot resolve that ambiguity.
  if (frames != 0 ||
      pages == 0 ||
      pageSize < 512 ||
      (pageSize & (pageSize - 1)) != 0 ||
      data.getUint32(96, Endian.host) != 0 ||
      data.getUint32(128, Endian.host) != 0 ||
      (data.getUint32(24, Endian.host) == 0 && data.getUint32(28, Endian.host) == 0)) {
    return SqliteWalEvidence(false, frames > 0 ? 'missing_committed_wal' : 'empty_wal_evidence_missing', details);
  }
  final primaryData = ByteData.sublistView(header);
  final dbPageSize = primaryData.getUint16(16) == 1 ? 65536 : primaryData.getUint16(16);
  if (dbPageSize != pageSize ||
      primary.lengthSync() != pages * pageSize ||
      primaryData.getUint32(28) != pages ||
      primaryData.getUint32(24) != primaryData.getUint32(92)) {
    return SqliteWalEvidence(false, 'checkpoint_primary_mismatch', details);
  }
  final expected = await _hash(primary);
  var checked = 0;
  var visited = 0;
  final seen = <String>{};
  for (final root in historyRoots) {
    if (!root.existsSync()) {
      continue;
    }
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (++visited > 10000) {
        return SqliteWalEvidence(false, 'evidence_scan_limit', {...details, 'snapshotsChecked': checked});
      }
      if (entity is! File ||
          p.basename(entity.path) != 'manifest.json' ||
          p.isWithin(excludedAttempt.absolute.path, entity.absolute.path) ||
          !seen.add(entity.absolute.path)) {
        continue;
      }
      final old = File(p.join(entity.parent.path, 'immich.sqlite'));
      final oldWal = File('${old.path}-wal');
      if (!old.existsSync() || !oldWal.existsSync() || oldWal.lengthSync() <= 32) {
        continue;
      }
      checked++;
      try {
        final before = [await _hash(old), await _hash(oldWal), await _hash(File('${old.path}-shm'))];
        if (await validateSqliteRecoverySnapshotFiles(entity.parent) != 'immich.sqlite') {
          continue;
        }
        final previous = ByteData.sublistView(await _header(File('${old.path}-shm'), 136));
        // walRestartHdr increments salt-1, retains the previous commit's frame
        // checksum, page count and change counter, and resets mxFrame/backfill.
        if (data.getUint32(8, Endian.host) != previous.getUint32(8, Endian.host) ||
            pages != previous.getUint32(20, Endian.host) ||
            data.getUint32(24, Endian.host) != previous.getUint32(24, Endian.host) ||
            data.getUint32(28, Endian.host) != previous.getUint32(28, Endian.host) ||
            data.getUint32(32) != ((previous.getUint32(32) + 1) & 0xffffffff) ||
            data.getUint16(14, Endian.host) != previous.getUint16(14, Endian.host)) {
          continue;
        }
        // Reconstruct page bytes as a stream, never write an older snapshot over
        // the current DB. This verifies even freelists and non-table pages.
        if (await _checkpointImageHash(old, oldWal, pageSize, pages) != expected) {
          continue;
        }
        final after = [await _hash(old), await _hash(oldWal), await _hash(File('${old.path}-shm'))];
        if (!before.indexed.every((e) => e.$2 == after[e.$1])) {
          continue;
        }
        return SqliteWalEvidence(true, 'checkpoint_with_matching_wal_snapshot', {
          ...details,
          'snapshotsChecked': checked,
          'witnessChecksums': before,
        });
      } catch (_) {
        // Retain incomplete/old attempts as evidence; they cannot authorize a switch.
      }
    }
  }
  return SqliteWalEvidence(false, 'checkpoint_witness_missing', {...details, 'snapshotsChecked': checked});
}

Future<String> _checkpointImageHash(File primary, File wal, int pageSize, int pages) async {
  final input = await wal.open();
  final base = await primary.open();
  try {
    final offsets = <int, int>{};
    for (var offset = 32; offset < wal.lengthSync(); offset += pageSize + 24) {
      await input.setPosition(offset);
      final frame = ByteData.sublistView(await input.read(24));
      offsets[frame.getUint32(0)] = offset + 24;
    }
    Stream<List<int>> image() async* {
      for (var page = 1; page <= pages; page++) {
        final offset = offsets[page];
        final file = offset == null ? base : input;
        await file.setPosition(offset ?? (page - 1) * pageSize);
        final bytes = await file.read(pageSize);
        if (bytes.length != pageSize) {
          throw const FormatException('Checkpoint image incomplete');
        }
        yield bytes;
      }
    }

    return (await sha256.bind(image()).first).toString();
  } finally {
    await input.close();
    await base.close();
  }
}
