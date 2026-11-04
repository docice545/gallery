import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';

class MultiSelectStatusButton extends ConsumerWidget {
  const MultiSelectStatusButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectCount = ref.watch(multiSelectProvider.select((s) => s.selectedAssets.length));
    return Tooltip(
      message: context.t.deselect_all,
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(48, 48),
          maximumSize: const Size(double.infinity, 48),
          padding: const EdgeInsets.symmetric(horizontal: 16),
        ),
        onPressed: () => ref.read(multiSelectProvider.notifier).reset(),
        icon: Icon(Icons.close_rounded, color: context.colorScheme.onPrimary),
        label: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            selectCount.toString(),
            semanticsLabel: context.t.selected_count(count: selectCount),
            style: context.textTheme.titleMedium?.copyWith(height: 1, color: context.colorScheme.onPrimary),
          ),
        ),
      ),
    );
  }
}
