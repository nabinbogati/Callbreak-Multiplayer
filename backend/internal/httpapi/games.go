package httpapi

import (
	"fmt"
	"net/http"
	"time"

	"github.com/nabin31bogati/callbreak/backend/internal/db"
	"github.com/nabin31bogati/callbreak/backend/internal/protocol"
)

// Upload bounds.
//
// seats is a Call Break table, so 0..3 and no more. handsTotal has no ceiling in
// docs/API.md, but it needs one here: it is multiplied by four to bound the
// hands array, and a client that sends a billion would make that check vacuous.
// A hundred is two decades of the longest format anyone plays.
const (
	maxSeats           = 4
	maxHandsTotal      = 100
	maxClientGameIDLen = 128
	maxDifficultyLen   = 32
)

// handleGame returns one game with its hand-by-hand scoreboard.
//
// The store scopes the lookup to the caller and reports ErrNotFound when they
// did not play in it, so a game id is not a way to read somebody else's
// results. That check lives there rather than here because it is one SQL
// predicate on a table this package cannot see.
func (s *Server) handleGame(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	id := r.PathValue("id")
	if id == "" {
		writeError(w, http.StatusBadRequest, codeBadRequest, "That request needs a game id.")
		return
	}

	detail, err := s.store.Game(ctx, userIDFrom(ctx), id)
	if err != nil {
		storeError(w, s.log, "Game", err)
		return
	}

	hands := make([]handJSON, 0, len(detail.Hands))
	for _, h := range detail.Hands {
		hands = append(hands, newHandJSON(h))
	}

	writeJSON(w, http.StatusOK, gameResponse{
		Game:  newGameSummaryJSON(detail.GameSummary),
		Hands: hands,
	})
}

// handleUpload records a game that was played entirely on the device.
//
// bots and lan games never touch the server while they are played, so the only
// way they reach history is for the device to post the result. That makes this
// the one endpoint where a client controls the whole record, which is why
// validate below is long and why the caller's own seat is taken from the
// session rather than from the payload.
func (s *Server) handleUpload(w http.ResponseWriter, r *http.Request) {
	var req uploadRequest
	if !decodeBody(w, r, maxUploadBody, &req) {
		return
	}

	ctx := r.Context()
	userID := userIDFrom(ctx)

	rec, err := buildGameRecord(req, userID)
	if err != nil {
		writeError(w, http.StatusBadRequest, codeBadRequest, err.Error())
		return
	}

	gameID, duplicate, err := s.store.RecordGame(ctx, rec)
	if err != nil {
		storeError(w, s.log, "RecordGame", err)
		return
	}

	if duplicate {
		// Not an error — the upload queue is meant to retry blindly, so a repeat
		// is the system working. Worth a log line all the same: a client that
		// keeps re-sending a game it has already had a 2xx for is a bug in the
		// queue's drop logic, and this is the only place it would ever show.
		s.log.Info("client re-uploaded an already recorded game",
			"user", userID, "game", gameID, "clientGameId", rec.ClientGameID)
	} else {
		s.log.Debug("recorded client game",
			"user", userID, "game", gameID, "mode", rec.Mode, "hands", len(rec.Hands))
	}

	writeJSON(w, http.StatusOK, uploadResponse{
		GameID:    gameID,
		Duplicate: duplicate,
	})
}

