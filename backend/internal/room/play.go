package room

import (
	"time"

	"github.com/nabin31bogati/callbreak/backend/internal/bot"
	"github.com/nabin31bogati/callbreak/backend/internal/engine"
	"github.com/nabin31bogati/callbreak/backend/internal/obs"
	"github.com/nabin31bogati/callbreak/backend/internal/protocol"
)

// publish is the table's heartbeat: decide what happens next, push a redacted
// view to every seat, then release the events the engine produced.
//
// Scheduling comes first so the view can carry the turn deadline the client
// renders as a countdown. Views come before events because the client applies
// the view as state and the events purely as animation.
func (r *Room) publish() {
	if !r.started || r.game == nil {
		return
	}
	r.scheduleNextAction()
	r.fanOutViews()
	for _, event := range r.game.TakeEvents() {
		r.onEvent(event)
	}
}

func (r *Room) fanOutViews() {
	now := time.Now().UnixMilli()
	deadline := int64(0)
	// Only a human's clock is worth showing; a bot's think delay is flavour, not
	// a countdown the player should watch.
	if r.autoKind == autoTurnTimeout && !r.autoAt.IsZero() {
		deadline = r.autoAt.UnixMilli()
	}

	// The scoreboard's clock is the whole table's, not one seat's, so unlike the
	// turn deadline it goes to everybody.
	handAdvance := int64(0)
	if !r.handAdvanceAt.IsZero() {
		handAdvance = r.handAdvanceAt.UnixMilli()
	}

	for i := range r.seats {
		if r.seats[i].client == nil {
			continue
		}
		view := r.game.ViewFor(i)
		// The engine does not know about hosts; the room does. Private tables
		// always have one (it is reassigned when one leaves), and quickplay has
		// none, so nil means "no host to point at".
		if r.hostSeat >= 0 {
			hs := r.hostSeat
			view.HostSeat = &hs
		}
		view.ServerTimeMs = now
		view.HandAdvanceMs = handAdvance
		if r.game.Turn != nil && *r.game.Turn == i {
			view.TurnDeadlineMs = deadline
		}
		frame, err := protocol.EncodeView(view)
		if err != nil {
			r.log.Error("failed to encode view", "seat", i, "err", err)
			continue
		}
		r.sendTo(i, frame)
		obs.MessagesOut.WithLabelValues(protocol.TypeView).Inc()
	}
}

func (r *Room) onEvent(event engine.Event) {
	frame, err := protocol.EncodeEvent(event)
	if err != nil {
		r.log.Error("failed to encode event", "err", err)
		return
	}
	r.broadcast(frame)
	obs.MessagesOut.WithLabelValues(protocol.TypeEvent).Inc()

	switch e := event.(type) {
	case engine.HandStarted:
		r.clearReady()
		r.noteHandStarted()
	case engine.CardPlayed:
		r.noteCardPlayed(e)
	case engine.TrickWon:
		r.noteTrickWon(e)
	case engine.HandOver:
		r.clearReady()
		r.noteHandOver(e)
	case engine.GameOver:
		r.clearReady()
		r.clearAuto()
		obs.GamesFinished.WithLabelValues(string(r.mode)).Inc()
		// The scoreboard is complete the moment this event exists, so the record
		// is built and queued here rather than at teardown. finishRecording
		// clears the log, which is what stops a later restart or close from
		// writing this same game a second time.
		r.finishRecording(true, e.Rankings)
	}
}

// scheduleNextAction sets the single clock the table runs on.
func (r *Room) scheduleNextAction() {
	r.clearAuto()
	if !r.started || r.game == nil {
		return
	}

	// Everyone reads the scoreboard at their own pace, but the table cannot wait
	// forever on someone who walked away. The clock is set here rather than off
	// the HandOver event so it is already running when the view that carries it
	// to the clients goes out — and only if it is not already running, so that
	// republishing (a tap, a reconnect) cannot keep pushing the deal back.
	if r.game.Phase == engine.PhaseHandOver {
		if r.handAdvanceAt.IsZero() {
			r.handAdvanceAt = time.Now().Add(r.pacing.HandAdvanceWait)
		}
		return
	}
	r.handAdvanceAt = time.Time{}

	if r.game.AwaitingTrickClr {
		r.setAuto(autoClearTrick, -1, time.Now().Add(r.pacing.TrickLinger))
		return
	}

	turn := r.game.Turn
	if turn == nil {
		return
	}
	s := &r.seats[*turn]

	if s.serverDriven() {
		r.setAuto(autoServerMove, *turn, time.Now().Add(r.thinkTime()))
		return
	}
	// The turn clock starts the moment the deal view goes out, while the
	// dealing animation is still on screen. The first bidder of the hand gets
	// [Pacing.DealGrace] extra so the animation does not eat into their bid
	// time.
	timeout := r.turnTimeout()
	if r.game.Phase == engine.PhaseBidding && r.firstBidDue() {
		timeout += r.pacing.DealGrace
	}
	r.setAuto(autoTurnTimeout, *turn, time.Now().Add(timeout))
}

