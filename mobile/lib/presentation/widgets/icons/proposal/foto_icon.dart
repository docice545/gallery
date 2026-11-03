// Review candidate only. Viewer/editor adoption requires Issue 17 design approval.
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'foto_icon_paths.dart';

export 'foto_icon_paths.dart' show FotoIconKind;

enum FotoIconState { normal, active, disabled, destructive }

class FotoIcon extends StatelessWidget {
  const FotoIcon({
    super.key,
    required this.kind,
    required this.semanticLabel,
    this.size = 22,
    this.state = FotoIconState.normal,
  }) : assert(size == 20 || size == 22 || size == 24);

  final FotoIconKind kind;
  final String semanticLabel;
  final double size;
  final FotoIconState state;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = switch (state) {
      FotoIconState.normal => colors.onSurface,
      FotoIconState.active => colors.primary,
      FotoIconState.disabled => colors.onSurface.withValues(alpha: .38),
      FotoIconState.destructive => colors.error,
    };
    final stroke =
        (size == 20
            ? 1.65
            : size == 22
            ? 1.75
            : 1.85) *
        24 /
        size;
    return SvgPicture.string(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" '
      'fill="none" stroke="black" stroke-width="$stroke" '
      'stroke-linecap="round" stroke-linejoin="round">${fotoIconPaths[kind]}</svg>',
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
      semanticsLabel: semanticLabel,
    );
  }
}

/// Uses the existing theme and standard accessible interaction behavior.
/// This proposal delegates the original callback; it owns no editor commands.
class FotoIconButton extends StatelessWidget {
  const FotoIconButton({
    super.key,
    required this.kind,
    required this.label,
    required this.onPressed,
    this.selected = false,
    this.destructive = false,
    this.size = 22,
  });

  final FotoIconKind kind;
  final String label;
  final VoidCallback? onPressed;
  final bool selected;
  final bool destructive;
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    selected: selected,
    child: SizedBox.square(
      dimension: 48,
      child: IconButton(
        tooltip: label,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          minimumSize: const Size.square(48),
          padding: EdgeInsets.zero,
          backgroundColor: selected ? Theme.of(context).colorScheme.primaryContainer : null,
        ),
        icon: ExcludeSemantics(
          child: FotoIcon(
            kind: kind,
            semanticLabel: label,
            size: size,
            state: onPressed == null
                ? FotoIconState.disabled
                : destructive
                ? FotoIconState.destructive
                : selected
                ? FotoIconState.active
                : FotoIconState.normal,
          ),
        ),
      ),
    ),
  );
}
