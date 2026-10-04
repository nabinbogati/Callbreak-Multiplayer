class_name TableScreen
extends Control

## The table: seats around a felt surface, the player's hand along the bottom,
## and overlays for bidding and between-hands scores. Identical for a solo
## game against bots, a LAN table and a server table — it only ever talks to
## [GameSession].
##
## Layout is computed by hand (see [method _layout]) rather than with
## containers, because the animations need exact positions: a thrown card
## starts where the finger let go, dealt cards land on the slot the real card
## will occupy, and a won trick sweeps toward the winner's avatar.

var session: GameSession

var _backdrop := Backdrop.new("table")
## Everything inside the safe area.
var _body := Control.new()
var _hud: Control
var _round_label: Label
var _felt_area := Control.new()
var _felt := FeltSurface.new()
var _seats := {}
var _hand := HandFan.new()
var _trick := TrickCluster.new()
var _fx := Control.new()
var _overlay := Control.new()
var _banners: VBoxContainer
var _autoplay_banner: Control
var _presence_banner: Control
var _presence_timer: SceneTreeTimer
var _offline_pill: Control

var _deal: DealOverlay
var _dealing := false
var _hand_revealed := 13
var _deal_counts: Array = []
var _last_dealt_hand := -1
## Opened to reclaim a seat in a game already under way: the first deal seen
## (if already in progress) is not replayed.
var _rejoined := false

var _throw_origins := {}
var _auto_play_key := ""
var _auto_play_timer: SceneTreeTimer
var _last_wake_ms := -10000
var _show_history := false
var _overlay_state := ""
var _bid_panel: BidPanel


func _init(session_in: GameSession) -> void:
	session = session_in
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rejoined = session is RemoteSession and not (session as RemoteSession).resume_token.is_empty()


func _ready() -> void:
	add_child(_backdrop)
	_backdrop.glow_alignment_portrait = Vector2(0, -0.6)
	_backdrop.glow_alignment_landscape = Vector2(0, -0.6)
	_backdrop.glow_scale = 1.4
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_body)

	_felt_area.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_felt_area.add_child(_felt)
	_body.add_child(_felt_area)
	for slot in [SeatView.Slot.LEFT, SeatView.Slot.TOP, SeatView.Slot.RIGHT, SeatView.Slot.BOTTOM]:
		var seat := SeatView.new(slot)
		seat.visible = false
		_seats[slot] = seat
		_body.add_child(seat)
	_hand.card_thrown.connect(_on_card_thrown)
	_body.add_child(_hand)
	_body.move_child(_seats[SeatView.Slot.BOTTOM], -1)
	_trick.set_anchors_preset(Control.PRESET_FULL_RECT)
	_body.add_child(_trick)
	_fx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fx.set_anchors_preset(Control.PRESET_FULL_RECT)
	_body.add_child(_fx)
	_hud = _build_hud()
	_body.add_child(_hud)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_overlay)
	_banners = UI.vbox(6)
	_banners.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_banners)

	App.instance.layout_changed.connect(_on_layout_changed)
	resized.connect(_on_layout_changed)
	session.changed.connect(_on_session_changed)
	session.game_event.connect(_on_game_event)
	# Signals first, then the tree: a local session deals in its _ready.
	add_child(session)
	_on_layout_changed()
	_on_session_changed()


func _exit_tree() -> void:
	Audio.stop_deal()
	Audio.stop_tick()


# ------------------------------------------------------------------ input

## Any touch anywhere is proof the player is still at the table, so it takes
## their seat back from autoplay. Seen before the GUI, so it never competes
## with the hand fan underneath.
func _input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed) or not is_visible_in_tree():
		return
	var v := session.view
	if v == null or v.you < 0 or not v.my_player().get("autoplay", false):
		return
	# A floor between sends keeps a frustrated burst of taps inside the
	# server's frame budget.
	var now := Time.get_ticks_msec()
	if now - _last_wake_ms < 400:
		return
	_last_wake_ms = now
	session.wake_up()


