package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/nabin31bogati/callbreak/backend/internal/auth"
	"github.com/nabin31bogati/callbreak/backend/internal/config"
	"github.com/nabin31bogati/callbreak/backend/internal/db"
	"github.com/nabin31bogati/callbreak/backend/internal/engine"
	"github.com/nabin31bogati/callbreak/backend/internal/protocol"
	"github.com/nabin31bogati/callbreak/backend/internal/room"
	"github.com/nabin31bogati/callbreak/backend/internal/settings"
)

// adminFakeClient is the smallest room.Client the admin tests need.
type adminFakeClient struct{ player string }

func (c *adminFakeClient) Send([]byte)            {}
func (c *adminFakeClient) Fail(string, string)    {}
func (c *adminFakeClient) Close(string, string)   {}
func (c *adminFakeClient) PlayerID() auth.GuestID { return auth.GuestID(c.player) }

type adminHarness struct {
	t      *testing.T
	server *httptest.Server
	hub    *room.Hub
	token  string
}

func adminValues() settings.Values {
	return settings.Values{
		BotThinkMin:     550 * time.Millisecond,
		BotThinkExtra:   450 * time.Millisecond,
		TrickLinger:     1100 * time.Millisecond,
		StartCountdown:  3 * time.Second,
		BidTimeout:      5 * time.Second,
		PlayTimeouts:    [4]time.Duration{10 * time.Second, 8 * time.Second, 6 * time.Second, 5 * time.Second},
		ReconnectGrace:  2 * time.Minute,
		HandAdvanceWait: 5 * time.Second,
		RoomIdleTTL:     5 * time.Minute,
		DealGrace:       3500 * time.Millisecond,
		MatchFillWait:   5 * time.Second,
		MatchMinPlayers: 2,
	}
}

func newAdminHarness(t *testing.T) *adminHarness {
	return newAdminHarnessWithStore(t, db.Nop{})
}

func newAdminHarnessWithStore(t *testing.T, store db.Store) *adminHarness {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	log := slog.New(slog.NewTextHandler(io.Discard, nil))

	hub := room.NewHub(ctx, room.DefaultPacing(), auth.NewSigner([]byte("s")), log, 100)

	live, err := settings.New(adminValues(), nil, log)
	if err != nil {
		t.Fatal(err)
	}

	api := NewServer(config.Config{APIRatePerMinute: 120}, store, auth.NewSigner([]byte("s")), log)
	api.Admin(hub, live, "sekret")

	mux := http.NewServeMux()
	api.Handler(mux)
	ts := httptest.NewServer(mux)
	t.Cleanup(ts.Close)
	return &adminHarness{t: t, server: ts, hub: hub, token: "sekret"}
}

func (h *adminHarness) get(path, token string) (int, map[string]any) {
	t := h.t
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, h.server.URL+path, nil)
	if err != nil {
		t.Fatal(err)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body := map[string]any{}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("bad response body for %s: %v", path, err)
	}
	return resp.StatusCode, body
}

// openRoom creates a live private table with two humans, so the list endpoint
// has something real to show.
func (h *adminHarness) openRoom(t *testing.T, code string) {
	t.Helper()
	r, _, err := h.hub.GetOrCreate(code, protocol.ModePrivate, room.AutoStart{}, 3, engine.DealConfig{})
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range []struct{ id, name string }{{"p-alice", "Alice"}, {"p-bob", "Bob"}} {
		cl := &adminFakeClient{player: p.id}
		if res := r.Join(room.JoinRequest{Client: cl, Player: cl.PlayerID(), Name: p.name}); res.Err != "" {
			t.Fatalf("join failed: %s %s", res.Err, res.ErrText)
		}
	}
}

func TestAdminRequiresToken(t *testing.T) {
	h := newAdminHarness(t)
	for _, path := range []string{"/v1/admin/rooms", "/v1/admin/settings"} {
		status, _ := h.get(path, "")
		if status != http.StatusUnauthorized {
			t.Errorf("%s without a token = %d, want 401", path, status)
		}
	}
	status, _ := h.get("/v1/admin/rooms", "wrong-token")
	if status != http.StatusUnauthorized {
		t.Errorf("wrong token = %d, want 401", status)
	}
}

