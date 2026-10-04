package httpapi

import (
	"math"
	"time"

	"github.com/nabin31bogati/callbreak/backend/internal/db"
)

// This file is the whole of the JSON contract in docs/API.md, in one place.
//
// Every struct here mirrors a block of that document, in the order it appears
// there, and nothing else in the package writes a response body by hand. The
// Godot client decodes exactly these shapes, so a renamed tag is a breaking
// change on two codebases at once — which is precisely why they are collected
// here rather than spread across the handlers.
//
// Two conventions worth stating once:
//
//   - Timestamps are formatted explicitly as RFC 3339 in UTC. time.Time's own
//     marshaller emits nanoseconds and a numeric offset, neither of which the
//     document promises.
//   - Scores are rounded to two decimals on the way out. The column is
//     numeric(6,2), so anything finer is float noise from the round trip.

// ------------------------------------------------------------------ helpers

func rfc3339(t time.Time) string { return t.UTC().Format(time.RFC3339) }

// rfc3339OrNull renders a timestamp that genuinely may not exist yet — a scope
// the player has never played. null says "never"; a zero time formatted as a
// string would say "the year 1".
func rfc3339OrNull(t time.Time) *string {
	if t.IsZero() {
		return nil
	}
	s := rfc3339(t)
	return &s
}

// score clamps a float to the two decimals the schema stores, so 13.199999…
// never reaches a client that will print it verbatim.
func score(f float64) float64 { return math.Round(f*100) / 100 }

// nullableID renders an empty user id as JSON null. A bot seat, and a human the
// server could not attribute to an account, both have no user — and the
// document spells that as null rather than "".
func nullableID(id string) *string {
	if id == "" {
		return nil
	}
	return &id
}

// ------------------------------------------------------------------ objects

// userJSON is the shared `user` object.
type userJSON struct {
	ID          string         `json:"id"`
	DisplayName string         `json:"displayName"`
	IsGuest     bool           `json:"isGuest"`
	AvatarID    string         `json:"avatarId"`
	Country     string         `json:"country"`
	CreatedAt   string         `json:"createdAt"`
	LastSeenAt  string         `json:"lastSeenAt"`
	Identities  []identityJSON `json:"identities"`
}

type identityJSON struct {
	Provider string `json:"provider"`
	LinkedAt string `json:"linkedAt"`
}

func newUserJSON(u db.User, ids []db.Identity) userJSON {
	// Never nil: the account tab iterates this array, and a null would make it
	// null-check something that is always a list.
	out := make([]identityJSON, 0, len(ids))
	for _, id := range ids {
		out = append(out, identityJSON{
			Provider: string(id.Provider),
			LinkedAt: rfc3339(id.CreatedAt),
		})
	}
	return userJSON{
		ID:          u.ID,
		DisplayName: u.DisplayName,
		IsGuest:     u.IsGuest,
		AvatarID:    u.AvatarID,
		Country:     u.Country,
		CreatedAt:   rfc3339(u.CreatedAt),
		LastSeenAt:  rfc3339(u.LastSeenAt),
		Identities:  out,
	}
}

// gameSummaryJSON is the shared `gameSummary` object: one game as one player
// experienced it.
type gameSummaryJSON struct {
	ID         string           `json:"id"`
	Mode       string           `json:"mode"`
	RoomCode   string           `json:"roomCode"`
	Completed  bool             `json:"completed"`
	StartedAt  string           `json:"startedAt"`
	FinishedAt string           `json:"finishedAt"`
	HandsTotal int              `json:"handsTotal"`
	You        gameYouJSON      `json:"you"`
	Players    []gamePlayerJSON `json:"players"`
}

type gameYouJSON struct {
	Seat        int     `json:"seat"`
	FinalScore  float64 `json:"finalScore"`
	Place       int     `json:"place"`
	TotalBid    int     `json:"totalBid"`
	TotalTricks int     `json:"totalTricks"`
}

type gamePlayerJSON struct {
	Seat        int     `json:"seat"`
	UserID      *string `json:"userId"`
	DisplayName string  `json:"displayName"`
	IsBot       bool    `json:"isBot"`
	FinalScore  float64 `json:"finalScore"`
	Place       int     `json:"place"`
}

