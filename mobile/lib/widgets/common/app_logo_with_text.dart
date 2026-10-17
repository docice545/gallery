import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/widgets/common/immich_logo.dart';

/// Reuses the existing photo mark without its baked-in product wordmark.
class AppLogoWithText extends StatelessWidget {
  const AppLogoWithText({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
    label: context.t.app_name,
    child: ExcludeSemantics(
      child: SizedBox(
        height: 43,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ImmichLogo(size: 43),
              const SizedBox(width: 8),
              Text(
                context.t.app_name,
                style: context.textTheme.titleLarge?.copyWith(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: context.primaryColor,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
