import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/deletion_result.model.dart';
import 'package:immich_mobile/domain/services/asset.service.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/action_buttons/base_action_button.widget.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/trash_bottom_sheet.widget.dart';
import 'package:immich_mobile/presentation/widgets/managed_deletion_dialog.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_route_scope.dart';
import 'package:immich_mobile/providers/infrastructure/action.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/services/cleanup.service.dart';
import 'package:immich_mobile/utils/deletion_message.dart';
import 'package:immich_mobile/utils/error_handler.dart';
import 'package:immich_mobile/widgets/common/confirm_dialog.dart';
import 'package:immich_mobile/widgets/common/immich_toast.dart';

@RoutePage()
class TrashPage extends StatelessWidget {
  const TrashPage({super.key});

  static const timelineOverviewControlsEnabled = true;
  // Soft scrubber-snapping hint, not a measured height (the rendered banner is ~48 px;
  // this 24 px delta is the value the old combined constant always encoded).
  static const trashInfoBannerTopSliverHeight = 24.0;

  @override
  Widget build(BuildContext context) {
    return TimelineRouteScope(
      timelineServiceBuilder: (ref, scope, groupBy) {
        final user = ref.watch(currentUserProvider);
        if (user == null) {
          throw Exception('User must be logged in to access trash');
        }

        return ref.watch(timelineFactoryProvider).trash(user.id, groupBy: groupBy, temporalScope: scope);
      },
      child: Timeline(
        withGroupingPill: true,
        appBar: SliverAppBar(
          title: Text(context.t.trash),
          floating: true,
          snap: true,
          pinned: true,
          centerTitle: true,
          elevation: 0,
          actions: const [_TrashKebabMenu()],
        ),
        topSliverWidget: Consumer(
          builder: (context, ref, child) {
            final trashDays = ref.watch(serverInfoProvider.select((v) => v.serverConfig.trashDays));

            return SliverPadding(
              padding: const EdgeInsets.all(16.0),
              sliver: SliverToBoxAdapter(
                child: Text(
                  ref.watch(serverInfoProvider.select((v) => v.serverFeatures.trash)) &&
                          trashDays > 0 &&
                          (!ref.watch(serverInfoProvider.select((v) => v.serverFeatures.authorizedDeletion)) ||
                              ref.watch(serverInfoProvider.select((v) => v.serverFeatures.ownerStorageDeletion)))
                      ? context.t.trash_retention_scope_info(days: trashDays)
                      : context.t.trash_manual_retention_info,
                ),
              ),
            );
          },
        ),
        topSliverWidgetHeight: TrashPage.trashInfoBannerTopSliverHeight,
        bottomSheet: const TrashBottomBar(),
      ),
    );
  }
}

class _TrashKebabMenu extends ConsumerWidget {
  const _TrashKebabMenu();

  Future<void> _emptyTrash(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => ConfirmDialog(
        title: context.t.empty_trash,
        content: context.t.empty_trash_confirmation,
        ok: context.t.delete_permanently,
      ),
    );
    if (confirmed != true || !context.mounted) {
      return;
    }
    final user = ref.read(currentUserProvider);
    if (user == null) {
      return;
    }
    try {
      final service = ref.read(assetServiceProvider);
      // Capture only this owner's synchronized Trash. Do not clear all cached
      // rows based on a count-only response or delete newly arriving assets.
      final ids = await service.getTrashIds(user.id);
      if (!context.mounted) {
        return;
      }
      if (ids.isEmpty) {
        return;
      }
      final controller = BatchDeletionController(service, ids)..start();
      final outcome = await showDialog<_BatchDeletionOutcome>(
        context: context,
        barrierDismissible: false,
        builder: (_) => BatchDeletionDialog(controller: controller),
      );
      if (outcome == null) {
        return;
      }
      if (outcome.error != null) {
        Error.throwWithStackTrace(outcome.error!, outcome.stackTrace!);
      }
      final results = outcome.results!;
      final completed = results.where((result) => result.complete).map((result) => result.id).toList();
      final localIds = await service.getDeletionLocalIds(completed);
      if (!context.mounted) {
        return;
      }
      final local = await ref.read(cleanupServiceProvider).deleteLocalAssetsDetailed(localIds, trash: false);
      if (!context.mounted) {
        return;
      }
      final reasons = results
          .where((result) => !result.complete)
          .map((result) => deletionMessage(context, result))
          .toSet()
          .join(', ');
      ImmichToast.show(
        context: context,
        msg:
            '${context.t.permanent_deletion_result(removed: completed.length, remaining: results.length - completed.length, reasons: reasons)}. ${context.t.device_deletion_result(removed: local.deletedIds.length, remaining: local.remainingIds.length, names: local.remainingIds.take(25).join(', '))}',
        toastType: results.any((result) => !result.complete) || local.remainingIds.isNotEmpty
            ? ToastType.error
            : ToastType.success,
      );
    } catch (error, stack) {
      handleError(error, stack: stack, description: 'Failed to empty captured Trash selection');
    }
  }

  Future<void> _confirmAndRun(
    BuildContext context,
    WidgetRef ref, {
    required String title,
    required String content,
    required Future<ActionResult> Function(String userId) action,
    required String Function(int count) successMsg,
  }) async {
    await showDialog<bool>(
      context: context,
      builder: (_) => ConfirmDialog(
        title: title,
        content: content,
        onOk: () async {
          final user = ref.read(currentUserProvider);
          if (user == null) {
            return;
          }
          final result = await action(user.id);
          if (!context.mounted) {
            return;
          }
          ImmichToast.show(
            context: context,
            msg: result.success ? successMsg(result.count) : context.t.scaffold_body_error_occurred,
            toastType: result.success ? ToastType.success : ToastType.error,
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MenuAnchor(
      consumeOutsideTap: true,
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(context.themeData.scaffoldBackgroundColor),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.grey),
        elevation: const WidgetStatePropertyAll(4),
        shape: const WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
        ),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 6)),
      ),
      menuChildren: [
        if (ref.watch(serverInfoProvider.select((v) => v.serverFeatures.authorizedDeletion)))
          BaseActionButton(
            label: context.t.managed_deletion_title,
            iconData: Icons.shield_outlined,
            onPressed: () => showDialog<void>(context: context, builder: (_) => const ManagedDeletionDialog()),
            menuItem: true,
          ),
        BaseActionButton(
          label: context.t.empty_trash,
          iconData: Icons.delete_forever_outlined,
          onPressed: () => _emptyTrash(context, ref),
          menuItem: true,
        ),
        if (ref.watch(serverInfoProvider.select((v) => v.serverFeatures.authorizedDeletion)))
          BaseActionButton(
            label: context.t.external_deletion_title,
            iconData: Icons.folder_delete_outlined,
            onPressed: () =>
                showDialog<void>(context: context, builder: (_) => const ManagedDeletionDialog(external: true)),
            menuItem: true,
          ),
        BaseActionButton(
          label: context.t.restore_all,
          iconData: Icons.restore_outlined,
          onPressed: () => _confirmAndRun(
            context,
            ref,
            title: context.t.restore_all,
            content: context.t.assets_restore_confirmation,
            action: ref.read(actionProvider.notifier).restoreAllTrash,
            successMsg: (count) => context.t.assets_restored_count(count: count),
          ),
          menuItem: true,
        ),
      ],
      builder: (context, controller, child) {
        return IconButton(
          icon: const Icon(Icons.more_vert_rounded),
          onPressed: () => controller.isOpen ? controller.close() : controller.open(),
        );
      },
    );
  }
}

