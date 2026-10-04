class_name ProfileScreen
extends Control

## The player's profile: statistics per mode, the history of finished games
## (each opening its hand-by-hand scorecard), and the account — its id to save,
## restoring a saved account onto this device, and (later) linked sign-ins.
##
## Everything comes from the REST API through the shared [ApiClient], which
## mints and refreshes the session on its own. A server with no database is a
## supported deployment, so that case reads as "history is off here", never as
## a crash.

const SCOPES := [["All", "all"], ["vs Humans", "online"], ["Private", "private"], ["vs Bots", "bots"], ["LAN", "lan"]]
const MONTHS := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
const UUID_PATTERN := "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"

var _tab := "statistics"
var _scope := "all"
var _stats := {}
var _stats_error: ApiClient.ApiError
var _stats_loading := false
var _games: Array = []
var _cursor := ""
var _games_error: ApiClient.ApiError
var _games_loading := false
var _games_loaded := false
var _busy := false
var _content: Control
var _pane: VBoxContainer


func _client() -> ApiClient:
	return Uploader.client


func _ready() -> void:
	add_child(Backdrop.new("background"))
	App.instance.layout_changed.connect(_build)
	_build()
	_load_stats()
	_refresh_me()


func handle_back() -> void:
	App.instance.pop()


func _refresh_me() -> void:
	var res: Dictionary = await _client().fetch_me()
	if res["ok"] and is_inside_tree():
		_build()


func _build() -> void:
	if not is_inside_tree():
		return
	if _content != null:
		_content.queue_free()
	var back := UI.glass_pill(UI.icon("back", 20, Tokens.TEXT_ON_DARK), handle_back, 18, UI.pad_all(9))
	var tabs := UI.hbox(8)
	for t in [["Statistics", "statistics"], ["History", "history"], ["Upgrade Account", "account"]]:
		var selected: bool = t[1] == _tab
		tabs.add_child(UI.expand(UI.pressable(UI.panel(UI.flat(Color(Tokens.GOLD, 0.16) if selected else Tokens.PANEL, 12,
				Tokens.GOLD_BORDER if selected else Tokens.HAIRLINE, 1, UI.pad_hv(6, 9)),
				UI.label(t[0], UI.sc(12, 11), Tokens.GOLD if selected else Tokens.TEXT_ON_DARK, "semibold",
				HORIZONTAL_ALIGNMENT_CENTER)), _select_tab.bind(t[1]), 0.94)))
	_pane = UI.vbox(14)
	match _tab:
		"statistics": _statistics()
		"history": _history()
		"account": _account()
	var col := UI.vbox(0, [UI.hbox(12, [back, UI.expand(_header())]), UI.gap(16), tabs, UI.gap(16),
			UI.expand_v(UI.scroll(_pane))])
	_content = UI.margin(col, Vector4(20 + UI.safe.x, 10 + UI.safe.y, 20 + UI.safe.z, 10 + UI.safe.w))
	_content.set_anchors_preset(Control.PRESET_FULL_RECT)
	if not UI.portrait and size.x > 620:
		_content.offset_left = (size.x - 620) / 2.0
		_content.offset_right = -(size.x - 620) / 2.0
	add_child(_content)


func _select_tab(tab: String) -> void:
	_tab = tab
	if tab == "history" and not _games_loaded and not _games_loading:
		_load_games(true)
	_build()


func _header() -> Control:
	var user := Settings.identity.cached_user()
	var name: String = user.get("displayName", "") if not str(user.get("displayName", "")).is_empty() else Settings.player_name
	var linked := false
	for i in user.get("identities", []):
		if i is Dictionary and i.get("provider", "device") != "device":
			linked = true
	var avatar := Control.new()
	avatar.custom_minimum_size = Vector2(44, 44)
	avatar.draw.connect(func():
		Draw.rounded_rect(avatar, Rect2(Vector2.ZERO, avatar.size), 22, [Tokens.GOLD, Tokens.GOLD_DEEP], true,
				Color(Tokens.GOLD_LIGHT, 0.9), 2.0)
		var font := Tokens.font("bold")
		var initial := GameView.initial(name)
		var tw := font.get_string_size(initial, HORIZONTAL_ALIGNMENT_LEFT, -1, 17).x
		avatar.draw_string(font, Vector2(22 - tw / 2.0, 28), initial, HORIZONTAL_ALIGNMENT_LEFT, -1, 17, Tokens.ON_GOLD))
	var title := UI.label(name, 17, Tokens.TEXT_PRIMARY, "bold")
	title.clip_text = true
	return UI.hbox(12, [avatar, UI.expand(UI.vbox(2, [title,
			UI.label("Signed in" if linked else "Guest account", 12, Tokens.TEXT_MUTED)]))])


