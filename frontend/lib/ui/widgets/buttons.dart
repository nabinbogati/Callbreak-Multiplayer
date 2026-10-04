import 'package:flutter/material.dart';

import '../../design/metrics.dart';
import '../../design/tokens.dart';
import 'backdrop.dart';

/// The primary action: a lit gold slab with a soft halo.
///
/// One widget for every "do the main thing" button in the app — confirm a bid,
/// start a game, play again — so they look, press and scale identically.
/// [onTap] null renders it disabled: flattened and dimmed, with no halo.
class GoldButton extends StatelessWidget {
  const GoldButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.dense = false,
  });

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;

  /// Shorter padding, for tight spots like landscape overlays.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final enabled = onTap != null;
    final radius = BorderRadius.circular(m.sc(14, 12));

    return PressFeedback(
      onTap: onTap,
      scale: 0.96,
      child: AnimatedOpacity(
        opacity: enabled ? 1 : 0.45,
        duration: const Duration(milliseconds: 160),
        child: Container(
          alignment: Alignment.center,
          padding: EdgeInsets.symmetric(
            horizontal: m.s(18),
            vertical: dense ? m.sc(11, 8) : m.sc(15, 11),
          ),
          decoration: BoxDecoration(
            gradient: goldButtonGradient,
            borderRadius: radius,
            border: Border.all(color: const Color(0x66FFF6D8), width: 1),
            boxShadow: enabled
                ? AppShadows.glow(AppColors.goldDeep, strength: 0.9, blur: 16)
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: m.sc(18, 16), color: AppColors.onGold),
                SizedBox(width: m.s(8)),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.bold(
                    dense ? m.sc(13, 12) : m.sc(15, 13),
                    AppColors.onGold,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The secondary action: a quiet glass slab beside a [GoldButton].
class GhostButton extends StatelessWidget {
  const GhostButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.dense = false,
  });

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return PressFeedback(
      onTap: onTap,
      scale: 0.96,
      child: Container(
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(
          horizontal: m.s(16),
          vertical: dense ? m.sc(11, 8) : m.sc(15, 11),
        ),
        decoration: BoxDecoration(
          color: const Color(0x14FFFFFF),
          borderRadius: BorderRadius.circular(m.sc(14, 12)),
          border: Border.all(color: AppColors.hairlineStrong),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: m.sc(17, 15), color: AppColors.textOnDark),
              SizedBox(width: m.s(7)),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.semiBold(
                  dense ? m.sc(13, 12) : m.sc(14, 13),
                  AppColors.textOnDark,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The raised glass card every floating panel sits in — dialogs, the bid
/// panel, the scoreboard, the reconnect notice.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding,
    this.accent = AppColors.goldBorder,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;

  /// Tints the hairline border; gold by default.
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Container(
      padding: padding ?? EdgeInsets.all(m.s(20)),
      decoration: BoxDecoration(
        gradient: surfaceGradient,
        borderRadius: BorderRadius.circular(m.s(20)),
        border: Border.all(color: accent.withValues(alpha: 0.38)),
        boxShadow: AppShadows.high,
      ),
      child: child,
    );
  }
}

/// A two-button confirmation dialog in the app's glass chrome — "Quit game?",
/// "Rejoin your game?". Pops `true` for [confirmLabel], `false` for
/// [cancelLabel].
class ConfirmDialog extends StatelessWidget {
  const ConfirmDialog({
    super.key,
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.cancelLabel,
    this.icon,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final String cancelLabel;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: EdgeInsets.symmetric(horizontal: m.s(32)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: m.s(320)),
        child: PopIn(
          child: GlassPanel(
            padding: EdgeInsets.fromLTRB(m.s(22), m.s(22), m.s(22), m.s(20)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Container(
                    width: m.s(48),
                    height: m.s(48),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.gold.withValues(alpha: 0.12),
                      border: Border.all(
                        color: AppColors.goldBorder.withValues(alpha: 0.5),
                      ),
                    ),
                    child: Icon(icon, size: m.s(22), color: AppColors.gold),
                  ),
                  SizedBox(height: m.s(14)),
                ],
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: AppText.bold(m.s(18), AppColors.textPrimary),
                ),
                SizedBox(height: m.s(8)),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: AppText.medium(m.s(13), AppColors.textMuted),
                ),
                SizedBox(height: m.s(22)),
                Row(
                  children: [
                    Expanded(
                      child: GhostButton(
                        label: cancelLabel,
                        dense: true,
                        onTap: () => Navigator.of(context).pop(false),
                      ),
                    ),
                    SizedBox(width: m.s(12)),
                    Expanded(
                      child: GoldButton(
                        label: confirmLabel,
                        dense: true,
                        onTap: () => Navigator.of(context).pop(true),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A one-shot scale-and-fade entrance for panels that appear over the table.
/// Runs once on mount and then stays out of the way (no repeating ticker).
class PopIn extends StatelessWidget {
  const PopIn({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 280),
    this.from = 0.9,
  });

  final Widget child;
  final Duration duration;

  /// Starting scale.
  final double from;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: duration,
      curve: Curves.easeOutBack,
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Transform.scale(scale: from + (1 - from) * t, child: child),
      ),
    );
  }
}