func handle_back() -> void:
	if session.view != null and session.view.phase == GameView.GAME_OVER:
		App.instance.pop_to_root()
		return
	if not session.is_ready() and not session.is_resuming():
		_leave()
		return
	var quit := await App.instance.confirm("Quit game?", "Your progress in this round will be lost.", "Cancel", "Quit")
	if quit:
		_leave()


## An explicit quit forfeits the seat — and the "Rejoin your game?" record
## with it.
func _leave() -> void:
	if session is RemoteSession:
		var remote := session as RemoteSession
		var stored := Settings.identity.active_game()
		if not stored.is_empty() and stored["serverUrl"] == remote.server_url and stored["roomCode"] == remote.room_code:
			Settings.identity.clear_active_game()
	session.shutdown()
	App.instance.pop()


# ----------------------------------------------------------------- layout

func _on_layout_changed() -> void:
	_body.set_anchors_preset(Control.PRESET_FULL_RECT)
	_body.offset_left = UI.safe.x + UI.sc(0, 8)
	_body.offset_top = UI.safe.y
	_body.offset_right = -UI.safe.z - UI.sc(0, 8)
	_body.offset_bottom = -UI.safe.w
	_banners.position = Vector2(0, UI.safe.y + 8)
	_banners.size.x = size.x
	_layout.call_deferred()
	_rebuild_overlay(true)


func _hand_card_width() -> float:
	return UI.sc(54, 61)


## Positions the felt, seats, hand and trick for the current size.
func _layout() -> void:
	var area := _body.size
	if area.x <= 0 or area.y <= 0:
		return
	var pad := Vector4(UI.sc(14, 7), UI.sc(8, 4), UI.sc(14, 7), UI.sc(10, 4))
	_hud.position = Vector2(pad.x, pad.y) if UI.portrait else Vector2(14, 12)
	_hud.size = Vector2(area.x - (pad.x + pad.z if UI.portrait else 28), 36)
	var top := pad.y + (36.0 + UI.sc(8, 4) if UI.portrait else 34.0)

	_hand.card_width = _hand_card_width()
	var fan_h := HandFan.LIFT + _hand.card_height()
	var hand_area_h := fan_h + 30.0
	var hand_top := area.y - pad.w - hand_area_h
	_hand.position = Vector2(pad.x, hand_top)
	_hand.size = Vector2(area.x - pad.x - pad.z, fan_h)

	var felt_top := top
	var felt_bottom := hand_top - UI.sc(10, 0)
	var box := Vector2(area.x - pad.x - pad.z, maxf(felt_bottom - felt_top, 40))
	_felt_area.position = Vector2(pad.x, felt_top)
	_felt_area.size = box
	var geo := _felt_geometry(box)
	_felt.position = Vector2((box.x - geo.x) / 2.0, geo.z)
	_felt.size = Vector2(geo.x, geo.y)

	var felt_inset := maxf(0.0, (box.x - geo.x) / 2.0)
	var seat_inset := clampf(felt_inset - UI.sc(14, 10), 0.0, felt_inset)
	for slot in _seats:
		var seat: SeatView = _seats[slot]
		seat.reset_size()
		var s := seat.get_combined_minimum_size()
		match slot:
			SeatView.Slot.TOP:
				seat.position = _felt_area.position + Vector2((box.x - s.x) / 2.0, geo.z - s.y / 2.0)
			SeatView.Slot.LEFT:
				seat.position = _felt_area.position + Vector2(seat_inset, (box.y - s.y) / 2.0)
			SeatView.Slot.RIGHT:
				seat.position = _felt_area.position + Vector2(box.x - seat_inset - s.x, (box.y - s.y) / 2.0)
			SeatView.Slot.BOTTOM:
				seat.position = Vector2((area.x - s.x) / 2.0, area.y - pad.w - s.y)
		seat.size = s
	_sync_trick()
	if _deal != null:
		_aim_deal()