func newGameSummaryJSON(g db.GameSummary) gameSummaryJSON {
	players := make([]gamePlayerJSON, 0, len(g.Players))
	for _, p := range g.Players {
		players = append(players, gamePlayerJSON{
			Seat:        p.Seat,
			UserID:      nullableID(p.UserID),
			DisplayName: p.DisplayName,
			IsBot:       p.IsBot,
			FinalScore:  score(p.FinalScore),
			Place:       p.Place,
		})
	}
	return gameSummaryJSON{
		ID:         g.GameID,
		Mode:       string(g.Mode),
		RoomCode:   g.RoomCode,
		Completed:  g.Completed,
		StartedAt:  rfc3339(g.StartedAt),
		FinishedAt: rfc3339(g.FinishedAt),
		HandsTotal: g.HandsTotal,
		You: gameYouJSON{
			Seat:        g.Seat,
			FinalScore:  score(g.FinalScore),
			Place:       g.Place,
			TotalBid:    g.TotalBid,
			TotalTricks: g.TotalTricks,
		},
		Players: players,
	}
}

// handJSON is one seat's line on the scoreboard for one hand. The same shape is
// read on upload and written on read, which is what makes a round trip through
// the server lossless.
type handJSON struct {
	HandIndex    int     `json:"handIndex"`
	Seat         int     `json:"seat"`
	Bid          int     `json:"bid"`
	TricksWon    int     `json:"tricksWon"`
	ScoreDelta   float64 `json:"scoreDelta"`
	RunningTotal float64 `json:"runningTotal"`
}

func newHandJSON(h db.HandRecord) handJSON {
	return handJSON{
		HandIndex:    h.HandIndex,
		Seat:         h.Seat,
		Bid:          h.Bid,
		TricksWon:    h.TricksWon,
		ScoreDelta:   score(h.ScoreDelta),
		RunningTotal: score(h.RunningTotal),
	}
}

// statsJSON is one scope's counters. Win rate, average score and bid accuracy
// are absent on purpose: the client derives them, so the two can never
// disagree.
type statsJSON struct {
	Scope            string  `json:"scope"`
	GamesPlayed      int     `json:"gamesPlayed"`
	GamesCompleted   int     `json:"gamesCompleted"`
	GamesWon         int     `json:"gamesWon"`
	GamesLost        int     `json:"gamesLost"`
	BestPlace        int     `json:"bestPlace"`
	HandsPlayed      int     `json:"handsPlayed"`
	TotalBid         int     `json:"totalBid"`
	BidsMade         int     `json:"bidsMade"`
	BidsFailed       int     `json:"bidsFailed"`
	HighestBid       int     `json:"highestBid"`
	TotalTricks      int     `json:"totalTricks"`
	TotalScore       float64 `json:"totalScore"`
	HighestGameScore float64 `json:"highestGameScore"`
	LowestGameScore  float64 `json:"lowestGameScore"`
	HighestHandScore float64 `json:"highestHandScore"`
	CurrentWinStreak int     `json:"currentWinStreak"`
	BestWinStreak    int     `json:"bestWinStreak"`
	// LastPlayedAt is null for a scope that has never been played. Every other
	// field in a never-played row is a meaningful zero; a date is not.
	LastPlayedAt *string `json:"lastPlayedAt"`
}

func newStatsJSON(s db.Stats) statsJSON {
	return statsJSON{
		Scope:            s.Scope,
		GamesPlayed:      s.GamesPlayed,
		GamesCompleted:   s.GamesCompleted,
		GamesWon:         s.GamesWon,
		GamesLost:        s.GamesLost,
		BestPlace:        s.BestPlace,
		HandsPlayed:      s.HandsPlayed,
		TotalBid:         s.TotalBid,
		BidsMade:         s.BidsMade,
		BidsFailed:       s.BidsFailed,
		HighestBid:       s.HighestBid,
		TotalTricks:      s.TotalTricks,
		TotalScore:       score(s.TotalScore),
		HighestGameScore: score(s.HighestGameScore),
		LowestGameScore:  score(s.LowestGameScore),
		HighestHandScore: score(s.HighestHandScore),
		CurrentWinStreak: s.CurrentWinStreak,
		BestWinStreak:    s.BestWinStreak,
		LastPlayedAt:     rfc3339OrNull(s.LastPlayedAt),
	}
}