# -------------------------------------------------------------- statistics

func _load_stats() -> void:
	_stats_loading = true
	_stats_error = null
	_build()
	var res: Dictionary = await _client().fetch_stats()
	_stats_loading = false
	if res["ok"]:
		_stats = {}
		for s in res["data"].get("scopes", []):
			if s is Dictionary:
				_stats[str(s.get("scope", "all"))] = s
	else:
		_stats_error = res["error"]
	if is_inside_tree():
		_build()


func _statistics() -> void:
	if _stats_loading:
		_pane.add_child(_spinner())
		return
	if _stats_error != null:
		_pane.add_child(_message_for(_stats_error, _load_stats))
		return
	var chips := HFlowContainer.new()
	chips.add_theme_constant_override("h_separation", 6)
	chips.add_theme_constant_override("v_separation", 6)
	for s in SCOPES:
		var selected: bool = s[1] == _scope
		chips.add_child(UI.pressable(UI.panel(UI.flat(Color(Tokens.GOLD, 0.16) if selected else Tokens.PANEL, 10,
				Tokens.GOLD_BORDER if selected else Tokens.HAIRLINE_STRONG, 1, UI.pad_hv(12, 7)),
				UI.label(s[0], 12, Tokens.GOLD if selected else Tokens.TEXT_ON_DARK, "semibold")),
				_select_scope.bind(s[1]), 0.94))
	_pane.add_child(chips)
	var st: Dictionary = _stats.get(_scope, {})
	var label := _scope_label(_scope)
	var played := int(st.get("gamesPlayed", 0))
	if played <= 0:
		if _scope == "all":
			_pane.add_child(_message("No games yet",
					"Play a hand and this fills up — every mode is counted, including games against bots."))
		else:
			_pane.add_child(_message("Nothing in %s yet" % label,
					"Play a %s game and its own records start here, separately from every other mode." % label))
		return
	var won := int(st.get("gamesWon", 0))
	var lost := int(st.get("gamesLost", 0))
	var completed := int(st.get("gamesCompleted", 0))
	var decided := completed if completed > 0 else won + lost
	var win_rate := float(won) / decided if decided > 0 else 0.0
	var average := float(st.get("totalScore", 0.0)) / decided if decided > 0 else 0.0
	var made := int(st.get("bidsMade", 0))
	var failed := int(st.get("bidsFailed", 0))
	var hands := int(st.get("handsPlayed", 0))
	var bidded := made + failed if made + failed > 0 else hands
	var accuracy := float(made) / bidded if bidded > 0 else 0.0
	_pane.add_child(UI.hbox(10, [
		UI.expand(_hero_stat("%d%%" % roundi(win_rate * 100), "Win rate", "%dW · %dL" % [won, lost])),
		UI.expand(_hero_stat(str(played), "Games played", "%d finished" % completed)),
	]))
	_pane.add_child(_section("Results", [[_place(int(st.get("bestPlace", 0))), "Best finish"],
			[str(int(st.get("currentWinStreak", 0))), "Streak"], [str(int(st.get("bestWinStreak", 0))), "Best streak"]]))
	_pane.add_child(_section("Scores", [["%.1f" % average, "Average"], ["%.1f" % float(st.get("highestGameScore", 0.0)), "Best game"],
			["%.1f" % float(st.get("highestHandScore", 0.0)), "Best hand"]]))
	_pane.add_child(_section("Bidding", [["%d%%" % roundi(accuracy * 100), "Bids made"],
			[str(int(st.get("highestBid", 0))), "Highest bid"], [str(hands), "Hands"]]))
	var last = st.get("lastPlayedAt")
	if last is String and not last.is_empty():
		_pane.add_child(UI.label("Last played " + format_played_at(last).to_lower(), 11, Tokens.TEXT_FAINT, "medium",
				HORIZONTAL_ALIGNMENT_CENTER))


func _select_scope(scope: String) -> void:
	_scope = scope
	_build()


static func _scope_label(scope: String) -> String:
	for s in SCOPES:
		if s[1] == scope:
			return s[0]
	return scope


