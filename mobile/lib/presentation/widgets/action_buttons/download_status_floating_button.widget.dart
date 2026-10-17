import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/providers/asset_viewer/download.provider.dart';
import 'package:immich_mobile/routing/router.dart';

class DownloadStatusFloatingButton extends ConsumerWidget {
  const DownloadStatusFloatingButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shouldShow = ref.watch(downloadStateProvider.select((state) => state.showProgress));
    final itemCount = ref.watch(downloadStateProvider.select((state) => state.taskProgress.length));
    final isDownloading = ref
        .watch(downloadStateProvider.select((state) => state.taskProgress))
        .values
        .where(
          (element) => ![
            TaskStatus.complete,
            TaskStatus.failed,
            TaskStatus.notFound,
            TaskStatus.canceled,
          ].contains(element.status),
        )
        .isNotEmpty;
    final hasFailed = ref
        .watch(downloadStateProvider.select((state) => state.taskProgress))
        .values
        .any((info) => info.status == TaskStatus.failed || info.status == TaskStatus.notFound);

    return shouldShow
        ? Badge.count(
            count: itemCount,
            textColor: context.colorScheme.onPrimary,
            backgroundColor: context.colorScheme.primary,
            child: FloatingActionButton(
              shape: RoundedRectangleBorder(
                borderRadius: const BorderRadius.all(Radius.circular(20)),
                side: BorderSide(color: context.colorScheme.outlineVariant, width: 1),
              ),
              backgroundColor: context.isDarkTheme
                  ? context.colorScheme.surfaceContainer
                  : context.colorScheme.surfaceBright,
              elevation: 2,
              onPressed: () {
                unawaited(context.pushRoute(const DownloadInfoRoute()));
              },
              child: Stack(
                alignment: AlignmentDirectional.center,
                children: [
                  isDownloading
                      ? Icon(Icons.downloading_rounded, color: context.colorScheme.primary, size: 28)
                      : Icon(
                          hasFailed ? Icons.error_outline : Icons.download_done,
                          color: hasFailed
                              ? context.colorScheme.error
                              : context.isDarkTheme
                              ? Colors.green[200]
                              : Colors.green[400],
                          size: 28,
                        ),
                  if (isDownloading)
                    const SizedBox(
                      height: 31,
                      width: 31,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        backgroundColor: Colors.transparent,
                        value: null, // Indeterminate progress
                      ),
                    ),
                ],
              ),
            ),
          )
        : const SizedBox.shrink();
  }
}
