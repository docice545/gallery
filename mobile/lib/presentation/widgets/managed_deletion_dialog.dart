import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/deletion_result.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/repositories/asset_api.repository.dart';
import 'package:immich_mobile/utils/deletion_message.dart';
import 'package:immich_mobile/widgets/common/confirm_dialog.dart';

class ManagedDeletionDialog extends ConsumerStatefulWidget {
  const ManagedDeletionDialog({super.key, this.external = false});
  final bool external;
  @override
  ConsumerState<ManagedDeletionDialog> createState() => _ManagedDeletionDialogState();
}

class _ManagedDeletionDialogState extends ConsumerState<ManagedDeletionDialog> {
  ManagedDeletionStatus? _status;
  bool _busy = false;
  String? _error;
  List<Map<String, dynamic>>? _libraries;
  String? _libraryId;
  int _loadRevision = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final revision = ++_loadRevision;
    try {
      final repository = ref.read(assetApiRepositoryProvider);
      if (widget.external && _libraries == null) {
        final libraries = await repository.libraryDeletionScopes();
        if (!mounted || revision != _loadRevision) {
          return;
        }
        setState(() {
          _libraries = libraries;
          _libraryId = libraries.isEmpty ? null : libraries.first['scope'] as String;
        });
        if (_libraryId == null) {
          return;
        }
      }
      final scope = _libraryId;
      final status = widget.external
          ? await repository.libraryDeletionStatus(scope!)
          : await repository.managedDeletionStatus();
      if (revision != _loadRevision || (widget.external && scope != _libraryId)) {
        return;
      }
      if (mounted) {
        setState(() {
          _status = status;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted && revision == _loadRevision) {
        setState(() => _error = managedDeletionErrorMessage(context, error));
      }
    }
  }

  Future<void> _change(bool enabled) async {
    final scope = _libraryId;
    if (enabled) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => ConfirmDialog(
          title: widget.external ? context.t.external_deletion_enable : context.t.managed_deletion_enable,
          content: widget.external ? context.t.external_deletion_confirm : context.t.managed_deletion_confirm,
          ok: widget.external ? context.t.external_deletion_enable : context.t.managed_deletion_enable,
        ),
      );
      if (confirmed != true || !mounted || scope != _libraryId) {
        return;
      }
    }
    await _run(
      () => widget.external
          ? ref.read(assetApiRepositoryProvider).setLibraryDeletionConsent(scope!, enabled)
          : ref.read(assetApiRepositoryProvider).setManagedDeletionConsent(enabled),
    );
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      await _load();
    } catch (error) {
      if (mounted) {
        final message = managedDeletionErrorMessage(context, error);
        await _load();
        if (mounted) {
          setState(() => _error = message);
        }
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return AlertDialog(
      title: Text(widget.external ? context.t.external_deletion_title : context.t.managed_deletion_title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.external ? context.t.external_deletion_description : context.t.managed_deletion_description),
            const SizedBox(height: 16),
            if (widget.external && _libraries != null) ...[
              if (_libraries!.isEmpty)
                Text(context.t.external_deletion_empty)
              else
                DropdownButton<String>(
                  isExpanded: true,
                  value: _libraryId,
                  items: _libraries!
                      .map(
                        (library) => DropdownMenuItem<String>(
                          value: library['scope'] as String,
                          child: Text(
                            '${library['name'] ?? context.t.external_deletion_scope} (${library['scope']})',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: _busy
                      ? null
                      : (scope) {
                          if (scope == null || scope == _libraryId) {
                            return;
                          }
                          setState(() {
                            _libraryId = scope;
                            _status = null;
                            _error = null;
                          });
                          unawaited(_load());
                        },
                ),
            ],
            if (_error != null) Text(_error!, style: TextStyle(color: context.colorScheme.error)),
            if (status == null) ...[
              if (_error == null && !(widget.external && _libraries?.isEmpty == true))
                const CircularProgressIndicator()
              else if (_error != null)
                TextButton(onPressed: _load, child: Text(context.t.retry)),
            ] else ...[
              Text(
                !status.prepared
                    ? widget.external
                          ? context.t.external_deletion_preparation_required
                          : context.t.managed_deletion_preparation_required
                    : status.enabled
                    ? widget.external
                          ? context.t.external_deletion_enabled
                          : context.t.managed_deletion_enabled
                    : context.t.managed_deletion_prepared,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy || (!status.enabled && !status.prepared) ? null : () => _change(!status.enabled),
                child: Text(
                  status.enabled
                      ? context.t.managed_deletion_disable
                      : widget.external
                      ? context.t.external_deletion_enable
                      : context.t.managed_deletion_enable,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: Text(context.t.close))],
    );
  }
}
