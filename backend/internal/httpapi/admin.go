// The admin surface: a live view of every table on this node and the
// runtime-tunable defaults, both gated behind a single token set in the
// environment (config.AdminToken). The whole surface is unmounted when no
// token is configured, so a deployment that never opts in is not exposed.
//
// Unlike the rest of the REST API these routes deliberately do not require a
// database: tables live in memory and settings work in memory too. An operator
// needs the dashboard most exactly when something else has gone wrong.
package httpapi

import (
	"crypto/subtle"
	_ "embed"
	"net/http"
	"time"

	"github.com/nabin31bogati/callbreak/backend/internal/db"
	"github.com/nabin31bogati/callbreak/backend/internal/engine"
	"github.com/nabin31bogati/callbreak/backend/internal/protocol"
	"github.com/nabin31bogati/callbreak/backend/internal/room"
	"github.com/nabin31bogati/callbreak/backend/internal/settings"
)

// admin gates a route behind the configured admin token. The comparison is
// constant-time because the token is a credential an operator typed somewhere;
// timing it must not leak it. Every failure looks the same, so a wrong token
// does not say how close it was.
func (s *Server) admin(next http.HandlerFunc) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token, ok := bearerToken(r)
		if !ok || subtle.ConstantTimeCompare([]byte(token), []byte(s.adminToken)) != 1 {
			writeError(w, http.StatusUnauthorized, codeUnauthorized,
				"That admin token is not valid.")
			return
		}
		next(w, r)
	})
}

// adminPage serves the dashboard itself. The page is a shell; every piece of
// data it shows comes from the API routes above it, so the token protects the
// whole thing rather than just this file.
//
//go:embed admin_ui.html
var adminUI []byte

func (s *Server) adminPage() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("X-Frame-Options", "DENY")
		_, _ = w.Write(adminUI)
	})
}

// -------------------------------------------------------------------- rooms

// handleAdminRooms lists every live table with its full status, plus a small
// summary the dashboard renders as headline cards. One round trip for the
// whole page is worth keeping: a dashboard polls this every few seconds.
func (s *Server) handleAdminRooms(w http.ResponseWriter, r *http.Request) {
	rooms := s.adminHub.Snapshot()

	out := make([]adminRoomJSON, 0, len(rooms))
	sum := adminSummaryJSON{
		ByMode:  map[string]int{},
		ByPhase: map[string]int{},
	}
	for _, rm := range rooms {
		st := rm.Snapshot()
		out = append(out, s.adminRoomJSON(st))

		sum.Rooms++
		sum.ByMode[string(st.Mode)]++
		phase := string(st.Phase)
		if phase == "" {
			phase = "lobby"
		}
		sum.ByPhase[phase]++
		if st.Started {
			sum.Started++
		} else {
			sum.Lobby++
		}
		sum.Humans += st.HumanSeats
		sum.HumansConnected += st.ConnectedHum
		if !st.Started && st.Mode == protocol.ModeOnline {
			sum.QuickplayFilling++
		}
		for i := range st.Seats {
			if st.Seats[i].Occupied && st.Seats[i].Kind == engine.KindBot {
				sum.Bots++
			}
		}
	}

	writeJSON(w, http.StatusOK, adminRoomsResponse{
		Rooms:      out,
		Summary:    sum,
		ServerTime: rfc3339(time.Now()),
	})
}

// handleAdminRoom returns one table's status, for the dashboard's detail pane.
func (s *Server) handleAdminRoom(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	rm, ok := s.adminHub.Get(id)
	if !ok {
		writeError(w, http.StatusNotFound, codeNotFound,
			"No active table has that code.")
		return
	}
	writeJSON(w, http.StatusOK, adminRoomResponse{
		Room:       s.adminRoomJSON(rm.Snapshot()),
		ServerTime: rfc3339(time.Now()),
	})
}

// ----------------------------------------------------------------- settings

// handleAdminSettings reads the current runtime defaults.
func (s *Server) handleAdminSettings(w http.ResponseWriter, r *http.Request) {
	v, source, updated := s.adminSettings.Get()
	writeJSON(w, http.StatusOK, adminSettingsResponse{
		Settings:    newAdminSettingsJSON(v),
		Source:      source,
		UpdatedAt:   rfc3339OrNull(updated),
		Persistence: s.adminSettings.Persisted(),
	})
}

