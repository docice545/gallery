import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/actions/delete.action.dart';
import 'package:immich_mobile/presentation/actions/restore.action.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_control_surface.dart';
import 'package:immich_mobile/presentation/widgets/icons/proposal/foto_icon.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';

/// The same two actions and geometry in trash selection and the trash viewer.
/// Actions retain their existing owner checks and irreversible-delete dialog.
class TrashActionBar extends ConsumerStatefulWidget {
  const TrashActionBar({super.key, required this.source});
  final ActionSource source;

  @override
  ConsumerState<TrashActionBar> createState() => _TrashActionBarState();
}

class _TrashActionBarState extends ConsumerState<TrashActionBar> {
  bool _running = false;

  Future<void> _run(ActionItem action) async {
    if (_running) {
      return;
    }
    setState(() => _running = true);
    try {
      await action.onAction();
    } finally {
      if (mounted) {
        setState(() => _running = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(readonlyModeProvider)) {
      return const SizedBox.shrink();
    }
    final restore = RestoreAction(source: widget.source).create(context, ref);
    final delete = DeleteAction(source: widget.source).create(context, ref);
    final labels = [context.t.restore, context.t.delete_permanently];
    final actions = [restore, delete];
    final colors = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelMedium!.copyWith(fontSize: 13);

    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 392),
          child: ViewerControlSurface(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  var widest = 0.0;
                  for (final label in labels) {
                    final measure = TextPainter(
                      text: TextSpan(text: label, style: style),
                      textScaler: MediaQuery.textScalerOf(context),
                      textDirection: Directionality.of(context),
                    )..layout();
                    if (measure.width > widest) {
                      widest = measure.width;
                    }
                    measure.dispose();
                  }
                  // Large text gets two full-width rows, never an ellipsis or a
                  // broken caption. Ordinary phone sizes keep two icon columns.
                  final stacked = widest + 16 > constraints.maxWidth / 2;
                  Widget button(int index) {
                    final enabled = actions[index] != null && !_running;
                    final color = enabled
                        ? (index == 0 ? colors.primary : colors.error)
                        : colors.onSurface.withValues(alpha: .38);
                    final icon = FotoIcon(
                      kind: index == 0 ? FotoIconKind.restore : FotoIconKind.trash,
                      semanticLabel: labels[index],
                      size: 24,
                      state: !enabled
                          ? FotoIconState.disabled
                          : index == 0
                          ? FotoIconState.active
                          : FotoIconState.destructive,
                    );
                    final label = Text(
                      labels[index],
                      style: style.copyWith(color: color),
                      softWrap: false,
                      maxLines: 1,
                    );
                    return Semantics(
                      button: true,
                      enabled: enabled,
                      label: labels[index],
                      child: Tooltip(
                        message: labels[index],
                        child: InkWell(
                          key: ValueKey(index == 0 ? 'trash-restore' : 'trash-delete-permanently'),
                          onTap: enabled ? () => unawaited(_run(actions[index]!)) : null,
                          borderRadius: BorderRadius.circular(20),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: ExcludeSemantics(
                              child: stacked
                                  ? SizedBox(
                                      height: 52,
                                      child: Row(
                                        children: [
                                          icon,
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Align(
                                              alignment: AlignmentDirectional.centerStart,
                                              child: FittedBox(fit: BoxFit.scaleDown, child: label),
                                            ),
                                          ),
                                        ],
                                      ),
                                    )
                                  : SizedBox(
                                      height:
                                          60 +
                                          (MediaQuery.textScalerOf(context).scale(13) - 13).clamp(0, double.infinity),
                                      child: Column(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [icon, const SizedBox(height: 6), label],
                                      ),
                                    ),
                            ),
                          ),
                        ),
                      ),
                    );
                  }

                  return stacked
                      ? Column(mainAxisSize: MainAxisSize.min, children: [button(0), button(1)])
                      : Row(
                          children: [
                            Expanded(child: button(0)),
                            Expanded(child: button(1)),
                          ],
                        );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
