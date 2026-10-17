import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:immich_mobile/domain/models/deletion_result.model.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:openapi/api.dart';

String? _managedDeletionFailureMessage(BuildContext context, String? code) => switch (code) {
  'DELETION_RECOVERY_UNAVAILABLE' => context.t.managed_deletion_recovery_missing,
  'DELETION_RECOVERY_INVALID' => context.t.managed_deletion_recovery_invalid,
  'DELETION_RECOVERY_EXPIRED' => context.t.managed_deletion_recovery_expired,
  'DELETION_RECOVERY_SCOPE_MISMATCH' => context.t.managed_deletion_recovery_scope_mismatch,
  'DELETION_ROOT_CHANGED' ||
  'OVERLAPPING_OWNER_ROOTS' ||
  'UNSUPPORTED_DELETION_FILESYSTEM' ||
  'DELETION_QUARANTINE_CONFLICT' => context.t.managed_deletion_roots_changed,
  'LIBRARY_STORAGE_READ_ONLY' => context.t.storage_read_only_deletion,
  'MANAGED_DELETION_PREPARATION_REQUIRED' => context.t.managed_deletion_preparation_required,
  _ => null,
};

String managedDeletionErrorMessage(BuildContext context, Object error) {
  String? code;
  if (error is ApiException && error.innerException == null) {
    code = error.message;
    try {
      final body = jsonDecode(code ?? '');
      if (body is Map && body['message'] is String) {
        code = body['message'] as String;
      }
    } catch (_) {
      // Only recognized codes are displayed; malformed responses use the fallback.
    }
  }
  return _managedDeletionFailureMessage(context, code) ?? context.t.scaffold_body_error_occurred;
}

String deletionMessage(BuildContext context, PermanentDeletionResult result) {
  final message = switch (result.code) {
    'LIBRARY_DELETION_NOT_AUTHORIZED' =>
      result.scope == 'managed' ? context.t.managed_deletion_disabled : context.t.external_deletion_blocked,
    'DELETION_BATCH_NOT_AUTHORIZED' => context.t.deletion_batch_blocked,
    _ => _managedDeletionFailureMessage(context, result.code) ?? context.t.deletion_not_completed,
  };
  final scope = result.scope == 'managed'
      ? context.t.managed_deletion_scope
      : result.scope != null
      ? '${context.t.external_deletion_scope} (${result.scope})'
      : null;
  return scope == null ? message : '$scope: $message';
}