func TestAdminWithoutTokenDisabled(t *testing.T) {
	// A server that never called Admin mounts none of the routes.
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	mux := http.NewServeMux()
	NewServer(config.Config{APIRatePerMinute: 120}, db.Nop{}, auth.NewSigner([]byte("s")), log).Handler(mux)
	ts := httptest.NewServer(mux)
	t.Cleanup(ts.Close)

	resp, err := http.Get(ts.URL + "/admin")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("/admin on a disabled server = %d, want 404", resp.StatusCode)
	}
}

func TestAdminRoomsList(t *testing.T) {
	h := newAdminHarness(t)
	h.openRoom(t, "ROOM")

	status, body := h.get("/v1/admin/rooms", h.token)
	if status != http.StatusOK {
		t.Fatalf("rooms list = %d", status)
	}
	sum := body["summary"].(map[string]any)
	if sum["rooms"].(float64) != 1 || sum["humans"].(float64) != 2 {
		t.Fatalf("summary wrong: %v", sum)
	}
	rooms := body["rooms"].([]any)
	room := rooms[0].(map[string]any)
	if room["id"] != "ROOM" || room["mode"] != "private" || room["started"] != false {
		t.Fatalf("room row wrong: %v", room)
	}
	seats := room["seats"].([]any)
	if len(seats) != 4 {
		t.Fatalf("expected 4 seat positions, got %d", len(seats))
	}
	occupied := 0
	var alice map[string]any
	for _, s := range seats {
		seat := s.(map[string]any)
		if seat["occupied"].(bool) {
			occupied++
			if seat["name"] == "Alice" {
				alice = seat
			}
		}
	}
	if occupied != 2 {
		t.Fatalf("expected 2 occupied seats, got %d", occupied)
	}
	if alice == nil || alice["kind"] != "human" || alice["connected"] != true {
		t.Fatalf("Alice's seat wrong: %v", alice)
	}
}

func TestAdminRoomDetailMissing(t *testing.T) {
	h := newAdminHarness(t)
	status, body := h.get("/v1/admin/rooms/NOPE", h.token)
	if status != http.StatusNotFound {
		t.Fatalf("missing room = %d, want 404", status)
	}
	if body["error"] == nil {
		t.Fatalf("404 should carry an error envelope")
	}
}

func TestAdminSettingsRoundTrip(t *testing.T) {
	h := newAdminHarness(t)

	status, body := h.get("/v1/admin/settings", h.token)
	if status != http.StatusOK {
		t.Fatalf("settings get = %d", status)
	}
	if body["source"] != "env" {
		t.Fatalf("fresh store should report source env, got %v", body["source"])
	}

	payload := map[string]any{"bidTimeout": "7s", "matchMinPlayers": 3}
	raw, _ := json.Marshal(payload)
	req, err := http.NewRequest(http.MethodPut, h.server.URL+"/v1/admin/settings", bytes.NewReader(raw))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+h.token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var body2 map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&body2); err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("settings put = %d: %v", resp.StatusCode, body2)
	}
	s := body2["settings"].(map[string]any)
	if s["bidTimeout"] != "7s" || s["matchMinPlayers"].(float64) != 3 {
		t.Fatalf("settings not applied: %v", s)
	}
	if body2["source"] != "runtime" {
		t.Fatalf("no persistence should report source runtime, got %v", body2["source"])
	}
	if body2["updatedAt"] == nil {
		t.Fatal("an update should stamp updatedAt")
	}

	// A bad value is rejected without applying anything.
	bad := map[string]any{"bidTimeout": "banana"}
	raw, _ = json.Marshal(bad)
	req, _ = http.NewRequest(http.MethodPut, h.server.URL+"/v1/admin/settings", bytes.NewReader(raw))
	req.Header.Set("Authorization", "Bearer "+h.token)
	req.Header.Set("Content-Type", "application/json")
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("bad duration = %d, want 400", resp.StatusCode)
	}

	status, body = h.get("/v1/admin/settings", h.token)
	if body["settings"].(map[string]any)["bidTimeout"] != "7s" {
		t.Fatalf("rejected update must not change the saved value")
	}
}

