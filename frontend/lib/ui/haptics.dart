import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../state/app_settings.dart';

/// Touch feedback for the table, gated on [AppSettings.hapticsEnabled].
///
/// Each method takes the calling widget's context and reads the setting
/// without subscribing to it, so these are safe to call from gesture
/// callbacks. The intensities map to meaning, not to taste: [tick] for a
/// selection moving, [tap] for a card leaving the hand, [thud] for something
/// the player should notice (a trick won), [nope] for a refused move.
class Haptics {
  const Haptics._();

  static bool _on(BuildContext context) =>
      SettingsScope.read(context).hapticsEnabled;

  /// The finger slid onto a different card.
  static void tick(BuildContext context) {
    if (_on(context)) HapticFeedback.selectionClick();
  }

  /// A card was thrown.
  static void tap(BuildContext context) {
    if (_on(context)) HapticFeedback.lightImpact();
  }

  /// Something worth feeling happened to this player — a trick taken.
  static void thud(BuildContext context) {
    if (_on(context)) HapticFeedback.mediumImpact();
  }

  /// The move was refused (an illegal card).
  static void nope(BuildContext context) {
    if (_on(context)) HapticFeedback.heavyImpact();
  }
}