// handleAdminSettingsPut applies a new set of runtime defaults. Missing
// fields keep their current value, so a dashboard can send the whole form or
// one field.
func (s *Server) handleAdminSettingsPut(w http.ResponseWriter, r *http.Request) {
	var req adminSettingsPutRequest
	if !decodeBody(w, r, maxAuthBody, &req) {
		return
	}

	current, _, _ := s.adminSettings.Get()
	next := current

	fields := []struct {
		name string
		raw  *string
		dst  *time.Duration
	}{
		{"botThinkMin", req.BotThinkMin, &next.BotThinkMin},
		{"botThinkExtra", req.BotThinkExtra, &next.BotThinkExtra},
		{"trickLinger", req.TrickLinger, &next.TrickLinger},
		{"startCountdown", req.StartCountdown, &next.StartCountdown},
		{"bidTimeout", req.BidTimeout, &next.BidTimeout},
		{"reconnectGrace", req.ReconnectGrace, &next.ReconnectGrace},
		{"handAdvanceWait", req.HandAdvanceWait, &next.HandAdvanceWait},
		{"roomIdleTTL", req.RoomIdleTTL, &next.RoomIdleTTL},
		{"dealGrace", req.DealGrace, &next.DealGrace},
		{"matchFillWait", req.MatchFillWait, &next.MatchFillWait},
	}
	for _, f := range fields {
		if err := applyDurationField(f.name, f.raw, f.dst); err != nil {
			writeError(w, http.StatusBadRequest, codeBadRequest, err.Error())
			return
		}
	}
	for i, raw := range req.PlayTimeouts {
		if err := applyDurationField("playTimeouts", raw, &next.PlayTimeouts[i]); err != nil {
			writeError(w, http.StatusBadRequest, codeBadRequest, err.Error())
			return
		}
	}
	if req.MatchMinPlayers != nil {
		next.MatchMinPlayers = *req.MatchMinPlayers
	}

	if err := next.Validate(); err != nil {
		writeError(w, http.StatusBadRequest, codeBadRequest, err.Error())
		return
	}
	if err := s.adminSettings.Update(next); err != nil {
		// Validation already passed, so this is a persistence failure — the
		// one thing worth a log line and a 500.
		s.log.Error("could not apply runtime settings", "err", err)
		writeError(w, http.StatusInternalServerError, codeInternal, msgInternal)
		return
	}

	v, source, updated := s.adminSettings.Get()
	writeJSON(w, http.StatusOK, adminSettingsResponse{
		Settings:    newAdminSettingsJSON(v),
		Source:      source,
		UpdatedAt:   rfc3339OrNull(updated),
		Persistence: s.adminSettings.Persisted(),
	})
}

// ------------------------------------------------------------------- history

// handleAdminGames lists recorded games across all accounts, newest first,
// with the same cursor History uses. It is the one admin route that needs the
// database — a game that was never recorded has no history to show, so a
// storeless server answers 503 persistence_disabled like the rest of the API.
func (s *Server) handleAdminGames(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query()

	mode := db.Mode(query.Get("mode"))
	if mode != "" && !mode.Valid() {
		writeError(w, http.StatusBadRequest, codeBadRequest,
			"That is not a game mode. Use bots, private, online or lan.")
		return
	}
	source := db.Source(query.Get("source"))
	if source != "" && source != db.SourceServer && source != db.SourceClient {
		writeError(w, http.StatusBadRequest, codeBadRequest,
			"That is not a game source. Use server or client.")
		return
	}
	limit, err := parseLimit(query.Get("limit"))
	if err != nil {
		writeError(w, http.StatusBadRequest, codeBadRequest,
			"That limit is not a number.")
		return
	}

	page, err := s.store.AdminGames(r.Context(), db.AdminGameQuery{
		Mode:   mode,
		Source: source,
		Limit:  limit,
		Cursor: query.Get("cursor"),
	})
	if err != nil {
		storeError(w, s.log, "AdminGames", err)
		return
	}

	games := make([]adminGameJSON, 0, len(page.Games))
	for _, g := range page.Games {
		games = append(games, newAdminGameJSON(g))
	}
	writeJSON(w, http.StatusOK, adminGamesResponse{
		Games:      games,
		NextCursor: page.NextCursor,
		ServerTime: rfc3339(time.Now()),
	})
}

// handleAdminGame returns one game with its hand-by-hand scoreboard, for the
// dashboard's history detail pane. No player scoping — this is the admin view.
func (s *Server) handleAdminGame(w http.ResponseWriter, r *http.Request) {
	detail, err := s.store.AdminGame(r.Context(), r.PathValue("id"))
	if err != nil {
		storeError(w, s.log, "AdminGame", err)
		return
	}
	hands := make([]handJSON, 0, len(detail.Hands))
	for _, h := range detail.Hands {
		hands = append(hands, newHandJSON(h))
	}
	writeJSON(w, http.StatusOK, adminGameResponse{
		Game:  newAdminGameJSON(detail.GameSummary),
		Hands: hands,
	})
}

