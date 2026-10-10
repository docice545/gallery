import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/deletion_result.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/repositories/asset_api.repository.dart';
import 'package:immich_mobile/widgets/common/confirm_dialog.dart';

class ManagedDeletionDialog extends ConsumerStatefulWidget {
  const ManagedDeletionDialog({super.key});
  @override
  ConsumerState<ManagedDeletionDialog> createState() => _ManagedDeletionDialogState();
}

class _ManagedDeletionDialogState extends ConsumerState<ManagedDeletionDialog> {
  final _proof = TextEditingController();
  ManagedDeletionStatus? _status;
  bool _verified = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final status = await ref.read(assetApiRepositoryProvider).managedDeletionStatus();
      if (mounted) {
        setState(() {
          _status = status;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = context.t.scaffold_body_error_occurred);
      }
    }
  }

  Future<void> _change(bool enabled) async {
    if (enabled) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => ConfirmDialog(
          title: context.t.managed_deletion_enable,
          content: context.t.managed_deletion_confirm,
          ok: context.t.managed_deletion_enable,
        ),
      );
      if (confirmed != true || !mounted) {
        return;
      }
    }
    await _run(() => ref.read(assetApiRepositoryProvider).setManagedDeletionConsent(enabled));
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      await _load();
    } catch (_) {
      // No optimistic success on timeout. Reload server state on the next open/retry.
      if (mounted) {
        setState(() => _error = context.t.scaffold_body_error_occurred);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  void dispose() {
    _proof.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return AlertDialog(
      title: Text(context.t.managed_deletion_title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.t.managed_deletion_description),
            const SizedBox(height: 16),
            if (_error != null) Text(_error!, style: TextStyle(color: context.colorScheme.error)),
            if (status == null) ...[
              if (_error == null)
                const CircularProgressIndicator()
              else
                TextButton(onPressed: _load, child: Text(context.t.retry)),
            ] else ...[
              Text(
                status.enabled
                    ? context.t.managed_deletion_enabled
                    : status.prepared
                    ? context.t.managed_deletion_prepared
                    : context.t.managed_deletion_preparation_required,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy || !status.prepared ? null : () => _change(!status.enabled),
                child: Text(status.enabled ? context.t.managed_deletion_disable : context.t.managed_deletion_enable),
              ),
              if (status.canPrepare) ...[
                const Divider(),
                TextField(
                  controller: _proof,
                  enabled: !_busy,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(labelText: context.t.managed_deletion_recovery_proof),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _verified,
                  onChanged: _busy ? null : (v) => setState(() => _verified = v ?? false),
                  title: Text(context.t.managed_deletion_exclusive_roots),
                ),
                OutlinedButton(
                  onPressed: _busy || !_verified || !RegExp(r'^[a-f0-9]{64}$').hasMatch(_proof.text.trim())
                      ? null
                      : () =>
                            _run(() => ref.read(assetApiRepositoryProvider).prepareManagedDeletion(_proof.text.trim())),
                  child: Text(context.t.managed_deletion_prepare),
                ),
              ],
            ],
          ],
        ),
      ),
      actions: [TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: Text(context.t.close))],
    );
  }
}