// firstBidDue reports whether the very first bid of the hand is still on the
// clock — the one whose deadline overlaps the dealing animation.
func (r *Room) firstBidDue() bool {
	for _, b := range r.game.Bids {
		if b != nil {
			return false
		}
	}
	return true
}

// thinkTime is the pause before a server-driven seat acts, so the table reads
// as four people playing rather than a state machine resolving.
func (r *Room) thinkTime() time.Duration {
	extra := r.pacing.BotThinkExtra
	if extra <= 0 {
		return r.pacing.BotThinkMin
	}
	return r.pacing.BotThinkMin + time.Duration(r.rng.Int64N(int64(extra)))
}

func (r *Room) turnTimeout() time.Duration {
	if r.game.Phase == engine.PhaseBidding {
		return r.pacing.BidTimeout
	}
	return r.pacing.PlayTimeouts[len(r.game.Trick)]
}

// runAuto applies whichever clock just fired.
func (r *Room) runAuto(kind autoKind, seatIndex int) {
	if !r.started || r.game == nil {
		return
	}
	switch kind {
	case autoClearTrick:
		if !r.game.AwaitingTrickClr {
			return
		}
		r.game.ClearTrick()
		r.publish()
	case autoServerMove, autoTurnTimeout:
		// The turn may have moved on between scheduling and firing — for
		// instance because the player reconnected and played. Acting on a stale
		// seat would inject a move nobody made.
		if r.game.Turn == nil || *r.game.Turn != seatIndex {
			r.publish()
			return
		}
		if kind == autoTurnTimeout {
			obs.TurnTimeouts.Inc()
			// Bidding and play run independent clocks. Missing the bid only
			// settles the bid — the seat stays its player's, so they still get
			// a full-clocked turn the moment the cards are in play. Only a
			// play-phase timeout hands the seat over for the rest of the hand;
			// see enterAutoplay.
			if r.game.Phase != engine.PhaseBidding {
				r.enterAutoplay(seatIndex)
			}
		}
		r.takeServerTurn(seatIndex)
	}
}

// enterAutoplay hands a seat over to the bot for every turn from here, not just
// the one that timed out.
//
// Making each subsequent turn wait out the full clock again would punish the
// rest of the table for one player walking away — four idle turns a hand is
// over a minute of nothing happening. The seat is given back the instant its
// player shows any sign of life; see clearAutoplay.
func (r *Room) enterAutoplay(seatIndex int) {
	s := &r.seats[seatIndex]
	if s.autoplay || s.kind == engine.KindBot {
		return
	}
	s.autoplay = true
	obs.AutoplayEntered.Inc()
	r.log.Info("seat handed to autoplay after a turn timeout",
		"seat", seatIndex, "phase", string(r.game.Phase))
	r.game.SetPlayer(seatIndex, r.playerInfo(seatIndex))
	r.broadcast(protocol.AutoplayChanged(seatIndex, s.name, true))
}

// clearAutoplay gives a seat back to its player. Returns whether anything
// changed, so callers only republish when it matters.
func (r *Room) clearAutoplay(seatIndex ...int) bool {
	changed := false
	seats := seatIndex
	if len(seats) == 0 {
		seats = []int{0, 1, 2, 3}
	}
	for _, i := range seats {
		s := &r.seats[i]
		if !s.autoplay {
			continue
		}
		s.autoplay = false
		changed = true
		if r.started && r.game != nil {
			r.game.SetPlayer(i, r.playerInfo(i))
			r.broadcast(protocol.AutoplayChanged(i, s.name, false))
		}
	}
	return changed
}

// applyAwake is the player saying "I am here" — sent on any interaction with
// the table, not only on a move, so tapping anywhere takes the seat back.
func (r *Room) applyAwake(seatIndex int) {
	if !r.clearAutoplay(seatIndex) {
		return
	}
	r.log.Info("player took back their seat from autoplay", "seat", seatIndex)
	// Republishing restarts the turn clock for this seat if it is on the clock,
	// so they get a full turn rather than the remains of the bot's think delay.
	r.publish()
}

