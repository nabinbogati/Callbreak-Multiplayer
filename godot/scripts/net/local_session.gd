class_name LocalSession
extends HostedSession

## A solo table against three bots, hosted entirely on this device. Seat 0 is
## the player. Nobody is kept to a clock — a game against bots is never
## hurried.


func _init(name_in := "You", difficulty_in := "normal", hands := Rules.HANDS_PER_GAME,
		scale := 1.0, seed_in := -1) -> void:
	super()
	mode = "bots"
	player_name = name_in
	difficulty = difficulty_in
	hands_per_game = hands
	animation_scale = scale
	seed_value = seed_in
	status = READY


func _ready() -> void:
	_deal_new_game()
	_publish()


## Seats 1–3 are Bot 1–3, clockwise from the player.
func _bot_name(seat: int, _bot_index: int) -> String:
	return bot_names[(seat - 1) % bot_names.size()]