// ------------------------------------------------------------------- wiring

// adminRoomJSON converts a room.Status into its wire form. Timestamps that may
// legitimately be absent — a table that has not started, a deadline that is
// not running — become null rather than a fabricated time.
func (s *Server) adminRoomJSON(st room.Status) adminRoomJSON {
	out := adminRoomJSON{
		ID:                 st.ID,
		Mode:               string(st.Mode),
		Closed:             st.Closed,
		Accepting:          st.Accepting,
		Started:            st.Started,
		StartedAt:          rfc3339OrNull(st.StartedAt),
		LastActive:         rfc3339(st.LastActive),
		TotalHands:         st.TotalHands,
		HostSeat:           st.HostSeat,
		Phase:              string(st.Phase),
		HandIndex:          st.HandIndex,
		Dealer:             st.Dealer,
		Turn:               st.Turn,
		TrickNumber:        st.TrickNumber,
		AwaitingTrickClear: st.AwaitingTrickClr,
		LastTrickWinner:    st.LastTrickWinner,
		Trick:              st.Trick,
		Bids:               st.Bids[:],
		TricksWon:          st.TricksWon,
		Totals:             st.Totals,
		RoundScores:        st.RoundScores,
		HandCounts:         st.HandCounts,
		Hands:              st.Hands,
		Rankings:           st.Rankings,
		CountdownAt:        rfc3339OrNull(st.CountdownAt),
		HandAdvanceAt:      rfc3339OrNull(st.HandAdvance),
		IdleCollectAt:      rfc3339OrNull(st.IdleCollect),
		FillWait:           st.FillWait.String(),
		MinPlayers:         st.MinPlayers,
		HumanSeats:         st.HumanSeats,
		ConnectedHum:       st.ConnectedHum,
	}

	out.TurnClock = adminDeadlineJSON{
		At:   rfc3339OrNull(st.TurnClock.At),
		Kind: st.TurnClock.Kind,
		Seat: st.TurnClock.Seat,
	}
	out.Pacing = adminPacingJSON{
		BotThinkMin:     st.Pacing.BotThinkMin.String(),
		BotThinkExtra:   st.Pacing.BotThinkExtra.String(),
		TrickLinger:     st.Pacing.TrickLinger.String(),
		BidTimeout:      st.Pacing.BidTimeout.String(),
		PlayTimeouts:    [4]string{st.Pacing.PlayTimeouts[0].String(), st.Pacing.PlayTimeouts[1].String(), st.Pacing.PlayTimeouts[2].String(), st.Pacing.PlayTimeouts[3].String()},
		ReconnectGrace:  st.Pacing.ReconnectGrace.String(),
		HandAdvanceWait: st.Pacing.HandAdvanceWait.String(),
		IdleTTL:         st.Pacing.IdleTTL.String(),
		StartCountdown:  st.Pacing.StartCountdown.String(),
		DealGrace:       st.Pacing.DealGrace.String(),
	}

	out.Seats = make([]adminSeatJSON, 0, 4)
	for i := range st.Seats {
		seat := st.Seats[i]
		hand := st.Hands[i]
		if hand == nil {
			hand = []string{}
		}
		roundScores := st.RoundScores[i]
		if roundScores == nil {
			roundScores = []float64{}
		}
		out.Seats = append(out.Seats, adminSeatJSON{
			Seat:        seat.Seat,
			Occupied:    seat.Occupied,
			Name:        seat.Name,
			Kind:        string(seat.Kind),
			Difficulty:  string(seat.Difficulty),
			Connected:   seat.Connected,
			Autoplay:    seat.Autoplay,
			PlayerID:    string(seat.Player),
			UserID:      seat.UserID,
			IsHost:      seat.Host,
			GraceUntil:  rfc3339OrNull(seat.GraceUntil),
			Hand:        hand,
			Bid:         st.Bids[i],
			TricksWon:   st.TricksWon[i],
			TotalScore:  score(st.Totals[i]),
			RoundScores: roundScores,
		})
	}
	return out
}

// applyDurationField applies a request field to one duration, explaining which
// field was wrong when the value does not parse. A nil field is "leave alone".
func applyDurationField(name string, raw *string, dst *time.Duration) error {
	if raw == nil {
		return nil
	}
	d, err := time.ParseDuration(*raw)
	if err != nil {
		return &badFieldError{name: name}
	}
	*dst = d
	return nil
}

