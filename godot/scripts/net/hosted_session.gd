class_name HostedSession
extends GameSession

## A table hosted on this device: the engine, the bots and the clock all live
## here. Shared by [LocalSession] (solo vs bots) and [LanHostSession] (this
## phone hosting friends on the Wi‑Fi), which differ only in who else is
## listening and whether people are kept to a clock.
##
## The publish loop: apply an intent to the engine, then [method _publish] —
## schedule whatever the table does on its own next, push views, drain and
## announce events. Scheduling comes first so the views can carry the deadline
## they are about to be counted down against.

## The seat this device's player occupies.
const HOST_SEAT := 0

var player_name := "You"
var bot_names: Array = ["Bot 1", "Bot 2", "Bot 3"]
var difficulty := "normal"
var animation_scale := 1.0
var hands_per_game := Rules.HANDS_PER_GAME
## Whether people are kept to a clock (bids, plays, the scoreboard). Only a
## table with somebody else waiting is.
var timed := false
var seed_value := -1

var _game: CallBreakGame
var _brains: Array = [null, null, null, null]
var _seats: Array = [null, null, null, null]
var _recorder: GameRecorder
var _rng := RandomNumberGenerator.new()
var _timer: Timer
var _timer_action := Callable()
var _started := false
## The game and hand [member _dealt_at_ms] belongs to.
var _dealt_game: CallBreakGame
var _dealt_hand := -1
var _dealt_at_ms := 0


func _init() -> void:
	_rng.randomize()
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.timeout.connect(_on_timer)
	add_child(_timer)


func started() -> bool:
	return _started


# ------------------------------------------------------------- lifecycle

## Fills any open seat with a bot and deals a brand-new game.
func _deal_new_game() -> void:
	_started = true
	if _seats[HOST_SEAT] == null:
		_seats[HOST_SEAT] = GameView.make_player(HOST_SEAT, player_name, "human")
	var bot_index := 0
	for seat in 4:
		if _seats[seat] == null:
			_seats[seat] = GameView.make_player(seat, _bot_name(seat, bot_index), "bot", difficulty)
		bot_index += 1
	_game = CallBreakGame.new(_seats, seed_value, hands_per_game)
	seed_value = -1
	_brains = []
	for p in _seats:
		_brains.append(BotBrain.new(p["difficulty"], _rng) if GameView.is_bot(p) else null)
	# Minted here rather than at game over: the id has to exist before the
	# first upload attempt for a retry to resolve to the same game.
	_recorder = GameRecorder.new(mode, HOST_SEAT)
	_game.start()
	turn_deadline_ms = 0
	hand_advance_deadline_ms = 0


## The name for a bot filling [param seat], the [param bot_index]th seat
## filled (humans included) — the LAN host's numbering.
func _bot_name(_seat: int, bot_index: int) -> String:
	return bot_names[bot_index % bot_names.size()]


# ------------------------------------------------------------ UI intents

func wake_up() -> void:
	if _started and _clear_autoplay(HOST_SEAT):
		_publish()


func place_bid(bid: int) -> void:
	if not _started:
		return
	var woke := _clear_autoplay(HOST_SEAT)
	if _game.place_bid(HOST_SEAT, bid) or woke:
		_publish()


func play(card: String) -> void:
	if not _started:
		return
	var woke := _clear_autoplay(HOST_SEAT)
	if _game.play_card(HOST_SEAT, card) or woke:
		_publish()


func continue_to_next_hand() -> void:
	_next_from(HOST_SEAT)


func restart() -> void:
	if not _started:
		return
	_timer.stop()
	_deal_new_game()
	_publish()


func _next_from(seat: int) -> void:
	if not _started:
		return
	var woke := _clear_autoplay(seat)
	if _game.phase != GameView.HAND_OVER:
		if woke:
			_publish()
		return
	_game.next_hand()
	_publish()


# ------------------------------------------------------------ host clock

func _publish() -> void:
	if not is_inside_tree() or status == CLOSED:
		return
	_schedule_next()
	view = _view_for(HOST_SEAT)
	_broadcast_views()
	for event in _game.take_events():
		_record(event)
		_announce(event)
	changed.emit()


## Emits an event locally. [LanHostSession] also fans it out to guests.
func _announce(event: Dictionary) -> void:
	game_event.emit(event)


## Pushes views to anyone else at the table. Nobody, on a solo table.
func _broadcast_views() -> void:
	pass


## A seat's view with the table's clocks stamped on it, in unix millis, so
## every device counts down against this one's.
func _view_for(seat: int) -> GameView:
	var v := _game.view_for(seat, HOST_SEAT if timed else -1)
	var now_ticks := Time.get_ticks_msec()
	var now_unix := int(Time.get_unix_time_from_system() * 1000.0)
	v.server_time_ms = now_unix
	if turn_deadline_ms > 0 and _game.turn == seat:
		v.turn_deadline_ms = now_unix + (turn_deadline_ms - now_ticks)
	if hand_advance_deadline_ms > 0:
		v.hand_advance_ms = now_unix + (hand_advance_deadline_ms - now_ticks)
	return v


## Feeds the recorder, and hands the finished game to the upload queue —
## fire-and-forget, so a phone with no signal finishes exactly as fast.
func _record(event: Dictionary) -> void:
	if _recorder == null:
		return
	match event["event"]:
		"handOver":
			# The engine still holds this hand's bids and tricks; the next deal
			# clears them, so they are taken now.
			_recorder.record_hand(event["handIndex"], _game.bids, _game.tricks_won, event["deltas"])
		"gameOver":
			var payload := _recorder.build(_game.players(), _game.totals, event["rankings"], _game.total_hands)
			_recorder = null
			var uploader := get_node_or_null("/root/Uploader")
			if uploader != null and not payload.is_empty():
				uploader.enqueue(payload)