// buildGameRecord validates an upload and turns it into the record to store.
//
// Every rule in the "Rules the server enforces" list in docs/API.md is applied
// here, in that order, and the returned error text is the message the client
// sees. Validation and construction are one function on purpose: the seat that
// gets the caller's user id is decided in the same pass that proves there is
// exactly one of them, so the two cannot drift apart.
func buildGameRecord(req uploadRequest, userID string) (db.GameRecord, error) {
	var zero db.GameRecord

	// Idempotency key. Without it a retry after a timeout would double-count the
	// game, so an upload that omits it is refused rather than quietly recorded
	// as non-idempotent.
	if req.ClientGameID == "" || len(req.ClientGameID) > maxClientGameIDLen {
		return zero, fmt.Errorf("clientGameId is required and must be at most %d characters", maxClientGameIDLen)
	}

	// Only the offline modes may be uploaded. online and private are played on
	// the server, which records them itself; accepting one here would let a
	// client invent a quickplay result.
	mode := db.Mode(req.Mode)
	if mode != db.ModeBots && mode != db.ModeLAN {
		return zero, fmt.Errorf("mode must be bots or lan")
	}

	if req.HandsTotal < 1 || req.HandsTotal > maxHandsTotal {
		return zero, fmt.Errorf("handsTotal must be between 1 and %d", maxHandsTotal)
	}

	startedAt, err := parseUploadTime("startedAt", req.StartedAt)
	if err != nil {
		return zero, err
	}
	finishedAt, err := parseUploadTime("finishedAt", req.FinishedAt)
	if err != nil {
		return zero, err
	}

	if len(req.Seats) < 1 || len(req.Seats) > maxSeats {
		return zero, fmt.Errorf("seats must have between 1 and %d entries", maxSeats)
	}

	seats := make([]db.SeatRecord, 0, len(req.Seats))
	seen := make(map[int]bool, len(req.Seats))
	yours := -1

	for _, seat := range req.Seats {
		if seat.Seat < 0 || seat.Seat >= maxSeats {
			return zero, fmt.Errorf("seat %d is not a seat at this table", seat.Seat)
		}
		if seen[seat.Seat] {
			return zero, fmt.Errorf("seat %d appears more than once", seat.Seat)
		}
		seen[seat.Seat] = true

		// Seat ownership is not negotiable. A payload does not get to name the
		// account behind any seat, including its own: the id comes from the
		// session token below, and anything sent here is refused loudly rather
		// than dropped silently so a client author finds out immediately.
		if seat.UserID != nil && *seat.UserID != "" {
			return zero, fmt.Errorf("seats must not carry a userId; your own seat is taken from your session")
		}
		if seat.IsYou {
			if yours >= 0 {
				return zero, fmt.Errorf("only one seat may be marked isYou")
			}
			yours = seat.Seat
		}
		if len(seat.BotDifficulty) > maxDifficultyLen {
			return zero, fmt.Errorf("botDifficulty is too long")
		}

		name := seat.DisplayName
		if name != "" {
			// Same sanitiser as a socket join, so a name in history reads the
			// same as it did at the table.
			name = protocol.SanitizeName(name)
		}

		seats = append(seats, db.SeatRecord{
			Seat:          seat.Seat,
			UserID:        "", // filled in for the caller's seat only, below.
			DisplayName:   name,
			IsBot:         seat.IsBot,
			BotDifficulty: seat.BotDifficulty,
			FinalScore:    seat.FinalScore,
			Place:         seat.Place,
			TotalBid:      seat.TotalBid,
			TotalTricks:   seat.TotalTricks,
			HandsMade:     seat.HandsMade,
		})
	}

	if yours < 0 {
		return zero, fmt.Errorf("exactly one seat must be marked isYou")
	}

	// The single point where an account is attached to a seat. Every other seat
	// keeps the empty user id it was built with, which the store writes as null:
	// a client cannot write history onto another player.
	for i := range seats {
		if seats[i].Seat == yours {
			seats[i].UserID = userID
			break
		}
	}

	if len(req.Hands) > req.HandsTotal*maxSeats {
		return zero, fmt.Errorf("hands has more entries than handsTotal allows")
	}
	hands := make([]db.HandRecord, 0, len(req.Hands))
	for _, h := range req.Hands {
		if h.HandIndex < 0 || h.HandIndex >= req.HandsTotal {
			return zero, fmt.Errorf("hand index %d is outside this game", h.HandIndex)
		}
		if h.Seat < 0 || h.Seat >= maxSeats {
			return zero, fmt.Errorf("hand seat %d is not a seat at this table", h.Seat)
		}
		hands = append(hands, db.HandRecord{
			HandIndex:    h.HandIndex,
			Seat:         h.Seat,
			Bid:          h.Bid,
			TricksWon:    h.TricksWon,
			ScoreDelta:   h.ScoreDelta,
			RunningTotal: h.RunningTotal,
		})
	}

	return db.GameRecord{
		Mode: mode,
		// The device computed this result, so it is marked as such and is never
		// eligible for anything public. A column rather than an inference.
		Source:       db.SourceClient,
		ClientGameID: req.ClientGameID,
		HandsTotal:   req.HandsTotal,
		Completed:    req.Completed,
		StartedAt:    startedAt,
		FinishedAt:   finishedAt,
		Seats:        seats,
		Hands:        hands,
	}, nil
}

// parseUploadTime accepts an RFC 3339 timestamp, treating an absent one as
// unset. A malformed one is refused: a game with a garbled clock would sort
// wrongly in a history list forever, and the client cannot fix it afterwards.
func parseUploadTime(field, raw string) (time.Time, error) {
	if raw == "" {
		return time.Time{}, nil
	}
	t, err := time.Parse(time.RFC3339, raw)
	if err != nil {
		return time.Time{}, fmt.Errorf("%s must be an RFC 3339 timestamp", field)
	}
	return t.UTC(), nil
}
