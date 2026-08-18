import 'package:flutter/material.dart';

import '../../design/metrics.dart';
import '../../design/tokens.dart';

/// The standard text-input chrome: a filled panel whose hairline resting
/// border warms to gold while the field holds focus, and a soft gold tint on
/// hover — the input analogue of [PressFeedback] on buttons. The gold cursor
/// carries the same emphasis through every field.
InputDecoration fieldDecoration(
  Metrics m,
  String hint, {
  TextStyle? hintStyle,
  EdgeInsetsGeometry? contentPadding,
}) {
  final radius = BorderRadius.circular(m.sc(12, 9));
  final padding =
      contentPadding ??
      EdgeInsets.symmetric(horizontal: m.sc(14, 9), vertical: m.sc(14, 9));
  final hairline = const BorderSide(color: AppColors.hairline);
  return InputDecoration(
    isDense: true,
    hintText: hint,
    hintStyle: hintStyle ?? AppText.medium(m.sc(14, 12), AppColors.textFaint),
    filled: true,
    fillColor: AppColors.panel,
    contentPadding: padding,
    border: OutlineInputBorder(borderRadius: radius, borderSide: hairline),
    enabledBorder: OutlineInputBorder(borderRadius: radius, borderSide: hairline),
    focusedBorder: OutlineInputBorder(
      borderRadius: radius,
      borderSide: const BorderSide(color: AppColors.gold, width: 1.5),
    ),
  );
}