import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/infrastructure/memory.provider.dart';
import 'package:immich_mobile/repositories/memory_api.repository.dart';
import 'package:immich_mobile/utils/error_handler.dart';
import 'package:immich_mobile/utils/memory_card_text.dart';

class MemoryCandidates extends HookConsumerWidget {
  const MemoryCandidates({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final candidates = ref.watch(memoryCandidatesProvider).value ?? const [];
    final busy = useState(false);
    if (candidates.isEmpty) {
      return const SizedBox.shrink();
    }
    final candidate = candidates.first;
    final title = getMemoryTitle(context, candidate.memory);

    Future<void> decide(String action) async {
      busy.value = true;
      try {
        await ref.read(memoryApiRepositoryProvider).decideCandidate(candidate.id, action);
        if (!context.mounted) {
          return;
        }
        ref.invalidate(memoryCandidatesProvider);
        ref.invalidate(memoryLaneProvider);
        ref.invalidate(allMemoriesProvider);
      } catch (error, stack) {
        handleError(error, stack: stack, description: 'Failed to decide memory candidate');
      } finally {
        if (context.mounted) {
          busy.value = false;
        }
      }
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('memory_candidate_new'.tr(context: context)),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            if (candidate.memory.data.subtitle != null) Text(candidate.memory.data.subtitle!),
            Wrap(
              spacing: 8,
              children: [
                TextButton(onPressed: busy.value ? null : () => decide('save'), child: Text(context.t.save)),
                TextButton(
                  onPressed: busy.value ? null : () => decide('dismiss'),
                  child: Text('memory_candidate_dismiss'.tr(context: context)),
                ),
                TextButton(
                  onPressed: busy.value ? null : () => decide('later'),
                  child: Text('memory_candidate_later'.tr(context: context)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
