import 'package:flutter/material.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/trash_action_bar.dart';

class TrashBottomBar extends StatelessWidget {
  const TrashBottomBar({super.key, this.docked = false});
  final bool docked;

  @override
  Widget build(BuildContext context) => docked
      ? const TrashActionBar(source: .timeline)
      : const Align(
          alignment: Alignment.bottomCenter,
          child: TrashActionBar(source: .timeline),
        );
}
