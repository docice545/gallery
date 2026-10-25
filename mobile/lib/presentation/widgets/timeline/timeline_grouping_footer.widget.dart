import 'package:flutter/material.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_grouping_selector.widget.dart';

/// A measured, non-floating timeline control for compact sheets and Trash.
///
/// Place in Scaffold.bottomNavigationBar so photo rows and floating snackbars
/// receive its actual height, including Android's gesture/navigation safe area.
class TimelineGroupingFooter extends StatelessWidget {
  const TimelineGroupingFooter({super.key});

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.viewInsetsOf(context).bottom > 0) {
      return const SizedBox.shrink();
    }

    return Material(
      key: const Key('timeline-grouping-footer'),
      color: Theme.of(context).colorScheme.surface,
      child: const SafeArea(
        top: false,
        minimum: EdgeInsets.fromLTRB(12, 4, 12, 4),
        child: Center(heightFactor: 1, child: TimelineGroupingSelector()),
      ),
    );
  }
}
