import 'package:flutter/widgets.dart';
import 'package:immich_mobile/domain/models/deletion_result.model.dart';
import 'package:immich_mobile/generated/translations.g.dart';

String deletionMessage(BuildContext context, PermanentDeletionResult result) {
  final message = switch (result.code) {
    'LIBRARY_DELETION_NOT_AUTHORIZED' =>
      result.scope == 'managed' ? context.t.managed_deletion_disabled : context.t.external_deletion_blocked,
    'MANAGED_DELETION_PREPARATION_REQUIRED' => context.t.managed_deletion_preparation_required,
    'DELETION_BATCH_NOT_AUTHORIZED' => context.t.deletion_batch_blocked,
    _ => context.t.deletion_not_completed,
  };
  final scope = result.scope == 'managed'
      ? context.t.managed_deletion_scope
      : result.scope != null
      ? '${context.t.external_deletion_scope} (${result.scope})'
      : null;
  return scope == null ? message : '$scope: $message';
}
