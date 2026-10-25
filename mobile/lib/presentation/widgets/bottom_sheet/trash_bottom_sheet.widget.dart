import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/presentation/actions/action.widget.dart';
import 'package:immich_mobile/presentation/actions/asset_debug.action.dart';
import 'package:immich_mobile/presentation/actions/delete.action.dart';
import 'package:immich_mobile/presentation/actions/restore.action.dart';

class TrashBottomBar extends StatelessWidget {
  const TrashBottomBar({super.key, this.docked = false});

  final bool docked;

  @override
  Widget build(BuildContext context) {
    final bar = Container(
      color: context.themeData.canvasColor,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: const SafeArea(
        top: false,
        child: Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.start,
          spacing: 4,
          runSpacing: 4,
          children: <ActionColumnButton>[
            .new(action: AssetDebugAction(source: .timeline)),
            .new(action: DeleteAction(source: .timeline)),
            .new(action: RestoreAction(source: .timeline)),
          ],
        ),
      ),
    );
    return docked ? bar : Align(alignment: Alignment.bottomCenter, child: bar);
  }
}