## Points the deal at the current layout: it can start before the first
## layout pass, and the screen can rotate mid-deal.
func _aim_deal() -> void:
	_deal.start = _felt_center()
	_deal.seat_targets = _anchors()
	var targets: Array = []
	for g in _hand.slot_centers_global():
		targets.append(_to_body(g))
	_deal.hand_targets = targets


## Felt size and top within the felt box: (width, height, top). Portrait is a
## tall rounded oval; landscape is wide and runs under the hand.
func _felt_geometry(box: Vector2) -> Vector3:
	const ASPECT := 1.66
	if UI.portrait:
		var h := minf(box.y * 0.79, box.x * 0.94 * ASPECT)
		return Vector3(h / ASPECT, h, (box.y - h) / 2.0)
	var top_inset := 0.03
	var bottom_inset := top_inset * (1.0 - 0.33)
	return Vector3(box.x * 0.575, box.y * (1.0 + 0.14 - top_inset - bottom_inset), box.y * top_inset)


func _trick_card_width() -> float:
	var box := _felt_area.size
	return minf(44.0, minf(box.x * 0.16, box.y * 0.3))


## The felt's visual centre in body coordinates — the trick's resting centre.
func _felt_center() -> Vector2:
	return _felt_area.position + _felt.position + _felt.size / 2.0


## Where each seat's avatar is, in body coordinates.
func _anchors() -> Dictionary:
	var out := {}
	for slot in _seats:
		var seat: SeatView = _seats[slot]
		if seat.visible:
			out[slot] = seat.position + seat.avatar.position + seat.avatar.size / 2.0
	return out


func _to_body(global: Vector2) -> Vector2:
	return global - _body.get_global_rect().position


# --------------------------------------------------------------------- HUD

func _build_hud() -> Control:
	var pill_pad := UI.pad_all(UI.sc(8, 9))
	var back := UI.glass_pill(UI.icon("back", UI.sc(16, 19), Tokens.TEXT_ON_DARK), handle_back, UI.sc(16, 15), pill_pad)
	var tune := UI.glass_pill(UI.icon("tune", UI.sc(16, 19), Tokens.TEXT_ON_DARK), _open_quick_settings,
			UI.sc(16, 15), pill_pad)
	_round_label = UI.label("Round 1 / 5", UI.sc(12, 13), Tokens.GOLD, "semibold")
	var round_pill := UI.glass_pill(_round_label, _toggle_history, UI.sc(16, 15),
			UI.pad_hv(UI.sc(14, 16), UI.sc(8, 9)), Color(Tokens.GOLD_BORDER, 0.35))
	var row := UI.hbox(8, [back, tune, UI.spacer(), round_pill])
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return row


func _toggle_history() -> void:
	_show_history = not _show_history
	_rebuild_overlay(true)


func _open_quick_settings() -> void:
	App.instance.sheet(QuickSettings.new())


# -------------------------------------------------------------- session

func _on_session_changed() -> void:
	if not is_inside_tree():
		return
	var v := session.view
	if v != null:
		_prune_throw_origins(v)
		_maybe_autoplay_flights(v)
		_maybe_start_deal(v)
	_refresh()
	_maybe_auto_play()


func _refresh() -> void:
	var v := session.view
	var show_table := session.is_ready() or (session.is_resuming() and v != null)
	_body.visible = show_table
	if show_table and v != null:
		_round_label.text = "Round %d / %d" % [v.hand_number(), v.hands_per_game]
		var deadline := 0 if _dealing else session.turn_deadline_ms
		for seat_index in 4:
			var slot := SeatView.slot_for(seat_index, v.you)
			var seat: SeatView = _seats[slot]
			seat.visible = seat_index < v.players.size()
			if not seat.visible:
				continue
			var count: int = _deal_counts[seat_index] if _dealing and seat_index < _deal_counts.size() \
					else v.hand_counts[seat_index]
			seat.update(v.player(seat_index), v.bids[seat_index], v.tricks_won[seat_index], v.turn == seat_index,
					v.dealer == seat_index, v.host_seat == seat_index,
					deadline if v.turn == seat_index and v.is_my_turn() else 0, count)
		var shown := _hand_revealed if _dealing else v.hand.size()
		_hand.set_hand(v.hand, v.legal_move_ids, not _dealing and v.phase == GameView.PLAYING and v.is_my_turn(), shown)
		_layout()
	_refresh_banners()
	_rebuild_overlay(false)