static func _place(place: int) -> String:
	return {1: "1st", 2: "2nd", 3: "3rd", 4: "4th"}.get(place, "—")


func _hero_stat(value: String, label: String, support: String) -> Control:
	return UI.panel(UI.flat(Tokens.PANEL, 14, Color(Tokens.GOLD_BORDER, 0.3), 1, UI.pad_hv(14, 14)), UI.vbox(2, [
		UI.label(value, UI.sc(30, 24), Tokens.GOLD, "bold"),
		UI.label(label, UI.sc(12, 11), Tokens.TEXT_PRIMARY, "semibold"),
		UI.label(support, 11, Tokens.TEXT_MUTED),
	]))


func _section(title: String, tiles: Array) -> Control:
	var row := UI.hbox(8)
	for t in tiles:
		row.add_child(UI.expand(UI.panel(UI.flat(Tokens.PANEL, 12, Tokens.HAIRLINE, 1, UI.pad_hv(10, 10)), UI.vbox(2, [
			UI.label(t[0], 17, Tokens.TEXT_PRIMARY, "bold", HORIZONTAL_ALIGNMENT_CENTER),
			UI.label(t[1], 11, Tokens.TEXT_MUTED, "medium", HORIZONTAL_ALIGNMENT_CENTER),
		]))))
	return UI.vbox(8, [UI.label(title, 13, Tokens.TEXT_MUTED, "semibold"), row])


# ----------------------------------------------------------------- history

func _load_games(reset: bool) -> void:
	if _games_loading:
		return
	_games_loading = true
	_games_error = null
	if reset:
		_games = []
		_cursor = ""
	_build()
	var res: Dictionary = await _client().fetch_games("", 20, _cursor)
	_games_loading = false
	_games_loaded = true
	if res["ok"]:
		for g in res["data"].get("games", []):
			if g is Dictionary:
				_games.append(g)
		var next = res["data"].get("nextCursor")
		_cursor = next if next is String else ""
	else:
		_games_error = res["error"]
	if is_inside_tree():
		_build()


func _history() -> void:
	if _games_error != null and _games.is_empty():
		_pane.add_child(_message_for(_games_error, _load_games.bind(true)))
		return
	if _games.is_empty():
		if _games_loading or not _games_loaded:
			_pane.add_child(_spinner())
		else:
			_pane.add_child(_message("No games yet",
					"Finished games land here — quickplay, private rooms, LAN and games against bots alike."))
		return
	for g in _games:
		_pane.add_child(_game_row(g))
	if not _cursor.is_empty():
		if _games_loading:
			_pane.add_child(_spinner())
		else:
			_pane.add_child(UI.button("Load more", false, _load_games.bind(false), 13, UI.pad_hv(0, 11)))


static func mode_label(game: Dictionary) -> String:
	var mode := str(game.get("mode", ""))
	if mode == "online":
		match int(game.get("handsTotal", 0)):
			3: return "Quickplay"
			5: return "Normal Play"
	if mode in ["bots", "private", "online", "lan"]:
		return GameSession.mode_label(mode)
	return mode


func _game_row(game: Dictionary) -> Control:
	var you: Dictionary = game.get("you") if game.get("you") is Dictionary else {}
	var place := int(you.get("place", 0))
	var badge_color := Tokens.GOLD if place == 1 else Tokens.TEXT_MUTED
	var badge := UI.panel(UI.flat(Color(badge_color, 0.15), 10, Color(badge_color, 0.5), 1, UI.pad_hv(0, 0)),
			UI.label(_place(place), 12, badge_color, "bold", HORIZONTAL_ALIGNMENT_CENTER))
	(badge.get_child(0) as Label).vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	badge.custom_minimum_size = Vector2(42, 42)
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var opponents := []
	for p in game.get("players", []):
		if p is Dictionary and int(p.get("seat", -1)) != int(you.get("seat", -2)):
			opponents.append(str(p.get("displayName", "")))
	var stamp = game.get("finishedAt") if game.get("finishedAt") is String else game.get("startedAt")
	var mode_chip := UI.panel(UI.flat(Color(Tokens.GOLD, 0.12), 6, Color.TRANSPARENT, 0, UI.pad_hv(7, 2)),
			UI.label(mode_label(game), 10, Tokens.GOLD, "semibold"))
	var top := UI.hbox(8, [mode_chip, UI.label(format_played_at(stamp if stamp is String else ""), 11, Tokens.TEXT_MUTED)])
	var opp := UI.label(", ".join(opponents) if not opponents.is_empty() else "Solo table", 12, Tokens.TEXT_ON_DARK)
	opp.clip_text = true
	opp.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var score := UI.label("%.1f" % float(you.get("finalScore", 0.0)), 16, Tokens.GOLD, "bold")
	score.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var row := UI.hbox(12, [badge, UI.expand(UI.vbox(4, [top, opp])), score])
	return UI.pressable(UI.panel(UI.flat(Tokens.PANEL, 14, Tokens.HAIRLINE, 1, UI.pad_hv(12, 10)), row),
			_open_game.bind(game), 0.97)


