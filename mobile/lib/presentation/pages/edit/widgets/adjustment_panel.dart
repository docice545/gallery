import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/presentation/pages/edit/editor.provider.dart';
import 'package:immich_mobile/presentation/widgets/icons/proposal/foto_icon.dart';

class AdjustmentPanel extends ConsumerStatefulWidget {
  const AdjustmentPanel({super.key, this.onComplete});
  final VoidCallback? onComplete;
  @override
  ConsumerState<AdjustmentPanel> createState() => _AdjustmentPanelState();
}

class _AdjustmentPanelState extends ConsumerState<AdjustmentPanel> {
  String _selected = 'brightness';
  static const _tools = {
    'brightness': FotoIconKind.brightness,
    'contrast': FotoIconKind.contrast,
    'saturation': FotoIconKind.saturation,
    'exposure': FotoIconKind.exposure,
    'temperature': FotoIconKind.temperature,
    'shadows': FotoIconKind.shadows,
    'highlights': FotoIconKind.highlights,
    'hue': FotoIconKind.hue,
  };
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(editorStateProvider);
    final notifier = ref.read(editorStateProvider.notifier);
    return Material(
      key: const Key('editor-adjustment-panel'),
      color: Colors.transparent,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final tool in _tools.entries)
                  FotoIconButton(
                    key: ValueKey('editor-adjustment-${tool.key}'),
                    kind: tool.value,
                    label: context.tr('editor_${tool.key}'),
                    selected: tool.key == _selected,
                    onPressed: () => setState(() => _selected = tool.key),
                  ),
              ],
            ),
          ),
          Row(
            children: [
              const SizedBox(width: 12),
              Text(
                '${((state.adjustments[_selected] ?? 0) * 100).round()}',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
              ),
              Expanded(
                child: Slider(
                  key: ValueKey('adjustment-slider-$_selected'),
                  min: -1,
                  max: 1,
                  value: state.adjustments[_selected] ?? 0,
                  onChangeStart: (_) => notifier.beginGesture(),
                  onChangeEnd: (_) {
                    notifier.endGesture();
                    widget.onComplete?.call();
                  },
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
