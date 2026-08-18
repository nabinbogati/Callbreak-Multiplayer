package room

import (
	"time"

	"github.com/nabin31bogati/callbreak/backend/internal/auth"
	"github.com/nabin31bogati/callbreak/backend/internal/bot"
	"github.com/nabin31bogati/callbreak/backend/internal/engine"
	"github.com/nabin31bogati/callbreak/backend/internal/obs"
	"github.com/nabin31bogati/callbreak/backend/internal/protocol"
)

// applyJoin seats a player, or explains why it cannot.
//
// Three cases, in priority order: a verified resume claim takes its seat back
// even mid-game; the same player rejoining before the deal replaces their own
// stale socket; otherwise a free seat is allocated.
func (r *Room) applyJoin(req JoinRequest) JoinResult {
	if seat, ok := r.resumeSeat(req); ok {
		return r.attach(seat, req, true)
	}

	// A second socket from the same player supersedes the first, which is what
	// happens when a phone reconnects before the old socket's close is noticed.
	if seat, ok := r.seatOfPlayer(req.Player); ok {
		return r.attach(seat, req, true)
	}

	if r.started {
		return JoinResult{
			Err:     protocol.ErrGameStarted,
			ErrText: "That game has already started.",
		}
	}

	seat, ok := r.allocateSeat(req.Seat)
	if !ok {
		return JoinResult{Err: protocol.ErrRoomFull, ErrText: "That table is full."}
	}
	return r.attach(seat, req, false)
}

// resumeSeat validates a resume claim against live state. A token is not enough
// on its own: the seat must still belong to that player, or the token would let
// anyone who once sat there walk back into a table that has moved on.
func (r *Room) resumeSeat(req JoinRequest) (int, bool) {
	if req.ResumeSeat == nil {
		return 0, false
	}
	seat := *req.ResumeSeat
	if seat < 0 || seat > 3 {
		return 0, false
	}
	s := &r.seats[seat]
	if !s.occupied || s.player != req.Player {
		return 0, false
	}
	return seat, true
}

func (r *Room) seatOfPlayer(player auth.GuestID) (int, bool) {
	if player == "" {
		return 0, false
	}
	for i := range r.seats {
		if r.seats[i].occupied && r.seats[i].player == player {
			return i, true
		}
	}
	return 0, false
}

// allocateSeat picks a seat. A forced seat (from the matchmaker) is honoured
// when free; otherwise the lowest open seat wins, which puts the room's creator
// at seat 0 exactly like the LAN host.
func (r *Room) allocateSeat(forced *int) (int, bool) {
	if forced != nil {
		if *forced >= 0 && *forced < 4 && !r.seats[*forced].occupied {
			return *forced, true
		}
		return 0, false
	}
	for i := 0; i < 4; i++ {
		if !r.seats[i].occupied {
			return i, true
		}
	}
	return 0, false
}

// attach binds a client to a seat and tells everyone about it.
func (r *Room) attach(index int, req JoinRequest, reclaiming bool) JoinResult {
	s := &r.seats[index]

	// Displace whatever socket was there. Doing this before rebinding means the
	// old connection cannot later be mistaken for the seat's owner. Fail (not
	// Send+Close) so the old phone actually receives the explanation before the
	// socket vanishes — otherwise a silently displaced client would reconnect on
	// the next tick and ping-pong with the newcomer for this seat.
	if s.client != nil && s.client != req.Client {
		old := s.client
		s.client = nil
		old.Fail(protocol.ErrUnauthorized, "This seat was taken over by another connection.")
	}

	wasBot := s.occupied && s.kind == engine.KindBot
	s.occupied = true
	s.player = req.Player
	s.name = req.Name
	s.kind = engine.KindHuman
	s.client = req.Client
	s.connected = true
	s.graceUntil = time.Time{}
	// Coming back to the table is itself proof the player is there.
	s.autoplay = false
	if req.Difficulty != "" {
		s.difficulty = req.Difficulty
	}
	// Only overwrite the account when this join actually carries one: identity
	// resolution is asynchronous, so a reconnect may arrive before the lookup
	// that enriched the previous socket has been repeated.
	if req.UserID != "" {
		s.userID = req.UserID
	}

	// Only private tables have a host. Quickplay is hostless by design: nobody
	// invited anybody, so nobody gets to start or restart on the others' behalf.
	if r.mode == protocol.ModePrivate && (r.hostSeat < 0 || req.Host) {
		r.hostSeat = index
	}

	if r.started {
		r.game.SetPlayer(index, r.playerInfo(index))
		r.noteSeatTaken(index)
		if reclaiming || wasBot {
			obs.Reconnects.Inc()
			r.broadcast(protocol.SeatChange(index, engine.KindHuman, s.name, true))
		}
		// A reclaimed seat may be the one on the clock, and its deadline was a
		// bot-think delay. Recompute so the human actually gets their turn.
		r.publish()
	} else {
		r.broadcastLobby()
		r.evaluateAutoStart()
	}

	return JoinResult{Seat: index, IsHost: r.hostSeat == index, Reconnected: reclaiming || wasBot}
}

