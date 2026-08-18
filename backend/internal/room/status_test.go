package room

import (
	"context"
	"testing"
	"time"

	"github.com/nabin31bogati/callbreak/backend/internal/auth"
	"github.com/nabin31bogati/callbreak/backend/internal/engine"
	"github.com/nabin31bogati/callbreak/backend/internal/protocol"
)

// fakeClient is the smallest room.Client a test can stand on: it records
// whether it was failed or closed and drops every frame it is sent.
type fakeClient struct {
	player auth.GuestID
	sent   chan []byte
	failed chan struct{}
	closed chan struct{}
}

func newFakeClient(player string) *fakeClient {
	return &fakeClient{
		player: auth.GuestID(player),
		sent:   make(chan []byte, 256),
		failed: make(chan struct{}, 1),
		closed: make(chan struct{}, 1),
	}
}

func (c *fakeClient) Send([]byte)            {}
func (c *fakeClient) Fail(string, string)    { c.failed <- struct{}{} }
func (c *fakeClient) Close(string, string)   { c.closed <- struct{}{} }
func (c *fakeClient) PlayerID() auth.GuestID { return c.player }

// testPacing is a short flat pacing so autostart countdowns fire fast.
func testPacing() Pacing {
	p := DefaultPacing()
	p.StartCountdown = 50 * time.Millisecond
	p.BidTimeout = time.Second
	return p
}

// TestSnapshotLobby checks that a lobby table's status reflects its seats and
// the table's creation-time facts, before any deal has happened.
func TestSnapshotLobby(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	log := quietLogger()

	r := New(ctx, Options{
		ID:         "TEST",
		Mode:       protocol.ModePrivate,
		Pacing:     testPacing(),
		Logger:     log,
		TotalHands: 3,
	})
	defer r.Close()

	st := r.Snapshot()
	if st.ID != "TEST" || st.Mode != protocol.ModePrivate || st.Closed || st.Started {
		t.Fatalf("lobby snapshot wrong: %+v", st)
	}
	if st.Phase != "" || st.HumanSeats != 0 || st.ConnectedHum != 0 {
		t.Fatalf("empty lobby should have no phase or humans: %+v", st)
	}

	alice := newFakeClient("p-alice")
	res := r.Join(JoinRequest{Client: alice, Player: alice.player, Name: "Alice"})
	if res.Err != "" {
		t.Fatalf("join failed: %s %s", res.Err, res.ErrText)
	}
	bob := newFakeClient("p-bob")
	res2 := r.Join(JoinRequest{Client: bob, Player: bob.player, Name: "Bob"})
	if res2.Err != "" {
		t.Fatalf("join failed: %s %s", res2.Err, res2.ErrText)
	}

	st = r.Snapshot()
	if st.HumanSeats != 2 || st.ConnectedHum != 2 {
		t.Fatalf("expected two humans, got %+v", st)
	}
	s := st.Seats[res.Seat]
	if !s.Occupied || s.Name != "Alice" || s.Kind != engine.KindHuman || !s.Connected || s.Player != alice.player {
		t.Fatalf("seat %d wrong: %+v", res.Seat, s)
	}
	if !s.Host {
		t.Fatalf("first joiner should host a private table")
	}
	if st.HostSeat != res.Seat {
		t.Fatalf("hostSeat = %d, want %d", st.HostSeat, res.Seat)
	}
}

// TestSnapshotStarted checks that a dealt table's status carries the engine
// state — phase, a hand per seat, bids and tricks — by letting a quickplay
// table autostart on its countdown.
func TestSnapshotStarted(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	log := quietLogger()

	r := New(ctx, Options{
		ID:         "QP1",
		Mode:       protocol.ModeOnline,
		Pacing:     testPacing(),
		Logger:     log,
		TotalHands: 3,
		AutoStart:  true,
		MinPlayers: 2,
		FillWait:   30 * time.Millisecond,
	})
	defer r.Close()

	alice := newFakeClient("p-alice")
	if res := r.Join(JoinRequest{Client: alice, Player: alice.player, Name: "Alice"}); res.Err != "" {
		t.Fatalf("join failed: %s %s", res.Err, res.ErrText)
	}
	bob := newFakeClient("p-bob")
	if res := r.Join(JoinRequest{Client: bob, Player: bob.player, Name: "Bob"}); res.Err != "" {
		t.Fatalf("join failed: %s %s", res.Err, res.ErrText)
	}

	var st Status
	deadline := time.Now().Add(3 * time.Second)
	for {
		st = r.Snapshot()
		if st.Started {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("table never started: %+v", st)
		}
		time.Sleep(10 * time.Millisecond)
	}

	if st.StartedAt.IsZero() {
		t.Fatalf("started table must carry StartedAt")
	}
	if st.Phase != engine.PhaseBidding && st.Phase != engine.PhasePlaying {
		t.Fatalf("unexpected phase %q", st.Phase)
	}
	if st.HandIndex != 0 {
		t.Fatalf("first hand should be index 0, got %d", st.HandIndex)
	}
	if st.Dealer != 0 {
		t.Fatalf("first dealer should be seat 0, got %d", st.Dealer)
	}
	occupied := 0
	handTotal := 0
	for i := range st.Seats {
		if !st.Seats[i].Occupied {
			continue
		}
		occupied++
		handTotal += len(st.Hands[i])
		if len(st.Hands[i]) == 0 {
			t.Fatalf("seat %d has an empty hand", i)
		}
	}
	if occupied != 4 {
		t.Fatalf("expected bots to fill to 4 seats, got %d", occupied)
	}
	// Every card is dealt to exactly one seat.
	if handTotal != 52 {
		t.Fatalf("52 cards should be dealt across seats, got %d", handTotal)
	}
	if st.Turn == nil {
		t.Fatalf("a bidding table must have a turn")
	}
}

// TestSnapshotClosed checks that Snapshot is safe on a room that is already
// shutting down and reports Closed.
func TestSnapshotClosed(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	log := quietLogger()

	r := New(ctx, Options{
		ID:     "GONE",
		Mode:   protocol.ModePrivate,
		Pacing: testPacing(),
		Logger: log,
	})
	r.Close()
	select {
	case <-r.closed:
	case <-time.After(2 * time.Second):
		t.Fatal("room did not shut down")
	}
	st := r.Snapshot()
	if !st.Closed {
		t.Fatalf("closed room should report Closed: %+v", st)
	}
}
