package db

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
)

// insertGameSQL creates the game row, or declines to.
//
// The ON CONFLICT clause names the partial index's predicate because that is
// how Postgres is told which unique index to arbitrate on; without the WHERE it
// cannot infer a partial one and refuses the statement.
//
// DO NOTHING rather than DO UPDATE is deliberate here, and is the opposite
// choice to the one ResolveIdentity makes. There, the point was to learn who
// won a race. Here the point is that a retry must write *nothing at all*: no
// row version, no updated finished_at, and — because the whole of RecordGame is
// downstream of this returning a row — no seats, no hands, and above all no
// second pass over the statistics.
//
// A concurrent, still-uncommitted insert of the same client_game_id does not
// slip through: ON CONFLICT DO NOTHING waits for the other transaction to
// finish before concluding there is a conflict, and this transaction is READ
// COMMITTED, so the SELECT that follows takes a fresh snapshot and sees the
// row the winner just committed.
const insertGameSQL = `
INSERT INTO games (mode, source, room_code, client_game_id, hands_total, completed, started_at, finished_at)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
ON CONFLICT (client_game_id) WHERE client_game_id IS NOT NULL DO NOTHING
RETURNING id`

// RecordGame writes a finished game and everything it implies, in one
// transaction.
//
// "One transaction" is the entire correctness argument. A game whose seats
// committed but whose statistics did not would be permanently wrong, and no
// amount of retrying at a higher level could tell that from a game that was
// never written. Either the whole scoreboard and both counter rows land, or the
// caller is free to try again from the top.
func (p *Postgres) RecordGame(ctx context.Context, rec GameRecord) (string, bool, error) {
	if err := validateRecord(rec); err != nil {
		return "", false, err
	}

	// Per-seat figures the hands imply. Derived from the record being written
	// rather than read back out of the database, so this costs no round trip
	// and cannot see a half-written game.
	perSeat := summariseHands(rec.Hands)

	var gameID string
	var duplicate bool
	err := p.inTx(ctx, "record game", func(tx pgx.Tx) error {
		var clientID *string
		if rec.ClientGameID != "" {
			clientID = &rec.ClientGameID
		}

		err := tx.QueryRow(ctx, insertGameSQL,
			string(rec.Mode), string(rec.Source), rec.RoomCode, clientID,
			rec.HandsTotal, rec.Completed, rec.StartedAt, rec.FinishedAt,
		).Scan(&gameID)

		if errors.Is(err, pgx.ErrNoRows) {
			// Already uploaded. Hand back the original id and stop: this is the
			// no-op that makes a client free to retry an upload forever.
			duplicate = true
			err = tx.QueryRow(ctx,
				`SELECT id FROM games WHERE client_game_id = $1`, rec.ClientGameID).Scan(&gameID)
			if err != nil {
				return p.fail("record game", err)
			}
			return nil
		}
		if err != nil {
			return p.fail("record game", err)
		}

		if err := p.insertChildren(ctx, tx, gameID, rec); err != nil {
			return err
		}

		// Statistics move only on the path that actually inserted a game, which
		// is what makes them exactly-once under retry rather than
		// at-least-once. There is no separate idempotency key on the counters
		// and there does not need to be: the games table already carries one,
		// and this transaction is the only thing that can reach past it.
		for _, seat := range rec.Seats {
			if seat.UserID == "" || !validUUID(seat.UserID) {
				continue // a bot, or a human the server could not attribute
			}
			d := seatDelta(rec, seat, perSeat[seat.Seat])
			// The mode's own row and the across-everything row, always both.
			for _, scope := range []string{string(rec.Mode), ScopeAll} {
				d.scope = scope
				if err := p.applyStats(ctx, tx, d); err != nil {
					return err
				}
			}
		}
		return nil
	})
	if err != nil {
		return "", false, err
	}
	return gameID, duplicate, nil
}

