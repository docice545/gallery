import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';

class ImmichTitleText extends StatelessWidget {
  final double fontSize;
  final Color? color;

  const ImmichTitleText({super.key, this.fontSize = 48, this.color});

  @override
  Widget build(BuildContext context) {
    return Text(
      context.t.app_name,
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: fontSize * 0.7,
        fontWeight: FontWeight.bold,
        color: color ?? context.primaryColor,
        letterSpacing: -1.0,
      ),
    );
  }
}
