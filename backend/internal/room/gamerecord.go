package room

import (
	"time"

	"github.com/nabin31bogati/callbreak/backend/internal/db"
	"github.com/nabin31bogati/callbreak/backend/internal/engine"
	"github.com/nabin31bogati/callbreak/backend/internal/protocol"
)

// The scoreboard a table accumulates while it is being played.
//
// Every field here is actor-owned, exactly like the engine and the seats: it is
// written only from the room goroutine, in the same switch that already fans
// events out to clients. Building the record as the game happens is what keeps
// the end of a game cheap — at GameOver there is nothing left to compute, only
// a hand-off to the recorder's queue.
//
// See docs/PERSISTENCE.md §2 for the grain and §2.3 for abandoned games.
type gameLog struct {
	// active is set from the deal until the record is submitted. It is the
	// double-record guard: a restart, a close and a GameOver all funnel through
	// finishRecording, and only the first one to run sees active.
	active    bool
	startedAt time.Time
	// seats is captured at the deal, then refreshed only when a human takes a
	// seat. It deliberately survives expireSeat: a player who rage-quits still
	// played the game, and §2.3 says that game must not vanish from their
	// history just because a bot finished it for them.
	seats  [4]db.SeatRecord
	hands  []db.HandRecord
	tricks []db.TrickRecord
	// trick is the trick currently on the table, assembled from the same
	// CardPlayed events the clients animate.
	trick []db.TrickPlay
}

func (g *gameLog) reset() {
	*g = gameLog{}
}

// recordMode maps the two modes a server-played table can have onto the storage
// vocabulary. Anything else is not recorded rather than guessed at.
func recordMode(m protocol.Mode) (db.Mode, bool) {
	switch m {
	case protocol.ModeOnline:
		return db.ModeOnline, true
	case protocol.ModePrivate:
		return db.ModePrivate, true
	}
	return "", false
}

// beginRecording starts a fresh scoreboard. Called from newGame, immediately
// after the engine has dealt — a game that was never dealt is never recorded.
func (r *Room) beginRecording() {
	r.rec.reset()
	if !r.recorder.enabled() {
		return
	}
	if _, ok := recordMode(r.mode); !ok {
		return
	}
	r.rec.active = true
	r.rec.startedAt = time.Now()
	for i := range r.seats {
		r.rec.seats[i] = r.seatRecord(i)
	}
	r.rec.hands = make([]db.HandRecord, 0, 4*r.totalHands)
}

// seatRecord is the identity half of a seat's row. Scores are filled in at the
// end, from the engine.
func (r *Room) seatRecord(index int) db.SeatRecord {
	s := &r.seats[index]
	rec := db.SeatRecord{
		Seat:        index,
		DisplayName: s.name,
		IsBot:       s.kind == engine.KindBot,
	}
	if rec.IsBot {
		difficulty := s.difficulty
		if difficulty == "" {
			difficulty = engine.Normal
		}
		rec.BotDifficulty = string(difficulty)
	} else {
		// Bots have no account; a human without a resolved device id is recorded
		// with an empty user id, which the store stores as NULL (§4.1).
		rec.UserID = s.userID
	}
	return rec
}

// noteSeatTaken refreshes a seat's identity when a human sits down at a seat
// the record currently attributes to a bot. That is the reconnect-into-a-bot
// case; a seat already attributed to a human is left alone so the player who
// actually played it keeps the credit.
func (r *Room) noteSeatTaken(index int) {
	if !r.rec.active {
		return
	}
	if !r.rec.seats[index].IsBot {
		return
	}
	r.rec.seats[index] = r.seatRecord(index)
}

// noteSeatUser attaches an account to a seat, for the case where identity
// resolution finished after the player was already seated.
func (r *Room) noteSeatUser(index int, userID string) {
	if !r.rec.active || userID == "" {
		return
	}
	if r.rec.seats[index].IsBot {
		return
	}
	r.rec.seats[index].UserID = userID
}

// ------------------------------------------------------------------- events

func (r *Room) noteHandStarted() {
	if !r.rec.active {
		return
	}
	r.rec.trick = nil
}