type badFieldError struct{ name string }

func (e *badFieldError) Error() string {
	return e.name + " is not a duration (use forms like 5s, 250ms)."
}

// --------------------------------------------------------------- wire types
//
// The admin wire types live with the admin handlers rather than in wire.go:
// they are the dashboard's contract, and the two were written together.

// adminRoomsResponse and its friends describe the live-table surface.
type adminRoomsResponse struct {
	Rooms      []adminRoomJSON  `json:"rooms"`
	Summary    adminSummaryJSON `json:"summary"`
	ServerTime string           `json:"serverTime"`
}

type adminRoomResponse struct {
	Room       adminRoomJSON `json:"room"`
	ServerTime string        `json:"serverTime"`
}

type adminSummaryJSON struct {
	Rooms            int            `json:"rooms"`
	Started          int            `json:"started"`
	Lobby            int            `json:"lobby"`
	Humans           int            `json:"humans"`
	Bots             int            `json:"bots"`
	HumansConnected  int            `json:"humansConnected"`
	QuickplayFilling int            `json:"quickplayFilling"`
	ByMode           map[string]int `json:"byMode"`
	ByPhase          map[string]int `json:"byPhase"`
}

type adminRoomJSON struct {
	ID                 string               `json:"id"`
	Mode               string               `json:"mode"`
	Closed             bool                 `json:"closed"`
	Accepting          bool                 `json:"accepting"`
	Started            bool                 `json:"started"`
	StartedAt          *string              `json:"startedAt"`
	LastActive         string               `json:"lastActive"`
	TotalHands         int                  `json:"totalHands"`
	HostSeat           int                  `json:"hostSeat"`
	Phase              string               `json:"phase"`
	HandIndex          int                  `json:"handIndex"`
	Dealer             int                  `json:"dealer"`
	Turn               *int                 `json:"turn"`
	TrickNumber        int                  `json:"trickNumber"`
	AwaitingTrickClear bool                 `json:"awaitingTrickClear"`
	LastTrickWinner    *int                 `json:"lastTrickWinner"`
	Trick              []engine.TrickPlay   `json:"trick"`
	Bids               []*int               `json:"bids"`
	TricksWon          [4]int               `json:"tricksWon"`
	Totals             [4]float64           `json:"totals"`
	RoundScores        [4][]float64         `json:"roundScores"`
	HandCounts         [4]int               `json:"handCounts"`
	Hands              [4][]string          `json:"hands"`
	Rankings           []engine.SeatRanking `json:"rankings"`
	TurnClock          adminDeadlineJSON    `json:"turnClock"`
	CountdownAt        *string              `json:"countdownAt"`
	HandAdvanceAt      *string              `json:"handAdvanceAt"`
	IdleCollectAt      *string              `json:"idleCollectAt"`
	Seats              []adminSeatJSON      `json:"seats"`
	Pacing             adminPacingJSON      `json:"pacing"`
	FillWait           string               `json:"fillWait"`
	MinPlayers         int                  `json:"minPlayers"`
	HumanSeats         int                  `json:"humanSeats"`
	ConnectedHum       int                  `json:"connectedHumans"`
}

type adminDeadlineJSON struct {
	At   *string `json:"at"`
	Kind string  `json:"kind"`
	Seat int     `json:"seat"`
}

type adminSeatJSON struct {
	Seat        int       `json:"seat"`
	Occupied    bool      `json:"occupied"`
	Name        string    `json:"name"`
	Kind        string    `json:"kind"`
	Difficulty  string    `json:"difficulty"`
	Connected   bool      `json:"connected"`
	Autoplay    bool      `json:"autoplay"`
	PlayerID    string    `json:"playerId"`
	UserID      string    `json:"userId"`
	IsHost      bool      `json:"isHost"`
	GraceUntil  *string   `json:"graceUntil"`
	Hand        []string  `json:"hand"`
	Bid         *int      `json:"bid"`
	TricksWon   int       `json:"tricksWon"`
	TotalScore  float64   `json:"totalScore"`
	RoundScores []float64 `json:"roundScores"`
}

type adminPacingJSON struct {
	BotThinkMin     string    `json:"botThinkMin"`
	BotThinkExtra   string    `json:"botThinkExtra"`
	TrickLinger     string    `json:"trickLinger"`
	BidTimeout      string    `json:"bidTimeout"`
	PlayTimeouts    [4]string `json:"playTimeouts"`
	ReconnectGrace  string    `json:"reconnectGrace"`
	HandAdvanceWait string    `json:"handAdvanceWait"`
	IdleTTL         string    `json:"idleTTL"`
	StartCountdown  string    `json:"startCountdown"`
	DealGrace       string    `json:"dealGrace"`
}

