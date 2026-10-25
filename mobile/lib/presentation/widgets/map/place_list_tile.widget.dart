import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';

/// Content determines row height, including with large accessibility fonts.
/// The preview stays beside the name without a screen-width-sized inner label.
class PlaceListTile extends StatelessWidget {
  const PlaceListTile({
    super.key,
    required this.name,
    required this.sourceName,
    required this.thumbnail,
    required this.onTap,
  });

  final String name;
  final String sourceName;
  final Widget thumbnail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
    child: Material(
      color: context.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: SizedBox(width: 64, height: 64, child: thumbnail),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(name, style: context.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w500)),
                    if (name != sourceName)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          sourceName,
                          style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