// insertChildren writes the seats, the scoreboard and — if trick recording is
// on — the cards. One batch, so a game costs one network round trip below the
// game row rather than one per hand.
func (p *Postgres) insertChildren(ctx context.Context, tx pgx.Tx, gameID string, rec GameRecord) error {
	batch := &pgx.Batch{}

	for _, s := range rec.Seats {
		var userID *string
		if s.UserID != "" && validUUID(s.UserID) {
			userID = &s.UserID
		}
		batch.Queue(`
			INSERT INTO game_seats (game_id, seat, user_id, display_name, is_bot, bot_difficulty,
			                        final_score, place, total_bid, total_tricks, hands_made,
			                        mode, finished_at)
			VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)`,
			gameID, s.Seat, userID, s.DisplayName, s.IsBot, s.BotDifficulty,
			s.FinalScore, s.Place, s.TotalBid, s.TotalTricks, s.HandsMade,
			string(rec.Mode), rec.FinishedAt)
	}

	for _, h := range rec.Hands {
		batch.Queue(`
			INSERT INTO game_hands (game_id, hand_index, seat, bid, tricks_won, score_delta, running_total)
			VALUES ($1,$2,$3,$4,$5,$6,$7)`,
			gameID, h.HandIndex, h.Seat, h.Bid, h.TricksWon, h.ScoreDelta, h.RunningTotal)
	}

	if p.opts.RecordTricks {
		for _, t := range rec.Tricks {
			plays, err := json.Marshal(t.Plays)
			if err != nil {
				return fmt.Errorf("db: encoding trick %d/%d: %w", t.HandIndex, t.TrickNumber, err)
			}
			batch.Queue(`
				INSERT INTO game_tricks (game_id, hand_index, trick_number, lead_seat, winner_seat, plays)
				VALUES ($1,$2,$3,$4,$5,$6)`,
				gameID, t.HandIndex, t.TrickNumber, t.LeadSeat, t.WinnerSeat, plays)
		}
	}

	results := tx.SendBatch(ctx, batch)
	// Close reports the first error any queued statement produced, which is the
	// one worth surfacing; the transaction is doomed either way.
	if err := results.Close(); err != nil {
		return p.fail("record game", err)
	}
	return nil
}

// handSummary is what a seat's hands say about it, in the shape the counters
// want.
type handSummary struct {
	played     int
	highestBid int
	// bestScore is the seat's best single hand. A pointer because a seat with
	// no recorded hands has no best hand, which is not the same as zero.
	bestScore *float64
}

// summariseHands rolls the scoreboard up per seat in one pass.
func summariseHands(hands []HandRecord) map[int]handSummary {
	out := make(map[int]handSummary, 4)
	for _, h := range hands {
		s := out[h.Seat]
		s.played++
		if h.Bid > s.highestBid {
			s.highestBid = h.Bid
		}
		if s.bestScore == nil || h.ScoreDelta > *s.bestScore {
			score := h.ScoreDelta
			s.bestScore = &score
		}
		out[h.Seat] = s
	}
	return out
}

// seatDelta turns one seat's result into a counter delta. The scope is left for
// the caller to fill in, because the same delta is applied twice under two
// different scopes.
func seatDelta(rec GameRecord, seat SeatRecord, hands handSummary) statsDelta {
	d := statsDelta{
		userID:      seat.UserID,
		completed:   rec.Completed,
		place:       seat.Place,
		handsPlayed: hands.played,
		totalBid:    seat.TotalBid,
		bidsMade:    seat.HandsMade,
		bidsFailed:  hands.played - seat.HandsMade,
		highestBid:  hands.highestBid,
		totalTricks: seat.TotalTricks,
		finalScore:  seat.FinalScore,
		finishedAt:  rec.FinishedAt,
	}
	if d.bidsFailed < 0 {
		// A caller claiming more hands made than hands played is confused; it
		// must not be allowed to drive a counter negative.
		d.bidsFailed = 0
	}
	// Only a game that reached a final scoreboard decides anything (§2.3): an
	// abandoned table counts as played, and nothing else.
	if rec.Completed && seat.Place > 0 {
		d.won = seat.Place == 1
		d.lost = seat.Place > 1
	}
	if rec.Completed {
		score := seat.FinalScore
		d.gameScore = &score
		d.handScore = hands.bestScore
	}
	return d
}

// validateRecord rejects a record the schema would reject anyway, but with an
// error naming the field rather than a constraint.
func validateRecord(rec GameRecord) error {
	if !rec.Mode.Valid() {
		return fmt.Errorf("db: %q is not a game mode", rec.Mode)
	}
	if rec.Source != SourceServer && rec.Source != SourceClient {
		return fmt.Errorf("db: %q is not a game source", rec.Source)
	}
	if len(rec.Seats) == 0 {
		return errors.New("db: a game with no seats is not a game")
	}
	seen := make(map[int]struct{}, len(rec.Seats))
	for _, s := range rec.Seats {
		if s.Seat < 0 || s.Seat > 3 {
			return fmt.Errorf("db: seat %d is not at the table", s.Seat)
		}
		if _, dup := seen[s.Seat]; dup {
			return fmt.Errorf("db: seat %d appears twice", s.Seat)
		}
		seen[s.Seat] = struct{}{}
	}
	return nil
}
