package ws

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/nabin31bogati/callbreak/backend/internal/auth"
	"github.com/nabin31bogati/callbreak/backend/internal/config"
	"github.com/nabin31bogati/callbreak/backend/internal/db"
	"github.com/nabin31bogati/callbreak/backend/internal/engine"
	"github.com/nabin31bogati/callbreak/backend/internal/match"
	"github.com/nabin31bogati/callbreak/backend/internal/obs"
	"github.com/nabin31bogati/callbreak/backend/internal/protocol"
	"github.com/nabin31bogati/callbreak/backend/internal/room"
)

// The tests in this package drive the real server over real websockets: the
// only thing faked is the clock, and only by shrinking it. That is deliberate —
// the bugs worth catching here (races between a reconnect and a turn timer,
// stale sockets, half-applied joins) do not reproduce against a mock.

// testStack is a running server plus everything needed to talk to it.
type testStack struct {
	t       *testing.T
	http    *httptest.Server
	hub     *room.Hub
	signer  *auth.Signer
	url     string
	cancel  context.CancelFunc
	clients []*testClient
	mu      sync.Mutex
}

// fastPacing compresses every table clock so a five-hand game runs in
// milliseconds. The ratios between them are preserved.
func fastPacing() room.Pacing {
	return room.Pacing{
		BotThinkMin:     time.Millisecond,
		BotThinkExtra:   time.Millisecond,
		TrickLinger:     time.Millisecond,
		BidTimeout:      2 * time.Second,
		PlayTimeouts:    room.FlatPlayTimeouts(2 * time.Second),
		ReconnectGrace:  2 * time.Second,
		HandAdvanceWait: 500 * time.Millisecond,
		IdleTTL:         5 * time.Second,
		StartCountdown:  10 * time.Millisecond,
		DealGrace:       0,
	}
}

// stackOpts are the pieces main() wires in that most tests do not care about.
// The zero value is the dependency-free server every existing test drives.
type stackOpts struct {
	// recorder persists finished games. Nil means nothing is recorded, which is
	// the no-DATABASE_URL deployment.
	recorder *room.Recorder
	// users resolves device ids to accounts. Nil means seats play exactly the
	// same and their games are recorded with no account.
	users db.Store
}

func newStack(t *testing.T, tune ...func(*config.Config, *room.Pacing)) *testStack {
	t.Helper()
	return newStackWith(t, stackOpts{}, tune...)
}

func newStackWith(t *testing.T, opts stackOpts, tune ...func(*config.Config, *room.Pacing)) *testStack {
	t.Helper()

	cfg := config.Config{
		Addr:             ":0",
		Env:              "test",
		MaxRooms:         100,
		MaxConnsPerIP:    64,
		MsgRatePerSecond: 1000,
		MsgBurst:         1000,
		MatchFillWait:    200 * time.Millisecond,
		MatchMinPlayers:  2,
		StartCountdown:   10 * time.Millisecond,
		JWTSecret:        []byte("test-secret"),
	}
	pacing := fastPacing()
	for _, fn := range tune {
		fn(&cfg, &pacing)
	}

	ctx, cancel := context.WithCancel(context.Background())
	log := slog.New(slog.NewTextHandler(discard{}, &slog.HandlerOptions{Level: slog.LevelError}))

	signer := auth.NewSigner(cfg.JWTSecret)
	hub := room.NewHub(ctx, pacing, signer, log, cfg.MaxRooms)
	// Set before the first table is opened, exactly as main does.
	hub.Recorder = opts.recorder
	matcher := match.New(hub, log, cfg.MatchMinPlayers, cfg.MatchFillWait)

	gateway := NewServer(cfg, hub, matcher, signer, log, obs.NewHealth())
	gateway.Users = opts.users
	mux := http.NewServeMux()
	gateway.Handler(mux)
	server := httptest.NewServer(mux)

	s := &testStack{
		t:      t,
		http:   server,
		hub:    hub,
		signer: signer,
		url:    "ws" + strings.TrimPrefix(server.URL, "http") + "/ws",
		cancel: cancel,
	}
	t.Cleanup(func() {
		s.mu.Lock()
		clients := append([]*testClient(nil), s.clients...)
		s.mu.Unlock()
		for _, c := range clients {
			c.close()
		}
		server.Close()
		hub.CloseAll()
		cancel()
	})
	return s
}

type discard struct{}

func (discard) Write(p []byte) (int, error) { return len(p), nil }

// ------------------------------------------------------------------ client

// frame is a decoded server message, kept as raw JSON so a test can assert on
// exactly what went over the wire.
type frame struct {
	Type string
	Raw  map[string]json.RawMessage
	Data []byte
}