func (r *Room) noteCardPlayed(e engine.CardPlayed) {
	if !r.rec.active {
		return
	}
	r.rec.trick = append(r.rec.trick, db.TrickPlay{Seat: e.Seat, Card: e.Card.ID()})
}

// noteTrickWon banks the completed trick. The engine has not swept it yet — it
// increments TrickNumber in ClearTrick — so TrickNumber here is the index of
// the trick that just finished.
//
// This detail is only ever read when the store was opened with trick recording
// on, so populating it always is harmless and costs one small slice per hand.
func (r *Room) noteTrickWon(e engine.TrickWon) {
	if !r.rec.active {
		return
	}
	if len(r.rec.trick) == 0 {
		return
	}
	r.rec.tricks = append(r.rec.tricks, db.TrickRecord{
		HandIndex:   r.game.HandIndex,
		TrickNumber: r.game.TrickNumber,
		LeadSeat:    r.rec.trick[0].Seat,
		WinnerSeat:  e.Seat,
		Plays:       r.rec.trick,
	})
	r.rec.trick = nil
}

// noteHandOver appends one scoreboard line per seat. The engine has already
// banked the deltas into Totals by the time this event is released, so the
// running total is read straight off it rather than recomputed here.
func (r *Room) noteHandOver(e engine.HandOver) {
	if !r.rec.active {
		return
	}
	for seat := 0; seat < 4; seat++ {
		bid := 0
		if b := r.game.Bids[seat]; b != nil {
			bid = *b
		}
		delta := 0.0
		if seat < len(e.Deltas) {
			delta = e.Deltas[seat]
		}
		r.rec.hands = append(r.rec.hands, db.HandRecord{
			HandIndex:    e.HandIndex,
			Seat:         seat,
			Bid:          bid,
			TricksWon:    r.game.TricksWon[seat],
			ScoreDelta:   delta,
			RunningTotal: r.game.Totals[seat],
		})
	}
}

// ---------------------------------------------------------------- submission

// finishRecording builds the record and hands it to the recorder. It is the
// only place a record is submitted, and it clears the log on the way out, so
// every path into it — GameOver, a restart, the room closing — records a game
// exactly once.
func (r *Room) finishRecording(completed bool, rankings []engine.SeatRanking) {
	if !r.rec.active {
		return
	}
	r.rec.active = false

	mode, ok := recordMode(r.mode)
	if !ok || r.game == nil {
		r.rec.reset()
		return
	}

	rec := db.GameRecord{
		Mode:     mode,
		Source:   db.SourceServer,
		RoomCode: r.id,
		// Server-played games are not uploads, so there is nothing to be
		// idempotent on: the server writes each one exactly once.
		ClientGameID: "",
		HandsTotal:   len(r.rec.hands) / 4,
		Completed:    completed,
		StartedAt:    r.rec.startedAt,
		FinishedAt:   time.Now(),
		Hands:        r.rec.hands,
		Tricks:       r.rec.tricks,
	}

	places := [4]int{}
	for _, rank := range rankings {
		if rank.Seat >= 0 && rank.Seat < 4 {
			places[rank.Seat] = rank.Place
		}
	}

	rec.Seats = make([]db.SeatRecord, 0, 4)
	for i := 0; i < 4; i++ {
		seat := r.rec.seats[i]
		seat.Seat = i
		seat.FinalScore = r.game.Totals[i]
		seat.Place = places[i]
		for _, hand := range r.rec.hands {
			if hand.Seat != i {
				continue
			}
			seat.TotalBid += hand.Bid
			seat.TotalTricks += hand.TricksWon
			if hand.TricksWon >= hand.Bid {
				seat.HandsMade++
			}
		}
		rec.Seats = append(rec.Seats, seat)
	}

	// The log is cleared before the hand-off so nothing the room still owns is
	// shared with the recorder's goroutines.
	r.rec = gameLog{}
	r.recorder.Submit(rec)
}

// abandonRecording writes a game that never reached a final scoreboard, per
// §2.3: it counts as played but never as won, and a rage-quit does not erase
// the hands that were actually finished. A no-op when there is nothing in
// progress, which is what makes it safe to call from every teardown path.
func (r *Room) abandonRecording() {
	r.finishRecording(false, nil)
}
