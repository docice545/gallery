import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/filters.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/pages/edit/editor.provider.dart';

/// Filter panel for selecting and adjusting photo filters
class FilterPanel extends ConsumerWidget {
  final ImageProvider source;
  const FilterPanel({super.key, required this.source});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editorState = ref.watch(editorStateProvider);
    final editorNotifier = ref.read(editorStateProvider.notifier);
    return Material(
      key: const Key('editor-filter-panel'),
      color: Colors.black.withValues(alpha: .78),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Filter thumbnails
            SizedBox(
              height: 96,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: filters.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, index) {
                  final isSelected = editorState.selectedFilterIndex == index;
                  return _FilterThumbnail(
                    index: index,
                    name: filterNames[index],
                    filter: filters[index],
                    isSelected: isSelected,
                    source: source,
                    filterIntensity: editorState.filterIntensity,
                    onTap: () => editorNotifier.setFilter(index, intensity: editorState.filterIntensity),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
            // Intensity slider
            if (editorState.selectedFilterIndex > 0) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(
                  children: [
                    Text(context.t.editor_filter_intensity, style: const TextStyle(color: Colors.white, fontSize: 14)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Slider(
                        key: const Key('filter-intensity-slider'),
                        min: 0.0,
                        max: 1.0,
                        value: editorState.filterIntensity,
                        onChanged: (value) =>
                            editorNotifier.setFilter(editorState.selectedFilterIndex, intensity: value),
                        activeColor: Colors.white,
                        inactiveColor: Colors.white24,
                      ),
                    ),
                    SizedBox(
                      width: 40,
                      child: Text(
                        '${(editorState.filterIntensity * 100).round()}%',
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                        textAlign: TextAlign.end,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FilterThumbnail extends StatelessWidget {
  final int index;
  final String name;
  final ColorFilter filter;
  final bool isSelected;
  final ImageProvider source;
  final double filterIntensity;
  final VoidCallback onTap;

  const _FilterThumbnail({
    required this.index,
    required this.name,
    required this.filter,
    required this.isSelected,
    required this.source,
    required this.filterIntensity,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: isSelected ? Colors.yellow : Colors.transparent, width: 3),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: ColorFiltered(
                colorFilter: applyFilterIntensity(index, filterIntensity),
                child: Image(image: source, width: 60, height: 60, fit: BoxFit.cover),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            name,
            style: TextStyle(
              color: isSelected ? Colors.white : Colors.white70,
              fontSize: 10,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