// takeServerTurn plays one move on behalf of a seat, using the same brain the
// bots use. A timed-out player gets a sensible move, not a random one.
func (r *Room) takeServerTurn(seatIndex int) {
	brain := r.brains[seatIndex]
	if brain == nil {
		brain = bot.New(engine.Normal, r.rng)
		r.brains[seatIndex] = brain
	}
	hand := r.game.HandOf(seatIndex)

	switch r.game.Phase {
	case engine.PhaseBidding:
		if !r.game.PlaceBid(seatIndex, brain.ChooseBid(hand)) {
			r.log.Warn("server bid rejected", "seat", seatIndex)
			return
		}
	case engine.PhasePlaying:
		bid := 1
		if b := r.game.Bids[seatIndex]; b != nil {
			bid = *b
		}
		card, ok := brain.ChooseCard(bot.Move{
			Hand:      hand,
			Trick:     r.game.Trick,
			Played:    r.game.PlayedThisHand,
			Bid:       bid,
			TricksWon: r.game.TricksWon[seatIndex],
		})
		if !ok || !r.game.PlayCard(seatIndex, card) {
			r.log.Error("server move rejected", "seat", seatIndex, "card", card.ID())
			return
		}
	default:
		return
	}
	r.publish()
}

// ------------------------------------------------------------- player intents

func (r *Room) applyBid(seatIndex, bid int) {
	// Acting is proof enough of presence; no need for a separate awake frame.
	r.clearAutoplay(seatIndex)
	if !r.started {
		r.sendErr(seatIndex, protocol.ErrGameStarted, "The game has not started yet.")
		return
	}
	if !r.game.PlaceBid(seatIndex, bid) {
		r.sendErr(seatIndex, protocol.ErrNotYourTurn, "It is not your turn to bid.")
		// Resend the authoritative view so a client that got out of step with
		// the table snaps back into line instead of staying wrong.
		r.fanOutViews()
		return
	}
	r.publish()
}

func (r *Room) applyPlay(seatIndex int, cardID string) {
	r.clearAutoplay(seatIndex)
	if !r.started {
		r.sendErr(seatIndex, protocol.ErrGameStarted, "The game has not started yet.")
		return
	}
	card, err := engine.ParseCard(cardID)
	if err != nil {
		r.sendErr(seatIndex, protocol.ErrBadFrame, "That is not a card.")
		return
	}
	if !r.game.PlayCard(seatIndex, card) {
		code := protocol.ErrIllegalMove
		message := "You cannot play that card."
		if r.game.Turn == nil || *r.game.Turn != seatIndex {
			code, message = protocol.ErrNotYourTurn, "It is not your turn."
		}
		r.sendErr(seatIndex, code, message)
		r.fanOutViews()
		return
	}
	r.publish()
}

// applyNext is a seat's consent to leave the scoreboard.
//
// With more than one human at the table, one player tapping "next hand" must
// not wipe the scoreboard out from under everybody else, so the hand only
// advances once every connected human has agreed — or the wait times out.
func (r *Room) applyNext(seatIndex int) {
	r.clearAutoplay(seatIndex)
	if !r.started || r.game.Phase != engine.PhaseHandOver {
		return
	}
	r.seats[seatIndex].consented = true

	ready, total, waiting := r.readyTally()
	if ready >= total {
		r.advanceHand()
		return
	}
	r.broadcast(protocol.ReadyState(ready, total, waiting))
}

func (r *Room) advanceHand() {
	if !r.started || r.game == nil || r.game.Phase != engine.PhaseHandOver {
		return
	}
	r.handAdvanceAt = time.Time{}
	r.clearReady()
	r.game.NextHand()
	r.publish()
}

// applyRestart deals a brand-new game with the same seats.
//
// On a private table that is the host's call. In quickplay there is no host, so
// every connected human has to agree — otherwise one player could reset a game
// the others were still playing.
func (r *Room) applyRestart(seatIndex int) {
	if !r.started {
		return
	}
	if r.mode == protocol.ModePrivate {
		if seatIndex != r.hostSeat {
			r.sendErr(seatIndex, protocol.ErrNotHost, "Only the host can restart this game.")
			return
		}
		r.restart()
		return
	}

	r.seats[seatIndex].consented = true
	ready, total, waiting := r.readyTally()
	if ready >= total {
		r.restart()
		return
	}
	r.broadcast(protocol.ReadyState(ready, total, waiting))
}

func (r *Room) restart() {
	r.clearAuto()
	r.newGame()
	obs.GamesStarted.WithLabelValues(string(r.mode)).Inc()
	r.publish()
}

// readyTally counts consent among connected humans. Bots and dropped players
// are never waited on — they would never answer.
func (r *Room) readyTally() (ready, total int, waitingFor []int) {
	for i := range r.seats {
		s := &r.seats[i]
		if !s.isHumanSeat() || !s.connected {
			continue
		}
		total++
		if s.consented {
			ready++
		} else {
			waitingFor = append(waitingFor, i)
		}
	}
	if waitingFor == nil {
		waitingFor = []int{}
	}
	return ready, total, waitingFor
}

func (r *Room) clearReady() {
	for i := range r.seats {
		r.seats[i].consented = false
	}
}
