import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/providers/backup/backup.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';

/// The durable recovery flags are read directly: the Store watch cache can lag.
Future<bool> confirmFreshBackupReview(BuildContext context, StoreRepository store) async {
  if (await store.tryGet(StoreKey.recoveryFreshStartReview) == true) {
    final ready = await store.tryGet(StoreKey.recoveryFreshStartLibraryReady) == true;
    if (!context.mounted) {
      return false;
    }
    if (!ready) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('sqlite_fresh_review_title'.tr()),
          content: Text('sqlite_fresh_wait_library'.tr()),
          actions: [TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: Text('ok'.tr()))],
        ),
      );
      return false;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('sqlite_fresh_review_title'.tr()),
        content: Text('sqlite_fresh_review_warning'.tr()),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: Text('cancel'.tr())),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text('sqlite_fresh_review_confirm'.tr()),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return false;
    }
    await store.upsert(StoreKey.recoveryFreshStartReview, false);
  }
  return true;
}

class BackupToggleButton extends ConsumerStatefulWidget {
  final VoidCallback onStart;
  final VoidCallback onStop;

  const BackupToggleButton({super.key, required this.onStart, required this.onStop});

  @override
  ConsumerState<BackupToggleButton> createState() => BackupToggleButtonState();
}

class BackupToggleButtonState extends ConsumerState<BackupToggleButton> with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _gradientAnimation;
  bool _isEnabled = false;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(duration: const Duration(seconds: 8), vsync: this);

    _gradientAnimation = Tween<double>(
      begin: 0,
      end: 1,
    ).animate(CurvedAnimation(parent: _animationController, curve: Curves.easeInOut));

    _isEnabled = ref.read(appConfigProvider).backup.enabled;
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _onToggle(bool value) async {
    final store = StoreRepository(ref.read(driftProvider));
    if (value && !await confirmFreshBackupReview(context, store)) {
      return;
    }
    if (!mounted) {
      return;
    }
    await ref.read(settingsProvider).write(.backupEnabled, value);

    setState(() {
      _isEnabled = value;
    });

    if (value) {
      widget.onStart.call();
    } else {
      widget.onStop.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final uploadTasks = ref.watch(backupProvider.select((state) => state.uploadItems));

    final isSyncing = ref.watch(backupProvider.select((state) => state.isSyncing));

    final iCloudProgress = ref.watch(backupProvider.select((state) => state.iCloudDownloadProgress));

    final errorCount = ref.watch(backupProvider.select((state) => state.errorCount));

    final isProcessing = uploadTasks.isNotEmpty || isSyncing || iCloudProgress.isNotEmpty;

    return AnimatedBuilder(
      animation: _animationController,
      builder: (context, child) {
        final gradientColors = [
          Color.lerp(
            context.primaryColor.withValues(alpha: 0.5),
            context.primaryColor.withValues(alpha: 0.3),
            _gradientAnimation.value,
          )!,
          Color.lerp(
            context.primaryColor.withValues(alpha: 0.2),
            context.primaryColor.withValues(alpha: 0.4),
            _gradientAnimation.value,
          )!,
          Color.lerp(
            context.primaryColor.withValues(alpha: 0.3),
            context.primaryColor.withValues(alpha: 0.5),
            _gradientAnimation.value,
          )!,
        ];

        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.all(Radius.circular(20)),
            gradient: LinearGradient(
              colors: gradientColors,
              stops: const [0.0, 0.5, 1.0],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(color: context.primaryColor.withValues(alpha: 0.1), blurRadius: 12, offset: const Offset(0, 2)),
            ],
          ),
          child: Container(
            margin: const EdgeInsets.all(1.5),
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.all(Radius.circular(18.5)),
              color: context.colorScheme.surfaceContainerLow,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [
                          context.primaryColor.withValues(alpha: 0.2),
                          context.primaryColor.withValues(alpha: 0.1),
                        ],
                      ),
                    ),
                    child: isProcessing
                        ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                        : Icon(Icons.cloud_upload_outlined, color: context.primaryColor, size: 24),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Flexible(
                              child: Text(
                                context.t.enable_backup,
                                style: context.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: context.primaryColor,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (errorCount > 0)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              context.t.upload_error_with_count(count: errorCount),
                              style: context.textTheme.labelMedium?.copyWith(color: context.colorScheme.error),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Switch.adaptive(value: _isEnabled, onChanged: (value) => _onToggle(value)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