func _sync_trick() -> void:
	var v := session.view
	if v == null:
		return
	var winner: int = v.last_trick.get("winner", -1) if v.awaiting_trick_clear else -1
	_trick.sync(v.visible_trick(), v.you, winner, _anchors(), _throw_origins, _felt_center(), _trick_card_width())


## Turns discrete happenings into sounds and notices.
func _on_game_event(event: Dictionary) -> void:
	match event.get("event"):
		"play":
			Audio.play_shot()
			if _is_trump_into_side_suit(str(event.get("card", ""))):
				Audio.play_trump()
		"trickWon":
			Audio.play_collect()
		"seatChanged":
			var online: bool = event.get("connected", true)
			var bot: bool = event.get("kind") == "bot"
			var name := str(event.get("name", "A player"))
			var text := "%s is back" % name
			if not online and not bot:
				text = "%s lost connection — a bot is playing their hand" % name
			elif not online:
				text = "%s went offline" % name
			elif bot:
				text = "%s left — a bot has taken the seat" % name
			_announce(text, online and not bot, "wifi" if online and not bot else "wifi_off", int(event.get("seat", -1)))
		"autoplay":
			var on: bool = event.get("autoplay", false)
			var name := str(event.get("name", "A player"))
			_announce("%s is idle — playing automatically" % name if on else "%s is playing again" % name, not on,
					"robot" if on else "touch", int(event.get("seat", -1)))


## A trump landing into a trick a side suit led — the moment the lead suit
## stops mattering — earns the trump flourish.
func _is_trump_into_side_suit(card: String) -> bool:
	if card.is_empty() or not Cards.is_trump(card) or session.view == null:
		return false
	var plays := session.view.visible_trick()
	return not plays.is_empty() and Cards.suit(plays[0]["card"]) != Cards.TRUMP_SUIT


# ---------------------------------------------------------------- dealing

## Spots a freshly dealt hand and runs the dealing flourish once per hand. A
## rejoin that lands on a hand already in progress skips that one deal only.
func _maybe_start_deal(v: GameView) -> void:
	if v.phase != GameView.BIDDING and v.phase != GameView.PLAYING:
		return
	if _last_dealt_hand == v.hand_index:
		return
	_last_dealt_hand = v.hand_index
	if _rejoined:
		_rejoined = false
		if v.phase == GameView.PLAYING or v.bids.any(func(b): return b >= 0):
			return
	_hand_revealed = 0
	_deal_counts = [0, 0, 0, 0]
	_dealing = true
	_trick.sync([], v.you, -1, {}, {}, _felt_center(), _trick_card_width())
	_layout()
	if _deal != null:
		_deal.queue_free()
	_deal = DealOverlay.new()
	_fx.add_child(_deal)
	# Lay the fan out for the new hand (nothing shown yet) so the player's own
	# cards can land on their real slots.
	_hand.set_hand(v.hand, [], false, 0)
	_aim_deal()
	_deal.progress.connect(_on_deal_progress)
	_deal.finished.connect(_on_deal_finished)
	_deal.begin(v.dealer, v.you)


func _on_deal_progress(counts: Array) -> void:
	var v := session.view
	_deal_counts = counts
	_hand_revealed = counts[v.you] if v != null and v.you >= 0 else 0
	_refresh()