## A finished game's hand-by-hand scorecard.
func _open_game(game: Dictionary) -> void:
	var body := UI.vbox(10)
	var sheet := App.instance.sheet(UI.margin(body, Vector4(22, 22, 22, 22 + UI.safe.w)))
	body.add_child(UI.label(mode_label(game), 18, Tokens.TEXT_PRIMARY, "bold"))
	var stamp = game.get("finishedAt") if game.get("finishedAt") is String else game.get("startedAt")
	body.add_child(UI.label(format_played_at(stamp if stamp is String else ""), 12, Tokens.TEXT_MUTED))
	var loading := _spinner()
	body.add_child(loading)
	var res: Dictionary = await _client().fetch_game(str(game.get("id", "")))
	if not is_instance_valid(body):
		return
	loading.queue_free()
	if not res["ok"]:
		body.add_child(UI.paragraph((res["error"] as ApiClient.ApiError).display_message(), 13, Tokens.TEXT_MUTED))
		return
	var detail: Dictionary = res["data"]
	var hands: Array = detail.get("hands", [])
	var summary: Dictionary = detail.get("game") if detail.get("game") is Dictionary else game
	if hands.is_empty():
		body.add_child(UI.label("No scorecard", 14, Tokens.TEXT_PRIMARY, "bold"))
		body.add_child(UI.paragraph("This game was recorded without its hand-by-hand detail.", 12, Tokens.TEXT_MUTED))
		return
	body.add_child(_scorecard(summary, hands))
	sheet.content.update_minimum_size()


func _scorecard(game: Dictionary, hands: Array) -> Control:
	var players: Array = game.get("players", [])
	players.sort_custom(func(a, b): return int(a.get("seat", 0)) < int(b.get("seat", 0)))
	var you_seat := int((game.get("you") if game.get("you") is Dictionary else {}).get("seat", -1))
	var col := UI.vbox(6)
	var head := ["Hand"]
	for p in players:
		head.append(str(p.get("displayName", "Seat %d" % int(p.get("seat", 0)))))
	col.add_child(RoundHistory._row(head, func(i):
		return [11, Tokens.GOLD if i > 0 and int(players[i - 1].get("seat", -1)) == you_seat else Tokens.TEXT_FAINT, "semibold"]))
	col.add_child(RoundHistory._rule())
	var indices := {}
	for h in hands:
		indices[int(h.get("handIndex", 0))] = true
	var order := indices.keys()
	order.sort()
	for hi in order:
		var cells := [str(hi + 1)]
		var deltas := []
		for p in players:
			var cell := {}
			for h in hands:
				if int(h.get("handIndex", -1)) == hi and int(h.get("seat", -1)) == int(p.get("seat", -2)):
					cell = h
			deltas.append(float(cell.get("scoreDelta", 0.0)))
			cells.append("—" if cell.is_empty() else "%.1f\n%d bid · %d won" % [float(cell.get("scoreDelta", 0.0)),
					int(cell.get("bid", 0)), int(cell.get("tricksWon", 0))])
		col.add_child(RoundHistory._row(cells, func(i):
			if i == 0:
				return [12, Tokens.TEXT_MUTED, "medium"]
			var d: float = deltas[i - 1]
			return [11, Tokens.DANGER if d < 0 else Tokens.GOLD, "semibold"]))
	col.add_child(RoundHistory._rule())
	var totals := ["Total"]
	for p in players:
		totals.append("%.1f" % float(p.get("finalScore", 0.0)))
	col.add_child(RoundHistory._row(totals, func(i): return [12, Tokens.TEXT_PRIMARY, "bold"] if i == 0 else [13, Tokens.GOLD, "bold"]))
	for l in col.find_children("*", "Label", true, false):
		(l as Label).clip_text = false
	return col


