import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/memory.model.dart';
import 'package:immich_mobile/presentation/pages/memory.page.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail.widget.dart';
import 'package:immich_mobile/presentation/widgets/memory/memory_candidates.widget.dart';
import 'package:immich_mobile/providers/haptic_feedback.provider.dart';
import 'package:immich_mobile/providers/infrastructure/memory.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/memory_card_text.dart';

/// The timeline reserves this height for the lane so its vertical scrubber remains aligned.
const memoryLaneMaxHeight = 200.0;

double memoryLaneCardWidth(double viewportWidth) {
  final width = viewportWidth * 0.4;
  if (width < 132.0) {
    return 132.0;
  }
  if (width > 148.0) {
    return 148.0;
  }
  return width;
}

double memoryLaneCardHeight(double viewportWidth) => memoryLaneCardWidth(viewportWidth) / MemoryCard.aspectRatio;

class MemoryLane extends ConsumerWidget {
  const MemoryLane({super.key, this.thumbnailBuilder});

  /// Optional deterministic thumbnail used by widget tests. The production path
  /// keeps using the normal remote thumbnail loader.
  final Widget Function(RemoteAsset asset)? thumbnailBuilder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final memoryLane = ref.watch(visibleMemoryLaneProvider);
    // A memory can briefly outlive its last asset while sync applies a tombstone. Do not
    // render an empty card (or index into a missing thumbnail) during that window.
    final memories = memoryLane.value?.where((memory) => memory.assets.isNotEmpty).toList(growable: false) ?? const [];
    if (memories.isEmpty) {
      return const MemoryCandidates();
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const MemoryCandidates(),
        LayoutBuilder(
          builder: (context, constraints) {
            // Keep the lane aligned with the timeline's 200 logical-pixel budget while
            // retaining a portrait card shape on phones and tablets. The width is derived
            // from the viewport so rotation and split-screen layouts do not change the
            // card size while a user is scrolling.
            final viewportWidth = constraints.hasBoundedWidth ? constraints.maxWidth : MediaQuery.sizeOf(context).width;
            final cardWidth = memoryLaneCardWidth(viewportWidth);
            final cardHeight = memoryLaneCardHeight(viewportWidth);
            final horizontalPadding = viewportWidth <= cardWidth ? 0.0 : 16.0;

            return SizedBox(
              height: memoryLaneMaxHeight,
              child: ListView.separated(
                key: const PageStorageKey<String>('memory-lane'),
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
                scrollCacheExtent: cardWidth * 2,
                itemCount: memories.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, index) {
                  final memory = memories[index];
                  return Center(
                    child: SizedBox(
                      width: cardWidth,
                      height: cardHeight,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(18),
                        onTap: () {
                          ref.read(hapticFeedbackProvider.notifier).heavyImpact();
                          MemoryPage.setMemory(ref, memory);
                          unawaited(context.pushRoute(MemoryRoute(memories: memories, memoryIndex: index)));
                        },
                      child: MemoryCard(
                        key: Key(memory.id),
                        memory: memory,
                        thumbnailBuilder: thumbnailBuilder,
                      ),
                      ),
                    ),
                  );
                },
              ),
            );
          },
        ),
      ],
    );
  }
}

class MemoryCard extends StatelessWidget {
  const MemoryCard({super.key, required this.memory, this.thumbnailBuilder});

  /// Width-to-height ratio matching the tall cards used by the iOS Gallery lane.
  static const aspectRatio = 0.74;

  final Memory memory;
  final Widget Function(RemoteAsset asset)? thumbnailBuilder;

  @override
  Widget build(BuildContext context) {
    final title = getMemoryTitle(context, memory);
    final colorScheme = Theme.of(context).colorScheme;
    final thumbnail = memory.assets.isEmpty
        ? null
        : thumbnailBuilder?.call(memory.assets.first) ??
            Thumbnail.remote(
              remoteId: memory.assets.first.id,
              thumbhash: memory.assets.first.thumbHash ?? '',
              fit: BoxFit.cover,
            );
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: colorScheme.surfaceContainerHighest,
        boxShadow: [
          BoxShadow(
            color: colorScheme.shadow.withValues(alpha: 0.25),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ?thumbnail,
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0.42, 1],
                  colors: [Colors.transparent, Color(0xCC000000)],
                ),
              ),
            ),
            Positioned(
              left: 14,
              right: 14,
              bottom: 14,
              child: Text(
                title,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                  fontSize: 15,
                  height: 1.2,
                  shadows: [Shadow(color: Colors.black54, blurRadius: 3)],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