type adminSettingsResponse struct {
	Settings    adminSettingsJSON `json:"settings"`
	Source      string            `json:"source"`
	UpdatedAt   *string           `json:"updatedAt"`
	Persistence bool              `json:"persistence"`
}

type adminSettingsJSON struct {
	BotThinkMin     string    `json:"botThinkMin"`
	BotThinkExtra   string    `json:"botThinkExtra"`
	TrickLinger     string    `json:"trickLinger"`
	StartCountdown  string    `json:"startCountdown"`
	BidTimeout      string    `json:"bidTimeout"`
	PlayTimeouts    [4]string `json:"playTimeouts"`
	ReconnectGrace  string    `json:"reconnectGrace"`
	HandAdvanceWait string    `json:"handAdvanceWait"`
	RoomIdleTTL     string    `json:"roomIdleTTL"`
	DealGrace       string    `json:"dealGrace"`
	MatchFillWait   string    `json:"matchFillWait"`
	MatchMinPlayers int       `json:"matchMinPlayers"`
}

func newAdminSettingsJSON(v settings.Values) adminSettingsJSON {
	return adminSettingsJSON{
		BotThinkMin:     v.BotThinkMin.String(),
		BotThinkExtra:   v.BotThinkExtra.String(),
		TrickLinger:     v.TrickLinger.String(),
		StartCountdown:  v.StartCountdown.String(),
		BidTimeout:      v.BidTimeout.String(),
		PlayTimeouts:    [4]string{v.PlayTimeouts[0].String(), v.PlayTimeouts[1].String(), v.PlayTimeouts[2].String(), v.PlayTimeouts[3].String()},
		ReconnectGrace:  v.ReconnectGrace.String(),
		HandAdvanceWait: v.HandAdvanceWait.String(),
		RoomIdleTTL:     v.RoomIdleTTL.String(),
		DealGrace:       v.DealGrace.String(),
		MatchFillWait:   v.MatchFillWait.String(),
		MatchMinPlayers: v.MatchMinPlayers,
	}
}

// adminSettingsPutRequest is a PATCH-by-field set: every field is a pointer,
// and a field that is absent keeps its current value.
type adminSettingsPutRequest struct {
	BotThinkMin     *string    `json:"botThinkMin"`
	BotThinkExtra   *string    `json:"botThinkExtra"`
	TrickLinger     *string    `json:"trickLinger"`
	StartCountdown  *string    `json:"startCountdown"`
	BidTimeout      *string    `json:"bidTimeout"`
	PlayTimeouts    [4]*string `json:"playTimeouts"`
	ReconnectGrace  *string    `json:"reconnectGrace"`
	HandAdvanceWait *string    `json:"handAdvanceWait"`
	RoomIdleTTL     *string    `json:"roomIdleTTL"`
	DealGrace       *string    `json:"dealGrace"`
	MatchFillWait   *string    `json:"matchFillWait"`
	MatchMinPlayers *int       `json:"matchMinPlayers"`
}

// adminGameJSON is one recorded game for the admin history list: the same
// facts as gameSummaryJSON plus the source, so the dashboard can tell a
// server-scored game from a device upload.
type adminGameJSON struct {
	ID         string           `json:"id"`
	Mode       string           `json:"mode"`
	Source     string           `json:"source"`
	RoomCode   string           `json:"roomCode"`
	Completed  bool             `json:"completed"`
	StartedAt  string           `json:"startedAt"`
	FinishedAt string           `json:"finishedAt"`
	HandsTotal int              `json:"handsTotal"`
	Players    []gamePlayerJSON `json:"players"`
}

func newAdminGameJSON(g db.GameSummary) adminGameJSON {
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
	return adminGameJSON{
		ID:         g.GameID,
		Mode:       string(g.Mode),
		Source:     string(g.Source),
		RoomCode:   g.RoomCode,
		Completed:  g.Completed,
		StartedAt:  rfc3339(g.StartedAt),
		FinishedAt: rfc3339(g.FinishedAt),
		HandsTotal: g.HandsTotal,
		Players:    players,
	}
}

type adminGamesResponse struct {
	Games      []adminGameJSON `json:"games"`
	NextCursor string          `json:"nextCursor"`
	ServerTime string          `json:"serverTime"`
}

type adminGameResponse struct {
	Game  adminGameJSON `json:"game"`
	Hands []handJSON    `json:"hands"`
}