func _on_deal_finished() -> void:
	_dealing = false
	_hand_revealed = 13
	if _deal != null:
		_deal.queue_free()
		_deal = null
	_refresh()
	# A convenience auto-throw deferred while the cards were hidden can go now.
	_maybe_auto_play()


# -------------------------------------------------------------- throwing

func _on_card_thrown(card: String, global_pos: Vector2) -> void:
	_throw_origins[card] = _to_body(global_pos)
	session.play(card)


## Plays of the viewer's own seat that arrive with no gesture — the server or a
## bot playing it on autoplay — still fly from where the card sat in the hand.
func _maybe_autoplay_flights(v: GameView) -> void:
	if v.you < 0:
		return
	for p in v.visible_trick():
		if p["seat"] != v.you or _throw_origins.has(p["card"]):
			continue
		var from = _hand.slot_center_global(p["card"])
		if from != null:
			_throw_origins[p["card"]] = _to_body(from)


## Forgets origins for cards no longer on the table, so a card id that turns up
## again in a later hand does not reuse a stale position.
func _prune_throw_origins(v: GameView) -> void:
	var live := v.trick.map(func(p): return p["card"])
	if not v.last_trick.is_empty():
		live.append_array(v.last_trick["plays"].map(func(p): return p["card"]))
	for id in _throw_origins.keys():
		if not live.has(id):
			_throw_origins.erase(id)


## The card the table throws for the player, when the choice is all but
## forced: the very last card, or the only card of the led suit.
func _auto_play_candidate(v: GameView) -> String:
	var hand := v.hand
	if Settings.auto_throw_last_card and hand.size() == 1 and v.legal_move_ids.has(hand[0]):
		return hand[0]
	if Settings.auto_throw_last_suit_card and not v.trick.is_empty():
		var of_led := Cards.of_suit(hand, Cards.suit(v.trick[0]["card"]))
		if of_led.size() == 1 and v.legal_move_ids.has(of_led[0]):
			return of_led[0]
	return ""


func _maybe_auto_play() -> void:
	var v := session.view
	if v == null or v.you < 0 or _dealing:
		return
	if v.phase != GameView.PLAYING or not v.is_my_turn() or v.awaiting_trick_clear:
		return
	# The server is already playing this seat.
	if v.my_player().get("autoplay", false):
		return
	var card := _auto_play_candidate(v)
	if card.is_empty():
		return
	var key := "%d:%d:%s" % [v.hand_index, v.trick_number, card]
	if key == _auto_play_key:
		return
	_auto_play_key = key
	var turn := v.turn
	get_tree().create_timer(0.42 * Settings.animation_scale()).timeout.connect(func():
		if not is_inside_tree():
			return
		var now := session.view
		if now == null or now.turn != turn or not now.hand.has(card) or not now.legal_move_ids.has(card):
			return
		var from = _hand.slot_center_global(card)
		if from != null:
			_throw_origins[card] = _to_body(from)
		session.play(card))


# ---------------------------------------------------------------- banners

func _refresh_banners() -> void:
	var v := session.view
	var game_over := v != null and v.phase == GameView.GAME_OVER
	var autoplay: bool = v != null and v.you >= 0 and v.my_player().get("autoplay", false) and not game_over
	if autoplay and _autoplay_banner == null:
		_autoplay_banner = _banner_box(UI.hbox(9, [UI.icon("robot", 15, Tokens.GOLD_MID), UI.vbox(0, [
			UI.label("Autoplay is on", 12, Tokens.GOLD_MID, "bold"),
			UI.label("Tap anywhere to take your seat back.", 11, Tokens.TEXT_MUTED),
		])]), Color(Tokens.GOLD_MID, 0.75), Color(0.039, 0.071, 0.027, 0.94))
		_banners.add_child(_autoplay_banner)
		_banners.move_child(_autoplay_banner, 0)
	elif not autoplay and _autoplay_banner != null:
		_autoplay_banner.queue_free()
		_autoplay_banner = null
	if game_over and _presence_banner != null:
		_presence_banner.queue_free()
		_presence_banner = null
	_update_offline_pill()