// playerInfo is the public description of a seat, as the engine and clients see it.
func (r *Room) playerInfo(index int) engine.PlayerInfo {
	s := &r.seats[index]
	difficulty := s.difficulty
	if difficulty == "" {
		difficulty = engine.Normal
	}
	return engine.PlayerInfo{
		Seat:       index,
		Name:       s.name,
		Kind:       s.kind,
		Difficulty: difficulty,
		Connected:  s.connected,
		Autoplay:   s.autoplay,
	}
}

func (r *Room) occupiedHumanSeats() int {
	n := 0
	for i := range r.seats {
		if r.seats[i].isHumanSeat() {
			n++
		}
	}
	return n
}

func (r *Room) connectedHumans() int {
	n := 0
	for i := range r.seats {
		if r.seats[i].isHumanSeat() && r.seats[i].connected {
			n++
		}
	}
	return n
}

// ------------------------------------------------------------------- lobby

// MinHumansToStart is how many connected humans a private table needs before
// the host may deal. One human against three bots is what the offline game is
// for; a private table is for people who actually invited each other, so it
// waits for a real player the same way a LAN table does (Dart
// LanHostSession.canStart).
const MinHumansToStart = 2

// applyHands updates the table's match length from the lobby. Any seated
// player may change it while the table is still waiting — the last value wins
// and is what the game deals when play starts, so host and players can agree on
// a length without leaving the room.
func (r *Room) applyHands(seat int, hands int) {
	if r.started || !protocol.ValidHandsPerGame(hands) {
		return
	}
	if r.totalHands == hands {
		return
	}
	r.totalHands = hands
	r.broadcastLobby()
}

func (r *Room) lobbyFor(seat int) protocol.Lobby {
	lobby := protocol.Lobby{
		Type:     protocol.TypeLobby,
		Room:     r.id,
		Mode:     r.mode,
		HostSeat: r.hostSeat,
		IsHost:   r.hostSeat == seat,
		Started:  r.started,
		// Only the host may start a private table, and only once at least
		// MinHumansToStart humans are actually connected. Quickplay tables deal
		// on their own countdown and are hostless, so nobody gets an explicit
		// start here.
		CanStart: !r.started && r.mode == protocol.ModePrivate &&
			r.hostSeat == seat && r.connectedHumans() >= MinHumansToStart,
		Seats:        make([]protocol.LobbySeat, 0, 4),
		HumansSeated: r.connectedHumans(),
		MinPlayers:   r.MinPlayers(),
		HandsPerGame: r.totalHands,
	}
	for i := range r.seats {
		s := &r.seats[i]
		if !s.occupied {
			continue
		}
		lobby.Seats = append(lobby.Seats, protocol.LobbySeat{
			Seat:      i,
			Name:      s.name,
			Kind:      s.kind,
			Connected: s.connected,
			IsYou:     i == seat,
			IsHost:    i == r.hostSeat,
		})
	}
	return lobby
}

func (r *Room) broadcastLobby() {
	for i := range r.seats {
		if r.seats[i].client == nil {
			continue
		}
		r.sendTo(i, protocol.Encode(r.lobbyFor(i)))
	}
}

// evaluateAutoStart decides whether a self-dealing table should be counting
// down, and is called after every change to who is sitting at it.
//
// The rule quickplay needs is "at least MinPlayers humans, ever": a table must
// never deal one human against three bots, and it must stop counting down if
// someone leaves at the last moment and takes it back below the minimum. Both
// directions matter, which is why this is re-evaluated on joins *and* leaves
// rather than only when the table fills up.
func (r *Room) evaluateAutoStart() {
	if r.started || !r.opts.AutoStart {
		return
	}

	humans := r.connectedHumans()
	if humans < r.MinPlayers() {
		r.cancelCountdown()
		return
	}

	// A full table has nobody left to wait for, so it deals on the short
	// countdown. A partial one holds the door open a while longer.
	wait := r.fillWait()
	if humans >= 4 {
		wait = r.pacing.StartCountdown
		// Shorten a fill-wait already in flight rather than letting four people
		// sit staring at each other.
		if !r.countdownAt.IsZero() && time.Until(r.countdownAt) > wait {
			r.cancelCountdown()
		}
	}
	r.applyStartCountdown(wait)
}

