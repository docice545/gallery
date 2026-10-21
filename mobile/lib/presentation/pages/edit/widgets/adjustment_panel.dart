import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/presentation/pages/edit/editor.provider.dart';

class AdjustmentPanel extends ConsumerStatefulWidget {
  const AdjustmentPanel({super.key});
  @override
  ConsumerState<AdjustmentPanel> createState() => _AdjustmentPanelState();
}

class _AdjustmentPanelState extends ConsumerState<AdjustmentPanel> {
  String _selected = 'brightness';
  static const _tools = {
    'brightness': Icons.brightness_6,
    'contrast': Icons.contrast,
    'saturation': Icons.colorize,
    'exposure': Icons.exposure,
    'temperature': Icons.thermostat,
    'shadows': Icons.tonality,
    'highlights': Icons.highlight,
    'hue': Icons.palette,
  };
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(editorStateProvider);
    final notifier = ref.read(editorStateProvider.notifier);
    return Material(
      key: const Key('editor-adjustment-panel'),
      color: const Color(0xff191919),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 88,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final tool in _tools.entries)
                  SizedBox(
                    width: 108,
                    child: TextButton(
                      key: ValueKey('editor-adjustment-${tool.key}'),
                      onPressed: () => setState(() => _selected = tool.key),
                      style: TextButton.styleFrom(
                        foregroundColor: tool.key == _selected ? Colors.yellow : Colors.white70,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(tool.value),
                          const SizedBox(height: 4),
                          Text(context.tr('editor_${tool.key}'), maxLines: 1, overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Row(
            children: [
              const SizedBox(width: 12),
              Text(
                '${((state.adjustments[_selected] ?? 0) * 100).round()}',
                style: const TextStyle(color: Colors.white),
              ),
              Expanded(
                child: Slider(
                  key: ValueKey('adjustment-slider-$_selected'),
                  min: -1,
                  max: 1,
                  value: state.adjustments[_selected] ?? 0,
                  activeColor: Colors.yellow,
                  onChangeStart: (_) => notifier.beginGesture(),
                  onChangeEnd: (_) => notifier.endGesture(),
                  onChanged: (value) => notifier.setAdjustment(_selected, value),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
