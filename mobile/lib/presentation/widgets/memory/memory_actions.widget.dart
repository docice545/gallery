import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/memory.model.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/infrastructure/memory.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:logging/logging.dart';

enum _MemoryAction { hide, delete }

/// Owner-only actions operate on the memory, never on its assets. The viewer
/// supplies pause/close callbacks so menu and confirmation cannot advance video.
class MemoryActions extends ConsumerStatefulWidget {
  const MemoryActions({required this.memory, required this.onRemoved, this.onPausedChanged, super.key});

  final Memory memory;
  final FutureOr<void> Function() onRemoved;
  final ValueChanged<bool>? onPausedChanged;

  @override
  ConsumerState<MemoryActions> createState() => _MemoryActionsState();
}

class _MemoryActionsState extends ConsumerState<MemoryActions> {
  bool _busy = false;
  bool _processing = false;

  Future<void> _select(_MemoryAction action) async {
    setState(() => _busy = true);
    var removed = false;
    try {
      if (action == _MemoryAction.delete) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('memory_delete_confirm_title'.tr(context: context)),
            content: Text('memory_delete_confirm_message'.tr(context: context)),
            actions: [
              TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(context.t.cancel)),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text('memory_delete'.tr(context: context)),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted) {
          return;
        }
      }

      setState(() => _processing = true);
      final service = ref.read(memoryManagementServiceProvider);
      if (action == _MemoryAction.hide) {
        await service.hide(widget.memory.id);
      } else {
        await service.delete(widget.memory.id);
      }
      if (!mounted) {
        return;
      }

      final tombstones = ref.read(confirmedMemoryRemovalsProvider(widget.memory.ownerId).notifier);
      tombstones.state = {...tombstones.state, widget.memory.id};
      ref.invalidate(memoryLaneProvider);
      ref.invalidate(allMemoriesProvider);
      ref.invalidate(memoryCandidatesProvider);
      removed = true;
      await widget.onRemoved();
    } catch (error, stack) {
      Logger('MemoryActions').warning('Failed to update memory visibility', error, stack);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('memory_action_failed'.tr(context: context))));
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _processing = false;
        });
        // A successful action closes the viewer; keep it paused throughout the
        // pop animation. Only cancellation/failure resumes the existing video.
        if (!removed) {
          widget.onPausedChanged?.call(false);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(currentUserProvider.select((user) => user?.id)) != widget.memory.ownerId) {
      return const SizedBox.shrink();
    }
    if (_processing) {
      return const Padding(
        padding: EdgeInsets.all(14),
        child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
      );
    }
    return PopupMenuButton<_MemoryAction>(
      tooltip: context.t.options,
      enabled: !_busy,
      icon: const Icon(Icons.more_vert, color: Colors.white),
      onOpened: () => widget.onPausedChanged?.call(true),
      onCanceled: () => widget.onPausedChanged?.call(false),
      onSelected: (action) => unawaited(_select(action)),
      itemBuilder: (context) => [
        PopupMenuItem(
          value: _MemoryAction.hide,
          child: Text('memory_hide'.tr(context: context)),
        ),
        PopupMenuItem(
          value: _MemoryAction.delete,
          child: Text('memory_delete'.tr(context: context)),
        ),
      ],
    );
  }
}
