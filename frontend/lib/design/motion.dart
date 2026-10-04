import 'package:flutter/widgets.dart';

import '../state/app_settings.dart';

/// Every gameplay timing in one place.
///
/// Several of these have to agree with each other across widgets — a thrown
/// card's top-level flight and the copy [TrickCluster] settles on the felt run
/// the same path for the same length of time, and the whole throw → gather →
/// sweep sequence must finish inside the host's trick linger (1100 ms on the
/// Go server, the LAN host and the solo table alike) or the trick is cleared
/// mid-animation. Keeping them side by side makes those budgets visible.
///
/// All values are base milliseconds at [AnimationSpeed.normal]; scale them
/// with [Motion.scaled] and the player's animation-speed setting.
class Motion {
  const Motion._();

  // ------------------------------------------------------------ trick cards

  /// A card travelling from a hand (or a seat) to its resting spot on the felt.
  static const throwMs = 380;

  /// Once a trick is decided, the four cards first slide together onto the
  /// winning card…
  static const gatherMs = 170;

  /// …then the stack sweeps off toward the winner's seat.
  static const sweepMs = 330;

  /// Total on-screen life of a completed trick's animation. Must stay below
  /// the hosts' 1100 ms trick linger with headroom for a late frame.
  static const trickAnimationMs = throwMs + gatherMs + sweepMs;

  // ---------------------------------------------------------------- dealing

  /// The deck dropping onto the felt.
  static const dealIntroMs = 180;

  /// Two quick riffles before the first card goes out.
  static const shuffleMs = 440;

  /// Gap between consecutive cards leaving the deck.
  static const dealGapMs = 44;

  /// One card's flight from the deck to its seat.
  static const dealFlightMs = 360;

  /// The tail after the last card lands, before the overlay hands off.
  static const dealOutroMs = 140;

  /// Whole deal, start to finish.
  static const dealTotalMs =
      dealIntroMs + shuffleMs + dealGapMs * 51 + dealFlightMs + dealOutroMs;

  // ------------------------------------------------------------------- hand

  /// Legal cards rising when the turn comes round, and slots closing up.
  static const slotMs = 220;

  /// Press-and-hold preview growing in.
  static const previewMs = 130;

  /// A dealt card turning face up in the hand.
  static const revealMs = 200;

  // ----------------------------------------------------------------- curves

  /// Material 3's emphasized curve: quick to start, long gentle settle.
  static const emphasized = Cubic(0.2, 0.0, 0.0, 1.0);

  /// Decelerating entrance — things arriving on screen.
  static const enter = Cubic(0.05, 0.7, 0.1, 1.0);

  /// Accelerating exit — things leaving.
  static const exit = Cubic(0.3, 0.0, 0.8, 0.15);

  /// The player's animation-speed multiplier, read without subscribing (for
  /// gesture callbacks and timers outside build).
  static double scaleOf(BuildContext context) =>
      SettingsScope.read(context).animationSpeed.durationScale;

  /// [scale] as applied to the trick sequence (throw, gather, sweep). Capped
  /// so that even on "slow" the whole sequence still fits a networked host's
  /// fixed 1100 ms linger — past it the server clears the trick and the cards
  /// would vanish mid-sweep. (A solo table stretches its own linger with the
  /// setting, so the cap only ever shortens the wait there.)
  static double trickScale(double scale) =>
      scale * trickAnimationMs > 1040 ? 1040 / trickAnimationMs : scale;

  static Duration scaled(int baseMs, double scale) =>
      Duration(milliseconds: (baseMs * scale).round());
}