## "Today 14:05", "Yesterday 09:12", "3 days ago", "12 Mar", "12 Mar 2025".
static func format_played_at(stamp: String) -> String:
	if stamp.is_empty():
		return "Unknown date"
	var unix := Wire.parse_iso(stamp)
	if unix <= 0:
		return "Unknown date"
	var bias := int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	var local := Time.get_datetime_dict_from_unix_time(unix + bias)
	var now := Time.get_datetime_dict_from_unix_time(int(Time.get_unix_time_from_system()) + bias)
	var day := Time.get_unix_time_from_datetime_dict({"year": local["year"], "month": local["month"], "day": local["day"]})
	var today := Time.get_unix_time_from_datetime_dict({"year": now["year"], "month": now["month"], "day": now["day"]})
	var difference := int(round((today - day) / 86400.0))
	var time := "%02d:%02d" % [local["hour"], local["minute"]]
	if difference == 0:
		return "Today " + time
	if difference == 1:
		return "Yesterday " + time
	if difference > 1 and difference < 7:
		return "%d days ago" % difference
	if local["year"] == now["year"]:
		return "%d %s" % [local["day"], MONTHS[local["month"] - 1]]
	return "%d %s %d" % [local["day"], MONTHS[local["month"] - 1], local["year"]]


# ----------------------------------------------------------------- account

func _account() -> void:
	var user := Settings.identity.cached_user()
	var account_id := str(user.get("id", ""))
	var copy := UI.button("Copy account id", false, func():
		DisplayServer.clipboard_set(account_id)
		App.instance.toast("Account id copied to the clipboard."), 13, UI.pad_hv(0, 11))
	copy.enabled = not account_id.is_empty()
	_pane.add_child(_card("Account id", [
		UI.label(account_id if not account_id.is_empty() else "Not available yet", 13,
				Tokens.TEXT_PRIMARY if not account_id.is_empty() else Tokens.TEXT_MUTED, "semibold"),
		UI.paragraph("Today this account lives on this device only. Reinstalling the app or switching phones would start a new one.",
				12, Tokens.TEXT_MUTED),
		copy,
	]))

	var pending := Settings.identity.pending_abandoned()
	if not pending.is_empty():
		var games := int(pending.get("games", 0))
		_pane.add_child(_card("Games from your old install", [
			UI.paragraph("Your previous account still has %d game%s on it. Bring them into this restored account, or leave them behind for good?" %
					[games, "" if games == 1 else "s"], 12, Tokens.TEXT_MUTED),
			UI.hbox(10, [UI.expand(UI.button("Leave them behind", false, _decide_abandoned.bind(pending, false), 12, UI.pad_hv(0, 11))),
					UI.expand(UI.button("Bring them along", true, _decide_abandoned.bind(pending, true), 12, UI.pad_hv(0, 11)))]),
		]))

	var restore := UI.button("Restore", true, _restore, 13, UI.pad_hv(0, 11))
	restore.enabled = not _busy
	_pane.add_child(_card("Restore a saved account", [
		UI.paragraph("New phone, or reinstalled the app? Enter the account id you saved from your old device and every game comes back with it.",
				12, Tokens.TEXT_MUTED),
		restore,
	]))

	_pane.add_child(UI.label("Link a sign-in", 13, Tokens.TEXT_MUTED, "semibold"))
	for provider in ["Google", "Facebook", "Apple"]:
		var label := "Continue with %s" % provider
		var b := UI.pressable(UI.panel(UI.flat(Tokens.PANEL, 12, Tokens.HAIRLINE_STRONG, 1, UI.pad_hv(14, 12)),
				UI.hbox(8, [UI.expand(UI.label(label, 13, Tokens.TEXT_ON_DARK, "semibold")),
					UI.label("Coming soon", 11, Tokens.TEXT_FAINT)])),
				func(): App.instance.toast("%s sign-in is coming soon." % provider))
		_pane.add_child(b)
	_pane.add_child(_card("Nothing is lost", [UI.paragraph("Linking adds a way to sign in to the account you already have. Every game, every statistic and every record stays exactly where it is — this account keeps its id.", 12, Tokens.TEXT_MUTED)]))
	_pane.add_child(_card("The same account on any device", [UI.paragraph("Sign in with the same Google account on an iPhone and you land on this account, with all of its history. It is the sign-in method that carries it, not the phone — so link more than one and any of them will get you back in.", 12, Tokens.TEXT_MUTED)]))