// TestAdminGamesList verifies the history list renders recorded games with
// their source and players, and passes the filter through to the store.
func TestAdminGamesList(t *testing.T) {
	store := newFakeStore()
	store.page = db.HistoryPage{Games: []db.GameSummary{{
		GameID:     "018f3a2b-7c41-7b3e-9a10-4f2c8d5e6b71",
		Mode:       db.ModeOnline,
		Source:     db.SourceServer,
		RoomCode:   "K7Q2",
		Completed:  true,
		StartedAt:  time.Date(2026, 8, 10, 9, 10, 0, 0, time.UTC),
		FinishedAt: time.Date(2026, 8, 10, 9, 34, 0, 0, time.UTC),
		HandsTotal: 5,
		Players: []db.GamePlayer{
			{Seat: 0, DisplayName: "Alice", IsBot: false, FinalScore: 13.2, Place: 1},
			{Seat: 1, DisplayName: "Amit", IsBot: true, FinalScore: 6.1, Place: 3},
		},
	}}}
	h := newAdminHarnessWithStore(t, store)

	status, body := h.get("/v1/admin/games?mode=online", h.token)
	if status != http.StatusOK {
		t.Fatalf("games list = %d: %v", status, body)
	}
	if store.lastAdminQuery.Mode != db.ModeOnline {
		t.Fatalf("mode filter not passed to store: %v", store.lastAdminQuery.Mode)
	}
	games := body["games"].([]any)
	if len(games) != 1 {
		t.Fatalf("expected 1 game, got %d", len(games))
	}
	g := games[0].(map[string]any)
	if g["id"] != "018f3a2b-7c41-7b3e-9a10-4f2c8d5e6b71" ||
		g["mode"] != "online" || g["source"] != "server" || g["completed"] != true {
		t.Fatalf("game row wrong: %v", g)
	}
	players := g["players"].([]any)
	if len(players) != 2 {
		t.Fatalf("expected 2 players, got %d", len(players))
	}
	if players[0].(map[string]any)["displayName"] != "Alice" {
		t.Fatalf("first player wrong: %v", players[0])
	}
}

// TestAdminGamesDetail returns the hand-by-hand scoreboard.
func TestAdminGamesDetail(t *testing.T) {
	store := newFakeStore()
	store.detail = db.GameDetail{
		GameSummary: db.GameSummary{
			GameID:     "018f3a2b-7c41-7b3e-9a10-4f2c8d5e6b71",
			Mode:       db.ModeBots,
			Source:     db.SourceClient,
			Completed:  true,
			FinishedAt: time.Date(2026, 8, 10, 9, 34, 0, 0, time.UTC),
			HandsTotal: 1,
		},
		Hands: []db.HandRecord{
			{HandIndex: 0, Seat: 0, Bid: 3, TricksWon: 3, ScoreDelta: 3, RunningTotal: 3},
		},
	}
	h := newAdminHarnessWithStore(t, store)

	status, body := h.get("/v1/admin/games/018f3a2b-7c41-7b3e-9a10-4f2c8d5e6b71", h.token)
	if status != http.StatusOK {
		t.Fatalf("game detail = %d: %v", status, body)
	}
	hands := body["hands"].([]any)
	if len(hands) != 1 {
		t.Fatalf("expected 1 hand row, got %d", len(hands))
	}
	row := hands[0].(map[string]any)
	if row["bid"].(float64) != 3 || row["tricksWon"].(float64) != 3 {
		t.Fatalf("hand row wrong: %v", row)
	}
	if body["game"].(map[string]any)["source"] != "client" {
		t.Fatalf("detail source wrong")
	}
}

// TestAdminGamesBadFilter rejects an unknown mode before the store is touched.
func TestAdminGamesBadFilter(t *testing.T) {
	store := newFakeStore()
	h := newAdminHarnessWithStore(t, store)

	status, body := h.get("/v1/admin/games?mode=nope", h.token)
	if status != http.StatusBadRequest {
		t.Fatalf("bad mode = %d: %v", status, body)
	}
	if store.called("AdminGames") {
		t.Fatal("invalid filter must be rejected before reaching the store")
	}
}

// TestAdminGamesDisabled answers 503 when the store is off.
func TestAdminGamesDisabled(t *testing.T) {
	h := newAdminHarness(t) // db.Nop{} — no persistence
	status, body := h.get("/v1/admin/games", h.token)
	if status != http.StatusServiceUnavailable {
		t.Fatalf("storeless games list = %d: %v", status, body)
	}
}