func (r *Room) fillWait() time.Duration {
	if r.opts.FillWait > 0 {
		return r.opts.FillWait
	}
	return r.pacing.StartCountdown
}

func (r *Room) applyStartCountdown(after time.Duration) {
	if r.started || !r.countdownAt.IsZero() {
		return
	}
	if after <= 0 {
		r.beginGame()
		return
	}
	r.countdownAt = time.Now().Add(after)
	r.broadcast(protocol.Countdown(int(after.Round(time.Second) / time.Second)))
}

// cancelCountdown stops a pending deal and tells everyone, so a client that is
// showing "starting in 3…" goes back to "waiting for players".
func (r *Room) cancelCountdown() {
	if r.countdownAt.IsZero() {
		return
	}
	r.countdownAt = time.Time{}
	r.broadcast(protocol.CountdownCancelled())
}

// applyStart handles the host pressing "Start" on a private table.
//
// Quickplay ignores it entirely: those tables deal on a countdown, and honouring
// a start frame there would let one player rush a deal before the others have
// finished loading the table.
func (r *Room) applyStart(seat int) {
	if r.started || r.mode != protocol.ModePrivate {
		return
	}
	if seat != r.hostSeat {
		r.sendErr(seat, protocol.ErrNotHost, "Only the host can start this game.")
		return
	}
	// A stale Start press beating the next lobby refresh must not deal a table
	// that no longer has enough people connected. Resend the lobby so the
	// host's button catches up with the new rule.
	if r.connectedHumans() < MinHumansToStart {
		r.sendErr(seat, protocol.ErrRoomNotReady, "Wait for at least two players to join.")
		r.broadcastLobby()
		return
	}
	r.beginGame()
}

// beginGame fills the empty seats with bots and deals. This mirrors
// LanHostSession.startGame in the Flutter client.
func (r *Room) beginGame() {
	if r.started {
		return
	}
	// The countdown can fire in the same breath as a player leaving. Dealing
	// here would start a game the table is no longer entitled to play, so the
	// minimum is checked again at the last possible moment.
	if r.opts.AutoStart && r.connectedHumans() < r.MinPlayers() {
		r.log.Info("start aborted: not enough players",
			"humans", r.connectedHumans(), "need", r.MinPlayers())
		r.cancelCountdown()
		r.broadcastLobby()
		return
	}
	r.countdownAt = time.Time{}
	r.fillWithBots()
	r.started = true
	r.startedAt = time.Now()
	r.accepting.Store(false)
	r.newGame()
	obs.GamesStarted.WithLabelValues(string(r.mode)).Inc()
	r.log.Info("game started", "humans", r.occupiedHumanSeats())
	r.broadcastLobby()
	r.publish()
}

func (r *Room) fillWithBots() {
	next := 0
	difficulty := r.tableDifficulty()
	for i := range r.seats {
		if r.seats[i].occupied {
			continue
		}
		r.seats[i] = seat{
			occupied:   true,
			name:       BotNames[next%len(BotNames)],
			kind:       engine.KindBot,
			connected:  true,
			difficulty: difficulty,
		}
		next++
	}
}

// tableDifficulty is whatever the humans asked for; the first seated human's
// preference wins, since one table can only have one bot standard.
func (r *Room) tableDifficulty() engine.Difficulty {
	for i := range r.seats {
		if r.seats[i].isHumanSeat() && r.seats[i].difficulty != "" {
			return r.seats[i].difficulty
		}
	}
	return engine.Normal
}

// newGame builds a fresh engine and matching brains from the current seats, and
// deals. Used by both the initial start and by restart — the engine has no
// in-place reset, the same as the Dart original.
func (r *Room) newGame() {
	// A restart on a table that never reached GameOver abandons a game that was
	// really dealt and really played, so it gets its §2.3 row before the state
	// it was built from is thrown away. After a normal GameOver this is a no-op
	// — that record was submitted from onEvent — which is what keeps a restart
	// from writing the finished game twice.
	r.abandonRecording()

	var players [4]engine.PlayerInfo
	for i := range r.seats {
		players[i] = r.playerInfo(i)
	}
	r.game = engine.NewGame(players, r.totalHands, r.rng)
	r.game.SetDealConfig(r.opts.Deal)
	for i := range r.brains {
		// Every seat gets a brain, not just the bots: it is what covers a human
		// who drops or lets their clock run out.
		r.brains[i] = bot.New(players[i].Difficulty, r.rng)
	}
	r.clearReady()
	r.clearAutoplay()
	r.handAdvanceAt = time.Time{}
	r.game.Start()
	// Started after the deal, so a table that was never dealt is never recorded,
	// and with a clean log, so a restarted game shares nothing with the one
	// before it.
	r.beginRecording()
}

// ------------------------------------------------------------- leaving seats