func (f frame) str(key string) string {
	var v string
	_ = json.Unmarshal(f.Raw[key], &v)
	return v
}

func (f frame) num(key string) int {
	var v int
	_ = json.Unmarshal(f.Raw[key], &v)
	return v
}

func (f frame) boolean(key string) bool {
	var v bool
	_ = json.Unmarshal(f.Raw[key], &v)
	return v
}

// testClient is a player. A reader goroutine funnels every frame into a channel
// and keeps the latest view, which is how the driver decides what to do next.
type testClient struct {
	t    *testing.T
	name string
	ws   *websocket.Conn

	frames chan frame
	done   chan struct{}
	once   sync.Once

	mu          sync.Mutex
	seat        int
	view        *engine.View
	guestToken  string
	resumeToken string
	isHost      bool
	readErr     error
}

func (s *testStack) dial(name string) *testClient {
	s.t.Helper()
	socket, _, err := websocket.DefaultDialer.Dial(s.url, nil)
	if err != nil {
		s.t.Fatalf("dial: %v", err)
	}
	c := &testClient{
		t:      s.t,
		name:   name,
		ws:     socket,
		frames: make(chan frame, 512),
		done:   make(chan struct{}),
		seat:   -1,
	}
	go c.read()

	s.mu.Lock()
	s.clients = append(s.clients, c)
	s.mu.Unlock()
	return c
}

func (c *testClient) read() {
	defer close(c.frames)
	for {
		_, data, err := c.ws.ReadMessage()
		if err != nil {
			c.mu.Lock()
			c.readErr = err
			c.mu.Unlock()
			return
		}
		var raw map[string]json.RawMessage
		if err := json.Unmarshal(data, &raw); err != nil {
			continue
		}
		var kind string
		_ = json.Unmarshal(raw["type"], &kind)

		switch kind {
		case protocol.TypeJoined:
			c.mu.Lock()
			_ = json.Unmarshal(raw["seat"], &c.seat)
			_ = json.Unmarshal(raw["guestToken"], &c.guestToken)
			_ = json.Unmarshal(raw["resumeToken"], &c.resumeToken)
			_ = json.Unmarshal(raw["isHost"], &c.isHost)
			c.mu.Unlock()
		case protocol.TypeView:
			var view engine.View
			if err := json.Unmarshal(data, &view); err == nil {
				c.mu.Lock()
				c.view = &view
				c.mu.Unlock()
			}
		}

		select {
		case c.frames <- frame{Type: kind, Raw: raw, Data: data}:
		case <-c.done:
			return
		}
	}
}

func (c *testClient) send(v any) {
	data, err := json.Marshal(v)
	if err != nil {
		c.t.Fatalf("%s: encode: %v", c.name, err)
	}
	if err := c.ws.WriteMessage(websocket.TextMessage, data); err != nil {
		c.t.Fatalf("%s: write: %v", c.name, err)
	}
}

// sendRaw writes bytes straight to the socket, for testing what the server does
// with input its own encoder would never produce.
func (c *testClient) sendRaw(payload string) {
	if err := c.ws.WriteMessage(websocket.TextMessage, []byte(payload)); err != nil {
		c.t.Fatalf("%s: write: %v", c.name, err)
	}
}

// decodeInto is json.Unmarshal, named so the test files read as assertions
// rather than as plumbing.
func decodeInto(data []byte, v any) error { return json.Unmarshal(data, v) }

func (c *testClient) join(roomCode string, extra map[string]any) {
	// The server rejects codes outside its alphabet, which surfaces downstream
	// as an unhelpful "connection closed". Catch it here instead — the
	// alphabet omits I, O, 0 and 1, which is easy to forget when inventing a
	// memorable code for a test.
	if roomCode != protocol.QuickplayRoom && !room.ValidRoomCode(roomCode) {
		c.t.Fatalf("%q is not a valid room code: the alphabet is %s",
			roomCode, room.RoomCodeAlphabet)
	}

	msg := map[string]any{
		"type": protocol.TypeJoin,
		"v":    protocol.Version,
		"room": roomCode,
		"name": c.name,
	}
	for k, v := range extra {
		msg[k] = v
	}
	c.send(msg)
}

func (c *testClient) close() {
	c.once.Do(func() {
		close(c.done)
		_ = c.ws.Close()
	})
}

func (c *testClient) currentSeat() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.seat
}

func (c *testClient) currentView() *engine.View {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.view
}

func (c *testClient) tokens() (guest, resume string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.guestToken, c.resumeToken
}