// ---------------------------------------------------------------- envelopes

// sessionResponse is the body of POST /v1/auth/device, /v1/auth/refresh, and —
// once it exists — a successful /v1/auth/link.
type sessionResponse struct {
	Token     string   `json:"token"`
	ExpiresAt string   `json:"expiresAt"`
	User      userJSON `json:"user"`
}

// restoreResponse is sessionResponse plus what a restore did with the install
// it replaced. Abandoned is set exactly when that install still had games and
// is waiting on a merge-or-discard decision; it is omitted when the install
// had no history (deleted outright) or when the restore was a no-op.
type restoreResponse struct {
	sessionResponse
	Abandoned *abandonedJSON `json:"abandoned,omitempty"`
}

type abandonedJSON struct {
	AccountID string `json:"accountId"`
	Games     int    `json:"games"`
}

type userResponse struct {
	User userJSON `json:"user"`
}

type statsResponse struct {
	Scopes []statsJSON `json:"scopes"`
}

type historyResponse struct {
	Games []gameSummaryJSON `json:"games"`
	// NextCursor is "" on the last page. It is a keyset cursor over
	// (finishedAt, id), opaque to the client, and is passed back verbatim.
	NextCursor string `json:"nextCursor"`
}

type gameResponse struct {
	Game  gameSummaryJSON `json:"game"`
	Hands []handJSON      `json:"hands"`
}

type uploadResponse struct {
	GameID string `json:"gameId"`
	// Duplicate reports that this upload matched a clientGameId already on
	// record and stored nothing new.
	Duplicate bool `json:"duplicate"`
}

// ----------------------------------------------------------------- requests

type deviceAuthRequest struct {
	DeviceID    string `json:"deviceId"`
	DisplayName string `json:"displayName"`
	// Platform is advisory and may be omitted; it is accepted so the client can
	// send it today and have somewhere to land when it is recorded.
	Platform string `json:"platform"`
}

type linkRequest struct {
	IDToken string `json:"idToken"`
}

type restoreRequest struct {
	// The account id shown in the profile's Account tab on the device that
	// owns the history. Restoring re-anchors *this* device to that account.
	AccountID string `json:"accountId"`
}

type patchMeRequest struct {
	// A pointer so an absent field is distinguishable from an empty one: PATCH
	// with no displayName is a malformed request, not a request to be renamed.
	DisplayName *string `json:"displayName"`
}

type uploadRequest struct {
	ClientGameID string           `json:"clientGameId"`
	Mode         string           `json:"mode"`
	Completed    bool             `json:"completed"`
	HandsTotal   int              `json:"handsTotal"`
	StartedAt    string           `json:"startedAt"`
	FinishedAt   string           `json:"finishedAt"`
	Seats        []uploadSeatJSON `json:"seats"`
	Hands        []handJSON       `json:"hands"`
}

type uploadSeatJSON struct {
	Seat int `json:"seat"`
	// IsYou marks the caller's own seat. Exactly one seat may set it, and it is
	// the only seat that gets a user id — a client does not get to write history
	// onto anybody else.
	IsYou bool `json:"isYou"`
	// UserID is not part of the documented request and must always be null or
	// absent. It is decoded only so that a client sending one is told plainly
	// that seat ownership comes from the session, rather than having the field
	// silently dropped and quietly believing it worked.
	UserID        *string `json:"userId"`
	DisplayName   string  `json:"displayName"`
	IsBot         bool    `json:"isBot"`
	BotDifficulty string  `json:"botDifficulty"`
	FinalScore    float64 `json:"finalScore"`
	Place         int     `json:"place"`
	TotalBid      int     `json:"totalBid"`
	TotalTricks   int     `json:"totalTricks"`
	HandsMade     int     `json:"handsMade"`
}