func _card(title: String, children: Array) -> Control:
	var col := UI.vbox(10, [UI.label(title, 14, Tokens.TEXT_PRIMARY, "bold")])
	for c in children:
		col.add_child(c)
	return UI.panel(UI.flat(Tokens.PANEL, 14, Color(Tokens.GOLD_BORDER, 0.25), 1, UI.pad_all(16)), col)


func _restore() -> void:
	var input := UI.line_edit("", "Enter account id", 14)
	var error := UI.label("", 11, Tokens.DANGER)
	error.visible = false
	var body := UI.vbox(12)
	var sheet := App.instance.sheet(UI.margin(body, Vector4(22, 22, 22, 22 + UI.safe.w)))
	var submit := func():
		var id := input.text.strip_edges()
		if RegEx.create_from_string(UUID_PATTERN).search(id) == null:
			error.text = "That does not look like an account id."
			error.visible = true
			return
		sheet.close(id)
	input.text_submitted.connect(func(_t): submit.call())
	body.add_child(UI.label("Restore your account", 18, Tokens.TEXT_PRIMARY, "bold"))
	body.add_child(UI.paragraph("Paste the id from the Account tab of your old device — the long string under \"Account id\". This device becomes that account.",
			12, Tokens.TEXT_MUTED))
	body.add_child(input)
	body.add_child(error)
	body.add_child(UI.hbox(10, [UI.expand(UI.button("Cancel", false, func(): sheet.close(null), 13, UI.pad_hv(0, 12))),
			UI.expand(UI.button("Restore", true, submit, 13, UI.pad_hv(0, 12)))]))
	var account_id = await sheet.closed
	if account_id == null:
		return
	_busy = true
	_build()
	var res: Dictionary = await _client().restore_account(account_id)
	_busy = false
	if not res["ok"]:
		App.instance.toast((res["error"] as ApiClient.ApiError).display_message())
		_build()
		return
	var data: Dictionary = res["data"]
	var user: Dictionary = data.get("user") if data.get("user") is Dictionary else {}
	var name := str(user.get("displayName", ""))
	App.instance.toast("Welcome back, %s. Your history is restored on this device." % (name if not name.is_empty() else "player"))
	var abandoned = data.get("abandoned")
	if abandoned is Dictionary:
		var pending := {"accountId": str(abandoned.get("accountId", "")), "games": int(abandoned.get("games", 0))}
		Settings.identity.save_pending_abandoned(pending)
	_stats_loading = false
	_games_loaded = false
	_load_stats()


func _decide_abandoned(pending: Dictionary, merge: bool) -> void:
	_busy = true
	var res: Dictionary
	if merge:
		res = await _client().merge_abandoned(pending["accountId"])
	else:
		res = await _client().discard_abandoned(pending["accountId"])
	_busy = false
	# A 404 means the offer is already consumed; either way it is settled.
	if res["ok"] or (res["error"] as ApiClient.ApiError).status_code == 404:
		Settings.identity.save_pending_abandoned({})
		var games := int(pending.get("games", 0))
		App.instance.toast("Your %d game%s joined your history." % [games, "" if games == 1 else "s"] if merge
				else "Those games were left behind. The restored account keeps its own history.")
		_games_loaded = false
		_load_stats()
	else:
		App.instance.toast((res["error"] as ApiClient.ApiError).display_message())
		_build()


# ------------------------------------------------------------------ states

func _spinner() -> Control:
	return UI.margin(UI.center(PulseRipple.new(54, "sync", 2)), Vector4(0, 30, 0, 30))


func _message(title: String, text: String, retry := Callable()) -> Control:
	var col := UI.vbox(8, [UI.label(title, 15, Tokens.TEXT_PRIMARY, "bold", HORIZONTAL_ALIGNMENT_CENTER),
			UI.paragraph(text, 12, Tokens.TEXT_MUTED, "medium", HORIZONTAL_ALIGNMENT_CENTER)])
	if retry.is_valid():
		var b := UI.button("Try again", true, retry, 13, UI.pad_hv(24, 11))
		b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		col.add_child(UI.gap(6))
		col.add_child(b)
	return UI.margin(col, Vector4(8, 24, 8, 24))


func _message_for(error: ApiClient.ApiError, retry: Callable) -> Control:
	if error.is_persistence_disabled():
		return _message("History is off on this server",
				"This server is running without a database, so games and statistics are not being recorded.")
	return _message("Could not load", error.display_message(), retry)