## Somebody else's seat changed. Never announced for the viewer's own seat
## (their reconnect overlay and autoplay banner cover that), nor over the
## winner screen.
func _announce(text: String, online: bool, icon: String, seat: int) -> void:
	var v := session.view
	if v == null or v.you == seat or v.phase == GameView.GAME_OVER:
		return
	if _presence_banner != null:
		_presence_banner.queue_free()
	var colour := Tokens.SUCCESS if online else Tokens.TEXT_MUTED
	var label := UI.label(text, 12, Tokens.TEXT_PRIMARY, "semibold")
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size.x = minf(size.x - 90, 300)
	_presence_banner = _banner_box(UI.hbox(8, [UI.icon(icon, 14, colour), label]), Color(colour, 0.55),
			Color(0.039, 0.071, 0.027, 0.9))
	_banners.add_child(_presence_banner)
	var banner := _presence_banner
	get_tree().create_timer(4.0).timeout.connect(func():
		if is_instance_valid(banner):
			var t := banner.create_tween()
			t.tween_property(banner, "modulate:a", 0.0, 0.24)
			t.tween_callback(banner.queue_free)
			if _presence_banner == banner:
				_presence_banner = null)


func _banner_box(content: Control, border: Color, bg: Color) -> Control:
	var panel := UI.panel(UI.with_shadow(UI.flat(bg, 12, border, 1, UI.pad_hv(14, 9)), Color(0, 0, 0, 0.5), 16,
			Vector2(0, 5)), content)
	panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for c in panel.find_children("*", "Control", true, false):
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.modulate.a = 0.0
	panel.create_tween().tween_property(panel, "modulate:a", 1.0, 0.24)
	return panel


## The debug "Go offline" pill: debug builds, debug mode on, live network table.
func _update_offline_pill() -> void:
	var v := session.view
	var want := OS.is_debug_build() and Settings.debug_mode and session.is_network() and session.is_ready() \
			and not (v != null and v.phase == GameView.GAME_OVER)
	if want and _offline_pill == null:
		_offline_pill = _go_offline_pill()
		add_child(_offline_pill)
	elif not want and _offline_pill != null:
		_offline_pill.queue_free()
		_offline_pill = null
	if _offline_pill != null:
		_offline_pill.reset_size()
		_offline_pill.position = Vector2((size.x - _offline_pill.size.x) / 2.0, UI.safe.y + 8)


func _go_offline_pill() -> Control:
	var offline := session.is_simulated_offline()
	var colour := Tokens.SUCCESS if offline else Tokens.TEXT_ON_DARK
	return UI.glass_pill(UI.hbox(5, [UI.icon("check" if offline else "wifi_off", UI.sc(14, 12), colour),
			UI.label("Back online" if offline else "Go offline", UI.sc(12, 11), colour, "semibold")]),
			func(): session.simulate_offline(not session.is_simulated_offline()), UI.sc(16, 12),
			UI.pad_hv(UI.sc(10, 8), UI.sc(8, 5)), Color(Tokens.SUCCESS, 0.7) if offline else Tokens.HAIRLINE_STRONG,
			Color(Tokens.SUCCESS, 0.18) if offline else Tokens.PANEL_SOFT)


# --------------------------------------------------------------- overlays

