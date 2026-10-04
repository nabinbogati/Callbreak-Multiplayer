import 'package:flutter/material.dart';

import '../../design/metrics.dart';
import '../../design/tokens.dart';
import '../../state/app_settings.dart';
import '../screens/settings_sheet.dart';
import 'backdrop.dart';

/// The compact settings sheet opened from the table — gameplay behaviour and
/// sound, without leaving the game. Everything here reads and writes
/// [AppSettings] through [SettingsScope], so changes apply and notify live.
Future<void> showQuickSettingsSheet(BuildContext context) async {
  await showSheet<void>(context, (sheetContext) => const _QuickSettingsBody());
}

class _QuickSettingsBody extends StatelessWidget {
  const _QuickSettingsBody();

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final settings = SettingsScope.of(context);

    return SingleChildScrollView(
      padding: EdgeInsets.all(m.s(20)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.tune_rounded, size: m.s(18), color: AppColors.gold),
              SizedBox(width: m.s(8)),
              Text('Settings', style: AppText.bold(m.s(18), AppColors.textPrimary)),
            ],
          ),
          SizedBox(height: m.s(18)),
          _ToggleRow(
            label: 'Drag to play',
            value: settings.dragToPlayEnabled,
            onChanged: (value) => settings.dragToPlayEnabled = value,
          ),
          SizedBox(height: m.s(14)),
          _ToggleRow(
            label: 'Tap twice to play',
            value: settings.tapTwiceToPlay,
            onChanged: (value) => settings.tapTwiceToPlay = value,
          ),
          SizedBox(height: m.s(14)),
          _ToggleRow(
            label: 'Auto throw last card',
            value: settings.autoThrowLastCard,
            onChanged: (value) => settings.autoThrowLastCard = value,
          ),
          SizedBox(height: m.s(14)),
          _ToggleRow(
            label: 'Auto throw last suit card',
            value: settings.autoThrowLastSuitCard,
            onChanged: (value) => settings.autoThrowLastSuitCard = value,
          ),
          SizedBox(height: m.s(18)),
          _ToggleRow(
            label: 'Background music',
            value: settings.musicEnabled,
            onChanged: (value) => settings.musicEnabled = value,
          ),
          SizedBox(height: m.s(14)),
          _ToggleRow(
            label: 'Sound effects',
            value: settings.sfxEnabled,
            onChanged: (value) => settings.sfxEnabled = value,
          ),
          SizedBox(height: m.s(14)),
          _ToggleRow(
            label: 'Vibration',
            value: settings.hapticsEnabled,
            onChanged: (value) => settings.hapticsEnabled = value,
          ),
        ],
      ),
    );
  }
}

/// One labelled On/Off pair, compact enough to sit on a table row.
class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Text(label, style: AppText.medium(m.sc(13, 12), AppColors.textOnDark)),
        ),
        SizedBox(width: m.s(10)),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _OnOffChip(
              label: 'On',
              selected: value,
              enabled: true,
              onTap: () => onChanged(true),
            ),
            SizedBox(width: m.s(6)),
            _OnOffChip(
              label: 'Off',
              selected: !value,
              enabled: true,
              onTap: () => onChanged(false),
            ),
          ],
        ),
      ],
    );
  }
}

/// A single On/Off pill; [enabled] false renders it inert and dimmed.
class _OnOffChip extends StatelessWidget {
  const _OnOffChip({
    required this.label,
    required this.selected,
    required this.enabled,
    this.onTap,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return GlassPill(
      radius: m.sc(10, 8),
      onTap: enabled ? onTap : null,
      padding: EdgeInsets.symmetric(horizontal: m.sc(16, 11), vertical: m.sc(10, 6)),
      background: selected ? AppColors.gold : AppColors.panel,
      border: selected ? AppColors.gold : AppColors.hairline,
      child: Text(
        label,
        style: AppText.semiBold(
          m.sc(13, 11),
          !enabled
              ? AppColors.textMuted
              : selected
              ? AppColors.onGold
              : AppColors.textOnDark,
        ),
      ),
    );
  }
}