import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/pages/edit/editor.provider.dart';

/// Adjustment panel for image corrections: brightness, contrast, saturation, etc.
class AdjustmentPanel extends ConsumerWidget {
  const AdjustmentPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editorState = ref.watch(editorStateProvider);
    final editorNotifier = ref.read(editorStateProvider.notifier);

    // Define adjustment controls with their keys, labels, icons, and value ranges
    final adjustments = [
      _AdjustmentConfig(
        key: 'brightness',
        label: context.t.editor_brightness,
        icon: Icons.brightness_6,
        value: editorState.adjustments['brightness'] ?? 0.0,
        min: -1.0,
        max: 1.0,
        onChanged: (value) => editorNotifier.setAdjustment('brightness', value),
      ),
      _AdjustmentConfig(
        key: 'contrast',
        label: context.t.editor_contrast,
        icon: Icons.contrast,
        value: editorState.adjustments['contrast'] ?? 0.0,
        min: -1.0,
        max: 1.0,
        onChanged: (value) => editorNotifier.setAdjustment('contrast', value),
      ),
      _AdjustmentConfig(
        key: 'saturation',
        label: context.t.editor_saturation,
        icon: Icons.colorize,
        value: editorState.adjustments['saturation'] ?? 0.0,
        min: -1.0,
        max: 1.0,
        onChanged: (value) => editorNotifier.setAdjustment('saturation', value),
      ),
      _AdjustmentConfig(
        key: 'exposure',
        label: context.t.editor_exposure,
        icon: Icons.exposure,
        value: editorState.adjustments['exposure'] ?? 0.0,
        min: -1.0,
        max: 1.0,
        onChanged: (value) => editorNotifier.setAdjustment('exposure', value),
      ),
      _AdjustmentConfig(
        key: 'temperature',
        label: context.t.editor_temperature,
        icon: Icons.thermostat,
        value: editorState.adjustments['temperature'] ?? 0.0,
        min: -1.0,
        max: 1.0,
        onChanged: (value) => editorNotifier.setAdjustment('temperature', value),
      ),
      _AdjustmentConfig(
        key: 'shadows',
        label: context.t.editor_shadows,
        icon: Icons.tonality,
        value: editorState.adjustments['shadows'] ?? 0.0,
        min: -1.0,
        max: 1.0,
        onChanged: (value) => editorNotifier.setAdjustment('shadows', value),
      ),
      _AdjustmentConfig(
        key: 'highlights',
        label: context.t.editor_highlights,
        icon: Icons.highlight,
        value: editorState.adjustments['highlights'] ?? 0.0,
        min: -1.0,
        max: 1.0,
        onChanged: (value) => editorNotifier.setAdjustment('highlights', value),
      ),
      _AdjustmentConfig(
        key: 'hue',
        label: context.t.editor_hue,
        icon: Icons.palette,
        value: editorState.adjustments['hue'] ?? 0.0,
        min: -1.0,
        max: 1.0,
        onChanged: (value) => editorNotifier.setAdjustment('hue', value),
      ),
    ];

    return Material(
      key: const Key('editor-adjustment-panel'),
      color: Colors.black.withValues(alpha: .78),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Adjustment tool selector
            SizedBox(
              height: 72,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: adjustments.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, index) {
                  final config = adjustments[index];
                  const isSelected = false; // We'll track selected tool separately if needed
                  return _AdjustmentToolButton(
                    config: config,
                    isSelected: isSelected,
                    onTap: () {
                      // For now, all sliders are visible. Could add a selected tool concept later.
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
            // Sliders for all adjustments
            ...adjustments.map((config) => _AdjustmentSlider(config: config)),
          ],
        ),
      ),
    );
  }
}

class _AdjustmentConfig {
  final String key;
  final String label;
  final IconData icon;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  const _AdjustmentConfig({
    required this.key,
    required this.label,
    required this.icon,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });
}

class _AdjustmentToolButton extends StatelessWidget {
  final _AdjustmentConfig config;
  final bool isSelected;
  final VoidCallback onTap;

  const _AdjustmentToolButton({required this.config, required this.isSelected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = isSelected ? Colors.white : Colors.white70;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(config.icon, color: color, size: 28),
          const SizedBox(height: 4),
          Text(
            config.label,
            style: TextStyle(color: color, fontSize: 10),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _AdjustmentSlider extends StatelessWidget {
  final _AdjustmentConfig config;

  const _AdjustmentSlider({required this.config});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Icon(config.icon, color: Colors.white70, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Slider(
              key: Key('adjustment-${config.key}'),
              min: config.min,
              max: config.max,
              value: config.value,
              onChanged: config.onChanged,
              activeColor: Colors.white,
              inactiveColor: Colors.white24,
            ),
          ),
          SizedBox(
            width: 40,
            child: Text(
              (config.value * 100).round().toString(),
              style: const TextStyle(color: Colors.white, fontSize: 12),
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}
