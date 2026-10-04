class_name RoundsCard
extends RefCounted

## The Quickplay / Normal Play choice card, shared by the join sheet and the
## lobby's match-length picker.


static func make(title: String, subtitle: String, selected: bool, on_tap: Callable, compact := false) -> Pressable:
	var pad := UI.pad_hv(UI.sc(10, 8) if compact else UI.sc(14, 10), UI.sc(9, 6) if compact else UI.sc(14, 9))
	var style := UI.flat(Tokens.GOLD if selected else Tokens.PANEL, UI.sc(12, 9),
			Tokens.GOLD if selected else Tokens.HAIRLINE, 1, pad)
	var col := UI.vbox(UI.sc(2, 1) if compact else UI.sc(3, 2), [
		UI.label(title, UI.sc(13, 11) if compact else UI.sc(14, 12), Tokens.ON_GOLD if selected else Tokens.TEXT_ON_DARK,
				"bold", HORIZONTAL_ALIGNMENT_CENTER),
		UI.label(subtitle, UI.sc(10, 9) if compact else UI.sc(11, 9.5),
				Color(Tokens.ON_GOLD, 0.8) if selected else Tokens.TEXT_MUTED, "medium", HORIZONTAL_ALIGNMENT_CENTER),
	])
	return UI.pressable(UI.panel(style, col), on_tap)
