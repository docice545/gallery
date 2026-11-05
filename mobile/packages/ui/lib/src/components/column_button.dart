import 'dart:async';
import 'dart:core';

import 'package:flutter/material.dart';
import 'package:immich_ui/src/constants.dart';
import 'package:immich_ui/src/internal.dart';

class ImmichColumnButton extends StatefulWidget {
  final IconData icon;
  final Widget? leadingIcon;
  final bool preserveIconWhileLoading;
  final double maxLabelWidth;
  final int? maxLabelLines;
  final String label;
  final FutureOr<void> Function() onPressed;
  final FutureOr<void> Function()? onLongPress;
  final bool compact;
  final bool disabled;
  final bool? loading;

  const ImmichColumnButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.leadingIcon,
    this.preserveIconWhileLoading = false,
    this.maxLabelWidth = 90,
    this.maxLabelLines = 2,
    this.onLongPress,
    this.disabled = false,
    this.compact = false,
    this.loading,
  });

  @override
  State<ImmichColumnButton> createState() => _ImmichColumnButtonState();
}

class _ImmichColumnButtonState extends State<ImmichColumnButton> {
  bool _running = false;
  bool get _isLoading => widget.loading ?? _running;
  bool get _isDisabled => widget.disabled || _isLoading;

  Future<void> _runAction(FutureOr<void> Function() action) async {
    setState(() => _running = true);
    try {
      await action();
    } finally {
      if (mounted) {
        setState(() => _running = false);
      }
    }
  }

  VoidCallback? get _onPressed => _isDisabled ? null : () => _runAction(widget.onPressed);

  VoidCallback? get _onLongPress =>
      _isDisabled || widget.onLongPress == null ? null : () => _runAction(widget.onLongPress!);

  @override
  Widget build(BuildContext context) {
    final foreground = context.colorOverride ?? Theme.of(context).colorScheme.onSurface;

    return TextButton(
      onPressed: _onPressed,
      onLongPress: _onLongPress,
      style: TextButton.styleFrom(
        foregroundColor: foreground,
        padding: widget.compact
            ? const EdgeInsets.symmetric(horizontal: 4)
            : const .symmetric(horizontal: ImmichSpacing.sm, vertical: ImmichSpacing.md),
        tapTargetSize: .shrinkWrap,
        shape: const RoundedRectangleBorder(borderRadius: .all(.circular(ImmichRadius.xl))),
      ),
      child: ConstrainedBox(
        constraints: .new(maxWidth: widget.maxLabelWidth),
        child: Column(
          mainAxisSize: .min,
          children: [
            SizedBox(
              height: widget.compact ? 48 : null,
              child: Center(
                widthFactor: 1,
                child: _isLoading && !widget.preserveIconWhileLoading
                    ? const SizedBox.square(
                        dimension: ImmichIconSize.md,
                        child: CircularProgressIndicator(strokeWidth: ImmichBorderWidth.lg),
                      )
                    : widget.leadingIcon ?? Icon(widget.icon, size: ImmichIconSize.md),
              ),
            ),
            if (!widget.compact) const SizedBox(height: ImmichSpacing.sm),
            Text(
              widget.label,
              maxLines: widget.maxLabelLines,
              textAlign: .center,
              overflow: widget.maxLabelLines == null ? TextOverflow.visible : TextOverflow.ellipsis,
              softWrap: true,
              style: .new(fontSize: widget.compact ? 11 : ImmichTextSize.body, fontWeight: .w500),
            ),
          ],
        ),
      ),
    );
  }
}