func _schedule(seconds: float, action: Callable) -> void:
	_timer_action = action
	_timer.start(maxf(seconds, 0.001))


func _on_timer() -> void:
	var action := _timer_action
	_timer_action = Callable()
	if action.is_valid() and status != CLOSED:
		action.call()


## Sets the table's single clock to whatever is due next.
func _schedule_next() -> void:
	_timer.stop()
	_timer_action = Callable()
	turn_deadline_ms = 0
	if not _started:
		return

	# The scoreboard waits on a timed table only; the deadline is kept across
	# republishes so somebody joining or leaving the wait cannot push it back.
	if _game.phase == GameView.HAND_OVER and timed:
		if hand_advance_deadline_ms == 0:
			hand_advance_deadline_ms = Time.get_ticks_msec() + int(HAND_ADVANCE_WAIT * 1000)
		_schedule((hand_advance_deadline_ms - Time.get_ticks_msec()) / 1000.0, func():
			if _game.phase == GameView.HAND_OVER:
				_game.next_hand()
				_publish())
		return
	hand_advance_deadline_ms = 0

	if _game.awaiting_trick_clear:
		_schedule(TRICK_LINGER * animation_scale, func():
			_game.clear_trick()
			_publish())
		return

	var seat := _game.turn
	if seat < 0:
		return

	# Bidding opens only once the dealing animation is over on every screen:
	# until then no bot bids and no person's bid clock runs.
	var opens_in := _until_bidding_opens()

	if _is_server_driven(seat):
		_schedule(opens_in + _think_time(), func(): _take_server_turn(seat))
		return

	if not timed:
		return

	# A person is on the clock: give them a real turn, then play it for them.
	var timeout: float = opens_in + (BID_TIMEOUT if _game.phase == GameView.BIDDING \
			else PLAY_TIMEOUTS[_game.trick.size()])
	turn_deadline_ms = Time.get_ticks_msec() + int(timeout * 1000)
	_schedule(timeout, func(): _time_out_seat(seat))


## Seconds until bidding opens: [method _deal_grace] after the deal, measured
## from the deal itself so a republish (a guest joining, a tap) cannot push it
## back. Zero outside bidding and once it has passed. The stamp is keyed to the
## game and hand, so a new hand — or a restarted game, which starts again at
## hand 0 — is stamped afresh. Counted in the table's own time, like the timer
## it feeds: the debug play speed runs that faster than the wall clock.
func _until_bidding_opens() -> float:
	if _game.phase != GameView.BIDDING:
		return 0.0
	if _dealt_game != _game or _dealt_hand != _game.hand_index:
		_dealt_game = _game
		_dealt_hand = _game.hand_index
		_dealt_at_ms = Time.get_ticks_msec()
	return maxf(0.0, _deal_grace() - (Time.get_ticks_msec() - _dealt_at_ms) / 1000.0 * Engine.time_scale)


## How long after a deal bidding opens. Unscaled, like the server's: a guest's
## animation speed is theirs to choose.
func _deal_grace() -> float:
	return DEAL_GRACE


## Whether the host plays this seat: a bot, a player who dropped, or one
## already handed over after running out of time.
func _is_server_driven(seat: int) -> bool:
	var p = _seats[seat]
	if p == null:
		return true
	return GameView.is_bot(p) or p["autoplay"] or not p["connected"]


func _think_time() -> float:
	return (BOT_THINK_MIN + _rng.randf() * BOT_THINK_EXTRA) * animation_scale


## A seat ran out of time. A play-phase timeout hands it to a bot for every
## turn from here — making the table sit through the full clock on each of a
## walked-away player's turns would cost over a minute a hand. Any sign of life
## gives the seat straight back. Missing a bid settles the bid and keeps the
## seat.
func _time_out_seat(seat: int) -> void:
	if _game.turn != seat:
		return
	if _game.phase != GameView.BIDDING:
		_set_autoplay(seat, true)
	_take_server_turn(seat)


func _set_autoplay(seat: int, on: bool) -> void:
	var p = _seats[seat]
	if p == null or GameView.is_bot(p) or p["autoplay"] == on:
		return
	p["autoplay"] = on
	_game.set_player(seat, p)
	_announce({"event": "autoplay", "seat": seat, "name": p["name"], "autoplay": on})


## Gives a seat back to its player. Returns whether anything changed.
func _clear_autoplay(seat: int) -> bool:
	var p = _seats[seat]
	if p == null or not p["autoplay"]:
		return false
	_set_autoplay(seat, false)
	return true


## Plays one turn on behalf of a seat with the bots' brain, so a timed-out
## player gets a sensible move rather than a random one.
func _take_server_turn(seat: int) -> void:
	if not _started:
		return
	if _brains[seat] == null:
		_brains[seat] = BotBrain.new(difficulty, _rng)
	var brain: BotBrain = _brains[seat]
	var hand := _game.hand_of(seat)
	match _game.phase:
		GameView.BIDDING:
			_game.place_bid(seat, brain.choose_bid(hand))
		GameView.PLAYING:
			var bid: int = _game.bids[seat] if _game.bids[seat] >= 0 else 1
			_game.play_card(seat, brain.choose_card(hand, _game.trick, _game.played_this_hand,
					bid, _game.tricks_won[seat]))
		_:
			return
	_publish()


func shutdown() -> void:
	status = CLOSED
	_timer.stop()
	queue_free()
