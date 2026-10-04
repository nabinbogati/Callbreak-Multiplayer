extends TestBase

## Port of frontend/test/engine_test.dart: rules invariants, scoring, bid
## suggestion, legal moves and view redaction.

const DIFFICULTIES := ["easy", "normal", "hard"]


func _bot_table() -> Array:
	var players := []
	for seat in 4:
		players.append(GameView.make_player(seat, "Bot %d" % seat, "bot"))
	return players


## Drives [param game] end to end with four bots, synchronously, and returns the
## trick-by-trick log.
func _play_full_game(game: CallBreakGame, brains: Array) -> Array:
	game.start()
	var tricks := []
	var guard := 0
	while game.phase != GameView.GAME_OVER and guard < 10000:
		guard += 1
		match game.phase:
			GameView.BIDDING:
				var seat := game.turn
				var bid: int = brains[seat].choose_bid(game.hand_of(seat))
				expect_true(game.place_bid(seat, bid), "bot bid should always be accepted")
			GameView.PLAYING:
				var seat := game.turn
				var legal := game.legal_moves_for(seat)
				expect_true(not legal.is_empty(), "a seat on the clock must have a legal move")
				var card: String = brains[seat].choose_card(game.hand_of(seat), game.trick,
						game.played_this_hand, game.bids[seat], game.tricks_won[seat])
				expect_true(legal.has(card), "bot must only offer a legal card")
				expect_true(game.play_card(seat, card), "legal card accepted")
				if game.awaiting_trick_clear:
					tricks.append(game.last_trick.duplicate(true))
					game.clear_trick()
			GameView.HAND_OVER:
				game.next_hand()
	return tricks


func test_rules_invariants_over_many_simulated_games() -> void:
	for seed_value in 40:
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_value
		var brains := []
		for i in 4:
			brains.append(BotBrain.new(DIFFICULTIES[seed_value % 3], rng))
		var game := CallBreakGame.new(_bot_table(), seed_value)
		var tricks := _play_full_game(game, brains)

		expect_eq(tricks.size(), Rules.HANDS_PER_GAME * Rules.TRICKS_PER_HAND, "seed %d trick count" % seed_value)
		for t in tricks:
			expect_eq(t["plays"].size(), 4, "every trick has exactly 4 plays")
			var seats := {}
			for p in t["plays"]:
				seats[p["seat"]] = true
			expect_eq(seats.size(), 4, "each seat plays once per trick")
			expect_eq(t["winner"], Rules.trick_winner(t["plays"]), "winner recomputes")

		for h in Rules.HANDS_PER_GAME:
			var hand_tricks := tricks.slice(h * 13, (h + 1) * 13)
			var cards := {}
			var won := [0, 0, 0, 0]
			for t in hand_tricks:
				won[t["winner"]] += 1
				for p in t["plays"]:
					cards[p["card"]] = true
			expect_eq(cards.size(), 52, "no card repeats within a hand")
			expect_eq(won[0] + won[1] + won[2] + won[3], 13, "tricks sum to 13")

		expect_eq(game.phase, GameView.GAME_OVER)
		for seat in 4:
			expect_eq(game.round_scores[seat].size(), Rules.HANDS_PER_GAME)
			var sum := 0.0
			for d in game.round_scores[seat]:
				sum += d
			expect_near(game.totals[seat], sum, 0.15, "total matches rounds")
		var ranked := {}
		for r in game.rankings:
			ranked[r["seat"]] = true
		expect_eq(ranked.size(), 4, "every seat ranked")


func test_scoring() -> void:
	expect_eq(Rules.score_hand(5, 5), 5.0, "exact bid")
	expect_near(Rules.score_hand(3, 6), 3.3, 1e-9, "overtricks")
	expect_eq(Rules.score_hand(7, 3), -7.0, "short")
	expect_eq(Rules.score_hand(7, 0), -7.0, "zero")
	expect_eq(Rules.clamp_bid(0), 1)
	expect_eq(Rules.clamp_bid(14), 13)
	expect_eq(Rules.clamp_bid(7), 7)


func test_bid_suggestion() -> void:
	var weak := []
	for r in range(2, 7): weak.append(Cards.make(r, Cards.Suit.HEARTS))
	for r in range(2, 8): weak.append(Cards.make(r, Cards.Suit.CLUBS))
	weak.append_array(["2D", "3D"])
	expect_eq(weak.size(), 13)
	expect_eq(Rules.estimate_tricks(weak), 0.0, "weak hand estimate")
	expect_eq(Rules.suggest_bid(weak), Rules.MIN_BID)

	var monster := ["AS", "KS", "QS", "JS", "10S", "9S", "AH", "KH", "QH", "AC", "KC", "QC", "AD"]
	expect_true(Rules.suggest_bid(monster) >= 8, "monster hand bids high")
	expect_true(Rules.suggest_bid(monster) <= Rules.MAX_BID)

	var lone_king := ["KH"]
	for r in range(2, 9): lone_king.append(Cards.make(r, Cards.Suit.CLUBS))
	for r in range(2, 7): lone_king.append(Cards.make(r, Cards.Suit.DIAMONDS))
	expect_eq(lone_king.size(), 13)
	expect_true(Rules.estimate_tricks(lone_king) < 1.0, "lone king discounted")

	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var brain := BotBrain.new("hard")
	for i in 10:
		var hand: Array = Cards.deal_hands(rng)[0]
		expect_eq(brain.choose_bid(hand), Rules.suggest_bid(hand), "hard bots bid the suggestion")


