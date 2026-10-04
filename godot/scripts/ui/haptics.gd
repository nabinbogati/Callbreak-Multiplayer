class_name Haptics
extends RefCounted

## Touch feedback for the table, gated on [member Settings.haptics_enabled].
## The intensities map to meaning, not to taste: [method tick] for a selection
## moving, [method tap] for a card leaving the hand, [method thud] for
## something the player should notice (a trick won), [method nope] for a
## refused move.

## The finger slid onto a different card.
static func tick() -> void:
	_pulse("tick", 8, 0.25)


## A card was thrown.
static func tap() -> void:
	_pulse("tap", 14, 0.45)


## Something worth feeling happened to this player — a trick taken.
static func thud() -> void:
	_pulse("thud", 24, 0.7)


## The move was refused (an illegal card).
static func nope() -> void:
	_pulse("nope", 40, 1.0)


static func _pulse(_kind: String, duration_ms: int, amplitude: float) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var settings := tree.root.get_node_or_null("Settings") if tree != null else null
	if settings == null or not settings.haptics_enabled:
		return
	Input.vibrate_handheld(duration_ms, amplitude)
