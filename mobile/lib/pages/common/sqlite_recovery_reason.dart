import 'package:flutter/services.dart';
import 'package:immich_mobile/data/db/sqlite_one_tap_recovery.dart';

/// Never show raw SQLite, platform or HTTP exceptions (paths, rows or tokens).
String recoveryReasonCode(Object error) {
  if (error is PlatformException && error.code == 'export_failed') {
    return 'external_backup_unverified';
  }
  if (error is RecoveryRefused && RegExp(r'^[a-z_]{1,80}$').hasMatch(error.reason)) {
    return error.reason;
  }
  return 'io_or_validation_failure';
}

String recoveryReasonKey(String code) => switch (code) {
  'persisted_recovery_block' => 'sqlite_recovery_reason_persisted_block',
  'external_backup_unverified' => 'sqlite_fresh_export_failed',
  'insufficient_space' => 'sqlite_recovery_reason_space',
  'empty_wal_evidence_missing' ||
  'checkpoint_witness_missing' ||
  'checkpoint_history_not_terminal' ||
  'checkpoint_primary_mismatch' ||
  'missing_committed_wal' ||
  'wal_or_index_invalid' ||
  'evidence_scan_limit' => 'sqlite_recovery_reason_wal',
  'server_credentials_unavailable' ||
  'server_auth_failed' ||
  'server_owner_mismatch' => 'sqlite_recovery_reason_account',
  'server_network_unavailable' || 'server_response_invalid' => 'sqlite_recovery_reason_network',
  'index_only_repair_not_proven' => 'sqlite_recovery_reason_content',
  _ => 'sqlite_recovery_reason_io',
};
