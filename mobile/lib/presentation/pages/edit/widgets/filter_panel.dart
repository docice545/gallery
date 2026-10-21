import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/filters.dart';
import 'package:immich_mobile/presentation/pages/edit/editor.provider.dart';
import 'package:immich_mobile/generated/translations.g.dart';

/// Filter panel for selecting and adjusting photo filters
class FilterPanel extends ConsumerWidget {
  const FilterPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editorState = ref.watch(editorStateProvider);
    final editorNotifier = ref.read(editorStateProvider.notifier);
    // Get the source image from the editor page state
    // We'll pass it via a provider or directly from the parent
    final sourceImage = ref.watch(editorSourceImageProvider);

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
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemBuilder: (context, index) {
                  final isSelected = editorState.selectedFilterIndex == index;
                  return _FilterThumbnail(
                    index: index,
                    name: filterNames[index],
                    filter: filters[index],
                    isSelected: isSelected,
                    sourceImage: sourceImage,
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
                    Text(
                      context.t.editor_filter_intensity,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Slider(
                        key: const Key('filter-intensity-slider'),
                        min: 0.0,
                        max: 1.0,
                        value: editorState.filterIntensity,
                        onChanged: (value) => editorNotifier.setFilter(
                          editorState.selectedFilterIndex,
                          intensity: value,
                        ),
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

/// Provider for the source image used in filter thumbnails
/// This is set by the editor page when the image is loaded
final editorSourceImageProvider = StateProvider<ui.Image?>((ref) => null);

class _FilterThumbnail extends StatelessWidget {
  final int index;
  final String name;
  final ColorFilter filter;
  final bool isSelected;
  final ui.Image? sourceImage;
  final double filterIntensity;
  final VoidCallback onTap;

  const _FilterThumbnail({
    required this.index,
    required this.name,
    required this.filter,
    required this.isSelected,
    required this.sourceImage,
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
              border: isSelected
                  ? Border.all(color: Colors.white, width: 3)
                  : Border.all(color: Colors.transparent, width: 3),
              image: DecorationImage(
                image: _FilterPreviewImage(
                  filter: applyFilterIntensity(index, filterIntensity),
                  sourceImage: sourceImage,
                ),
                fit: BoxFit.cover,
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

/// An image that shows the filter applied to the source image
class _FilterPreviewImage extends ImageProvider<_FilterPreviewImage> {
  final ColorFilter filter;
  final ui.Image? sourceImage;

  const _FilterPreviewImage({required this.filter, this.sourceImage});

  @override
  ImageStreamCompleter load(_FilterPreviewImage key, ImageDecoderCallback decode) {
    return OneFrameImageStreamCompleter(
      SynchronousFuture<ImageInfo>(
        ImageInfo(
          image: _createFilterPreview(key.filter, key.sourceImage),
          scale: 1.0,
        ),
      ),
    );
  }

  @override
  Future<_FilterPreviewImage> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  static ui.Image _createFilterPreview(ColorFilter filter, ui.Image? sourceImage) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, 60, 60));
    
    if (sourceImage != null) {
      // Draw the source image scaled to fit
      final srcRect = Rect.fromLTWH(0, 0, sourceImage.width.toDouble(), sourceImage.height.toDouble());
      final dstRect = Rect.fromLTWH(0, 0, 60, 60);
      final paint = Paint()..filterQuality = FilterQuality.low;
      canvas.drawImageRect(sourceImage, srcRect, dstRect, paint);
      canvas.drawRect(dstRect, Paint()..colorFilter = filter);
    } else {
      // Fallback to gradient if no source image
      final rect = Rect.fromLTWH(0, 0, 60, 60);
      final gradient = LinearGradient(
        colors: [Colors.grey.shade300, Colors.grey.shade600],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ).createShader(rect);
      
      canvas.drawRect(rect, Paint()..shader = gradient);
      canvas.drawRect(rect, Paint()..colorFilter = filter);
    }
    
    final picture = recorder.endRecording();
    return picture.toImageSync(60, 60);
  }
}