func (r *Room) applyDisconnect(msg disconnectMsg) {
	idx := msg.seat
	if idx < 0 || idx > 3 || r.seats[idx].client != msg.client {
		return // Already replaced by a newer socket.
	}
	s := &r.seats[idx]
	s.client = nil
	s.connected = false

	if !r.started {
		// Nothing to preserve before the deal: free the seat outright so the
		// lobby does not fill up with ghosts.
		*s = seat{}
		if r.hostSeat == idx {
			r.reassignHost()
		}
		r.broadcastLobby()
		r.evaluateAutoStart()
		if r.occupiedHumanSeats() == 0 {
			r.idleAt = time.Now().Add(r.pacing.IdleTTL)
		}
		return
	}

	s.graceUntil = time.Now().Add(r.pacing.ReconnectGrace)
	obs.BotTakeovers.Inc()
	r.game.SetPlayer(idx, r.playerInfo(idx))
	r.log.Info("seat dropped, bot covering", "seat", idx, "grace", r.pacing.ReconnectGrace)
	r.broadcast(protocol.SeatChange(idx, s.kind, s.name, false))
	if r.hostSeat == idx {
		r.reassignHost()
	}
	// The dropped seat may be the one on the clock; republishing swaps its human
	// turn clock for a bot-think delay so the table keeps moving.
	r.publish()
}

func (r *Room) applyLeave(msg leaveMsg) {
	idx := msg.seat
	if idx < 0 || idx > 3 || r.seats[idx].client != msg.client {
		return
	}
	// An explicit leave forfeits the grace window: the player said they are done.
	r.seats[idx].client = nil
	r.seats[idx].connected = false
	r.seats[idx].graceUntil = time.Time{}
	if msg.client != nil {
		msg.client.Close("normal", "left the table")
	}
	if r.started {
		r.expireSeat(idx)
	} else {
		r.seats[idx] = seat{}
		if r.hostSeat == idx {
			r.reassignHost()
		}
		r.broadcastLobby()
		r.evaluateAutoStart()

		// An explicit leave is a deliberate "I am done" — nobody is coming
		// back, so an empty lobby has no reason to live out its idle TTL.
		// Disconnects keep that grace (a dropped phone may rejoin the code);
		// a leave forfeits it, the same way it does mid-game in expireSeat.
		if r.connectedHumans() == 0 && !r.anySeatInGrace() {
			r.log.Info("no one left in the lobby, closing table")
			r.Close()
		}
	}
}

// expireSeat converts a seat whose player is not coming back into a permanent
// bot, so the remaining players get a finished game rather than a stalled one.
func (r *Room) expireSeat(index int) {
	s := &r.seats[index]
	if !s.occupied || s.kind == engine.KindBot {
		return
	}
	s.kind = engine.KindBot
	s.player = ""
	// The account goes with the player. The game record keeps its own snapshot,
	// so the human who played most of this game still gets it in their history.
	s.userID = ""
	s.client = nil
	s.connected = true
	s.graceUntil = time.Time{}
	if s.difficulty == "" {
		s.difficulty = engine.Normal
	}

	if r.started {
		r.game.SetPlayer(index, r.playerInfo(index))
		r.broadcast(protocol.SeatChange(index, engine.KindBot, s.name, true))
	}
	if r.hostSeat == index {
		r.reassignHost()
	}
	r.log.Info("seat handed to a bot for good", "seat", index)

	if r.connectedHumans() == 0 && !r.anySeatInGrace() {
		// Nobody is left to watch: stop the table rather than let four bots play
		// out five hands into an empty room. But a seat that is still inside its
		// drop-grace window is a player who may come straight back — closing now
		// would flush their rejoin into a brand-new lobby instead of the table
		// they were mid-way through, so the room stays for them.
		r.log.Info("no humans left, closing table")
		r.Close()
		return
	}
	if r.started {
		r.publish()
	} else {
		r.broadcastLobby()
	}
}

// anySeatInGrace reports whether any seat is still within its drop-grace
// window — a claim on this table that outlives whoever is currently connected.
func (r *Room) anySeatInGrace() bool {
	now := time.Now()
	for i := range r.seats {
		if !r.seats[i].graceUntil.IsZero() && now.Before(r.seats[i].graceUntil) {
			return true
		}
	}
	return false
}

// reassignHost moves host duties to the lowest-numbered connected human, so a
// private table never loses its ability to start or restart when the host
// leaves. Quickplay has no host to reassign.
func (r *Room) reassignHost() {
	r.hostSeat = -1
	if r.mode != protocol.ModePrivate {
		return
	}
	for i := range r.seats {
		if r.seats[i].isHumanSeat() && r.seats[i].connected {
			r.hostSeat = i
			return
		}
	}
}