## Rebuilds the modal layer when what it should show changes: the bid panel,
## the scoreboard, the winner screen, the round history, or — before the
## table is ready — the lobby, the connecting state or the failure card.
func _rebuild_overlay(force: bool) -> void:
	var v := session.view
	var state := _overlay_key(v)
	if state == _overlay_state and not force:
		return
	_overlay_state = state
	UI.free_children(_overlay)
	_bid_panel = null
	var show_table := session.is_ready() or (session.is_resuming() and v != null)
	if not show_table:
		_overlay.add_child(_connection_state())
		return
	if v == null:
		return
	if v.phase == GameView.BIDDING and v.is_my_turn() and not v.i_have_bid() and not _dealing:
		_bid_panel = BidPanel.new(v.hand, session.turn_deadline_ms)
		_bid_panel.bid_chosen.connect(func(b): session.place_bid(b))
		_bid_panel.custom_minimum_size.x = minf(300, size.x - 40)
		var c := CenterContainer.new()
		c.set_anchors_preset(Control.PRESET_FULL_RECT)
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
		c.add_child(_bid_panel)
		_overlay.add_child(c)
	if v.phase == GameView.HAND_OVER:
		var board := Scoreboard.new(v, session.hand_advance_deadline_ms)
		board.continue_pressed.connect(func(): session.continue_to_next_hand())
		_overlay.add_child(_modal(board, 340))
	if v.phase == GameView.GAME_OVER:
		var winner := WinnerScreen.new(v)
		winner.play_again.connect(_play_again)
		winner.go_home.connect(func(): App.instance.pop_to_root())
		_overlay.add_child(winner)
	if _show_history:
		_overlay.add_child(RoundHistory.overlay(v, _toggle_history))
	if session.is_resuming() and not session.is_ready():
		_overlay.add_child(_reconnect_overlay())


func _overlay_key(v: GameView) -> String:
	var show_table := session.is_ready() or (session.is_resuming() and v != null)
	if not show_table:
		return "conn:%s:%s:%s:%d:%s" % [session.status, session.error_message, JSON.stringify(session.lobby()),
				session.countdown(), session.is_simulated_offline()]
	if v == null:
		return "none"
	var bidding := v.phase == GameView.BIDDING and v.is_my_turn() and not v.i_have_bid() and not _dealing
	return "%s:%d:%s:%s:%d:%d:%s" % [v.phase, v.hand_index, bidding, _show_history, session.turn_deadline_ms if bidding else 0,
			session.hand_advance_deadline_ms, session.is_resuming() and not session.is_ready()]


func _modal(content: Control, max_width: float) -> Control:
	var scrim := ColorRect.new()
	scrim.color = Color(0, 0, 0, 0.6)
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	content.custom_minimum_size.x = minf(max_width - 40, size.x - 40)
	center.add_child(content)
	scrim.add_child(center)
	return scrim


## "Play again": on quickplay that means fresh opponents from matchmaking — a
## same-table rematch would only re-pit the player against whoever stayed.
func _play_again() -> void:
	if session.mode == "online" and session is RemoteSession:
		var previous := session as RemoteSession
		var hands := previous.view.hands_per_game if previous.view != null else 0
		var rematch := Sessions.remote(previous.server_url, RemoteSession.QUICKPLAY_ROOM, "online", hands)
		previous.shutdown()
		App.instance.replace(TableScreen.new(rematch))
		return
	session.restart()


func _connection_state() -> Control:
	if session.status == GameSession.ERROR:
		return _connect_failure()
	var lobby := session.lobby()
	if not lobby.is_empty():
		var panel := LobbyPanel.new(lobby, session.countdown())
		panel.start_pressed.connect(func(): session.start_game())
		panel.leave_pressed.connect(func():
			session.leave_lobby()
			_leave())
		panel.hands_changed.connect(func(h): session.set_hands_per_game(h))
		# Centred when it fits, scrollable when it does not.
		var centre := UI.center(panel)
		var scroller := UI.scroll(centre)
		scroller.resized.connect(func(): centre.custom_minimum_size.y = scroller.size.y)
		scroller.set_anchors_preset(Control.PRESET_FULL_RECT)
		scroller.offset_top = UI.safe.y
		scroller.offset_bottom = -UI.safe.w
		var wrap := Control.new()
		wrap.set_anchors_preset(Control.PRESET_FULL_RECT)
		wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
		wrap.add_child(scroller)
		return wrap
	return _full_center(_reconnect_notice(session.is_resuming()))