class _BatchDeletionOutcome {
  final List<PermanentDeletionResult>? results;
  final Object? error;
  final StackTrace? stackTrace;

  const _BatchDeletionOutcome.success(this.results) : error = null, stackTrace = null;
  const _BatchDeletionOutcome.failure(this.error, this.stackTrace) : results = null;
}

class BatchDeletionController {
  final AssetService service;
  final List<String> ids;
  final status = ValueNotifier<PermanentDeletionBatchStatus?>(null);
  late final Future<List<PermanentDeletionResult>> operation;
  bool canceling = false;

  BatchDeletionController(this.service, this.ids);

  void start() {
    operation = service.deleteWithResults(ids, onBatchStatus: (value) => status.value = value);
  }

  Future<void> cancel() async {
    final batchId = status.value?.id;
    if (batchId == null || canceling) {
      return;
    }
    canceling = true;
    try {
      status.value = await service.cancelDeletionBatch(batchId);
    } finally {
      canceling = false;
    }
  }

  void dispose() => status.dispose();
}

class BatchDeletionDialog extends StatefulWidget {
  final BatchDeletionController controller;

  const BatchDeletionDialog({super.key, required this.controller});

  @override
  State<BatchDeletionDialog> createState() => _BatchDeletionDialogState();
}

class _BatchDeletionDialogState extends State<BatchDeletionDialog> {
  @override
  void initState() {
    super.initState();
    widget.controller.status.addListener(_statusChanged);
    unawaited(_finishWhenComplete());
  }

  void _statusChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _finishWhenComplete() async {
    try {
      final results = await widget.controller.operation;
      if (mounted) {
        Navigator.of(context).pop(_BatchDeletionOutcome.success(results));
      }
    } catch (error, stackTrace) {
      if (mounted) {
        Navigator.of(context).pop(_BatchDeletionOutcome.failure(error, stackTrace));
      }
    }
  }

  @override
  void dispose() {
    widget.controller.status.removeListener(_statusChanged);
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.controller.status.value;
    final processed = status?.processed ?? 0;
    final total = status?.total ?? widget.controller.ids.length;
    final progress = total == 0 ? 0.0 : (processed / total).clamp(0.0, 1.0);
    final canCancel = status != null && !status.cancelled && !widget.controller.canceling;

    return AlertDialog(
      title: Text(context.t.delete_permanently),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LinearProgressIndicator(value: progress),
          const SizedBox(height: 16),
          Text(context.t.upload_progress(processed: processed, total: total, remaining: total - processed)),
          if (status?.cancelled ?? false) ...[const SizedBox(height: 8), Text(context.t.canceled)],
        ],
      ),
      actions: [
        TextButton(
          onPressed: canCancel ? widget.controller.cancel : null,
          child: Text(widget.controller.canceling ? context.t.canceling : context.t.cancel),
        ),
      ],
    );
  }
}