func test_legal_moves() -> void:
	expect_eq(Rules.legal_moves(["AH", "2C", "10S"], []), ["AH", "2C", "10S"] as Array[String], "leading free")
	expect_eq(Rules.legal_moves(["5H", "JH", "2C"], [Cards.play(3, "9H")]), ["JH"] as Array[String], "must head")
	expect_same_set(Rules.legal_moves(["3H", "5H", "2C"], [Cards.play(3, "9H")]), ["3H", "5H"], "follow low")
	expect_same_set(Rules.legal_moves(["3S", "9S", "2C"], [Cards.play(3, "9H")]), ["3S", "9S"], "must trump")
	expect_eq(Rules.legal_moves(["3S", "9S", "2C"], [Cards.play(2, "9H"), Cards.play(3, "5S")]),
			["9S"] as Array[String], "must overtrump")
	expect_same_set(Rules.legal_moves(["3S", "2C"], [Cards.play(2, "9H"), Cards.play(3, "QS")]),
			["3S", "2C"], "any card when unable")


func test_trick_winner_and_would_win() -> void:
	expect_eq(Rules.trick_winner([Cards.play(0, "9H"), Cards.play(1, "KH"), Cards.play(2, "2C"), Cards.play(3, "AH")]), 3)
	expect_eq(Rules.trick_winner([Cards.play(0, "9H"), Cards.play(1, "KH"), Cards.play(2, "2S"), Cards.play(3, "AH")]), 2)
	expect_true(Rules.would_win([Cards.play(0, "9H")], "10H"))
	expect_true(not Rules.would_win([Cards.play(0, "9H")], "AC"))


func test_card_ids_round_trip() -> void:
	for c in Cards.full_deck():
		expect_true(Cards.is_valid(c), "valid " + c)
		expect_eq(Cards.make(Cards.rank(c), Cards.suit(c)), c)
	expect_eq(Cards.rank("10H"), 10)
	expect_eq(Cards.suit("10H"), Cards.Suit.HEARTS)
	expect_true(not Cards.is_valid("1X"))
	expect_eq(Cards.sort_for_display(["2H", "AS", "KH", "3S"]), ["AS", "3S", "KH", "2H"] as Array[String])


func test_view_redaction_and_round_trip() -> void:
	var game := CallBreakGame.new(_bot_table(), 1)
	game.start()
	var view := game.view_for(0)
	expect_eq(view.hand, game.hand_of(0), "own hand visible")
	expect_eq(view.hand_counts, [13, 13, 13, 13] as Array[int])
	var spectator := game.view_for(-1)
	expect_true(spectator.hand.is_empty() and spectator.legal_move_ids.is_empty(), "spectator sees nothing")

	# Through JSON, exactly as it would cross a socket.
	var wire := JSON.stringify(game.view_for(0, 0).to_dict())
	var decoded := GameView.from_dict(JSON.parse_string(wire))
	expect_eq(decoded.host_seat, 0, "host seat survives")
	expect_eq(decoded.hand, view.hand)
	expect_eq(decoded.bids, [-1, -1, -1, -1] as Array[int], "null bids decode as -1")
	expect_eq(decoded.turn, game.turn)
	var hostless := GameView.from_dict(JSON.parse_string(JSON.stringify(game.view_for(0).to_dict())))
	expect_eq(hostless.host_seat, -1, "hostless table")


func test_decodes_server_golden_view() -> void:
	# Real frames written by the Go server's golden test, read straight from
	# backend/testdata so a regenerated file is checked here too. The copy in
	# tests/fixtures only stands in when the project is opened on its own.
	var path := ProjectSettings.globalize_path("res://").path_join("../backend/testdata/view_frames.json").simplify_path()
	if not FileAccess.file_exists(path):
		path = "res://tests/fixtures/view_frames.json"
	var f := FileAccess.open(path, FileAccess.READ)
	expect_true(f != null, "fixture present")
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	var frames: Array = parsed if parsed is Array else parsed.values()
	var decoded := 0
	for frame in frames:
		if frame is Dictionary and frame.has("phase"):
			var v := GameView.from_dict(frame)
			expect_eq(v.players.size(), 4, "four players")
			expect_eq(v.phase, frame["phase"])
			decoded += 1
	expect_true(decoded > 0, "at least one view decoded")