func _full_center(child: Control) -> Control:
	var c := CenterContainer.new()
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.add_child(child)
	return c


func _reconnect_notice(resuming: bool) -> Control:
	var col := UI.vbox(0, [UI.center(PulseRipple.new(68, "sync" if resuming else "signal", 2 if resuming else 3)),
			UI.gap(14),
			UI.label("Reconnecting…" if resuming else "Connecting…", 13, Tokens.TEXT_MUTED, "medium",
					HORIZONTAL_ALIGNMENT_CENTER)])
	if resuming:
		col.add_child(UI.gap(6))
		col.add_child(UI.label("Your seat is being held. Stay close.", 11, Tokens.TEXT_MUTED, "medium",
				HORIZONTAL_ALIGNMENT_CENTER))
	if OS.is_debug_build() and Settings.debug_mode and session.is_simulated_offline():
		col.add_child(UI.gap(20))
		var pill := _go_offline_pill()
		pill.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		col.add_child(pill)
	return col


## A mid-game reconnect keeps the last deal on screen behind a small card,
## rather than swapping the table for a blank page.
func _reconnect_overlay() -> Control:
	var card := UI.panel(UI.with_shadow(UI.flat(Tokens.PANEL, 18, Tokens.HAIRLINE, 1, UI.pad_all(20)), Color(0, 0, 0, 0.6),
			30, Vector2(0, 12)), _reconnect_notice(true))
	card.custom_minimum_size.x = 260
	var c := _full_center(card)
	c.mouse_filter = Control.MOUSE_FILTER_STOP
	return c


func _connect_failure() -> Control:
	var message := session.error_message if not session.error_message.is_empty() \
			else "Something went wrong while connecting. Check your internet and try again."
	var pulse := Control.new()
	pulse.custom_minimum_size = Vector2(72, 72)
	pulse.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	pulse.draw.connect(func():
		var t := (sin(Time.get_ticks_msec() / 1500.0 * PI) + 1.0) / 2.0
		var c := Vector2(36, 36)
		pulse.draw_circle(c, 27 + 5 * t, Color(Tokens.DANGER, 0.08 + 0.05 * t), true, -1.0, true)
		pulse.draw_arc(c, 27 + 5 * t, 0, TAU, 48, Color(Tokens.DANGER, 0.3 + 0.15 * t), 1.5, true)
		pulse.draw_circle(c, 26, Color(Tokens.DANGER, 0.14), true, -1.0, true)
		Draw.icon(pulse, "wifi_off", Rect2(c - Vector2(13, 13), Vector2(26, 26)), Tokens.DANGER))
	var timer := Timer.new()
	timer.wait_time = 1.0 / 30.0
	timer.autostart = true
	timer.timeout.connect(pulse.queue_redraw)
	pulse.add_child(timer)
	var buttons := UI.hbox(10)
	# Only a brand-new connect can simply try again; a seat that was given up
	# cannot be retried into existence.
	if session.is_network() and session.view == null:
		buttons.add_child(UI.expand(UI.button("Try again", true, func(): session.retry_connect(), 13, UI.pad_hv(0, 13))))
	buttons.add_child(UI.expand(UI.button("Back", false, _leave, 13, UI.pad_hv(0, 13))))
	var col := UI.vbox(0, [pulse, UI.gap(14),
		UI.label("Can't connect", 18, Tokens.TEXT_PRIMARY, "bold", HORIZONTAL_ALIGNMENT_CENTER), UI.gap(6),
		UI.paragraph(message, 13, Tokens.TEXT_MUTED, "medium", HORIZONTAL_ALIGNMENT_CENTER), UI.gap(22), buttons])
	col.custom_minimum_size.x = minf(300, size.x - 48)
	return _full_center(UI.margin(col, UI.pad_all(24)))