// await blocks until a frame satisfies match, or the deadline passes.
func (c *testClient) await(d time.Duration, what string, match func(frame) bool) frame {
	c.t.Helper()
	deadline := time.After(d)
	for {
		select {
		case f, ok := <-c.frames:
			if !ok {
				c.mu.Lock()
				err := c.readErr
				c.mu.Unlock()
				c.t.Fatalf("%s: connection closed while waiting for %s (%v)", c.name, what, err)
			}
			if match(f) {
				return f
			}
		case <-deadline:
			c.t.Fatalf("%s: timed out waiting for %s", c.name, what)
		}
	}
}

func (c *testClient) awaitType(d time.Duration, kind string) frame {
	c.t.Helper()
	return c.await(d, kind+" frame", func(f frame) bool { return f.Type == kind })
}

// expectNo asserts that no frame matching the predicate arrives within d.
func (c *testClient) expectNo(d time.Duration, what string, match func(frame) bool) {
	c.t.Helper()
	deadline := time.After(d)
	for {
		select {
		case f, ok := <-c.frames:
			if !ok {
				return
			}
			if match(f) {
				c.t.Fatalf("%s: unexpectedly received %s: %s", c.name, what, f.Data)
			}
		case <-deadline:
			return
		}
	}
}

// ------------------------------------------------------------------- driver

// drive plays the game for a client until the game is over or the deadline
// passes. It only ever sends moves the server told it were legal, so any
// rejection is a genuine server bug rather than a confused test.
func (c *testClient) drive(d time.Duration) *engine.View {
	c.t.Helper()
	deadline := time.After(d)
	for {
		select {
		case f, ok := <-c.frames:
			if !ok {
				c.mu.Lock()
				err := c.readErr
				c.mu.Unlock()
				c.t.Fatalf("%s: connection closed mid-game (%v)", c.name, err)
			}
			switch f.Type {
			case protocol.TypeError:
				if f.boolean("fatal") {
					c.t.Fatalf("%s: fatal error mid-game: %s", c.name, f.Data)
				}
				c.t.Fatalf("%s: server rejected a move it had offered: %s", c.name, f.Data)
			case protocol.TypeView:
				view := c.currentView()
				if view == nil {
					continue
				}
				if view.Phase == engine.PhaseGameOver {
					return view
				}
				c.respond(view)
			}
		case <-deadline:
			c.t.Fatalf("%s: game did not finish in time", c.name)
		}
	}
}

// driveUntilHandOver plays only as far as the first between-hands scoreboard,
// without consenting to move on. It is how the consent tests get a table into
// the state they need to examine.
func (c *testClient) driveUntilHandOver(d time.Duration) *engine.View {
	c.t.Helper()
	deadline := time.After(d)
	for {
		select {
		case f, ok := <-c.frames:
			if !ok {
				c.t.Fatalf("%s: connection closed before the hand ended", c.name)
			}
			if f.Type != protocol.TypeView {
				continue
			}
			view := c.currentView()
			if view == nil {
				continue
			}
			if view.Phase == engine.PhaseHandOver {
				return view
			}
			if view.Phase == engine.PhaseGameOver {
				c.t.Fatal("game ended before a hand-over was observed")
			}
			c.respond(view)
		case <-deadline:
			c.t.Fatalf("%s: no hand finished in time", c.name)
		}
	}
}

// autopilotGuest plays a seated client's moves for it until the game ends or
// the connection closes, from a goroutine of its own. Unlike [drive] it never
// calls t.Fatalf, so it is safe to run off the test goroutine — the quiet
// second human a private table now needs before it can deal.
func autopilotGuest(c *testClient, done chan<- struct{}) {
	defer func() { done <- struct{}{} }()
	for {
		f, ok := <-c.frames
		if !ok {
			return
		}
		if f.Type != protocol.TypeView {
			continue
		}
		v := c.currentView()
		if v == nil {
			continue
		}
		if v.Phase == engine.PhaseGameOver {
			return
		}
		c.respond(v)
	}
}

func (c *testClient) respond(view *engine.View) {
	seat := c.currentSeat()
	switch view.Phase {
	case engine.PhaseBidding:
		if view.Turn != nil && *view.Turn == seat && view.Bids[seat] == nil {
			c.send(map[string]any{"type": protocol.TypeBid, "bid": engine.SuggestBid(view.Hand)})
		}
	case engine.PhasePlaying:
		if view.Turn != nil && *view.Turn == seat && len(view.LegalMoveIDs) > 0 {
			c.send(map[string]any{"type": protocol.TypePlay, "card": view.LegalMoveIDs[0]})
		}
	case engine.PhaseHandOver:
		c.send(map[string]any{"type": protocol.TypeNext})
	}
}
