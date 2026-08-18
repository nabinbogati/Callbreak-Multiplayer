package ws

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"

	"github.com/nabin31bogati/callbreak/backend/internal/config"
	"github.com/nabin31bogati/callbreak/backend/internal/db"
	"github.com/nabin31bogati/callbreak/backend/internal/engine"
	"github.com/nabin31bogati/callbreak/backend/internal/protocol"
	"github.com/nabin31bogati/callbreak/backend/internal/room"
)

// These tests drive real tables over real websockets, exactly like the rest of
// this package, and assert on what reached the store. Nothing here talks to
// Postgres: the store is a fake, because the property under test is what the
// room actor produces and when, not how a row is written.

// recordingStore is a db.Store that keeps whatever it is asked to record.
// Embedding db.Nop supplies the methods these tests never call.
type recordingStore struct {
	db.Nop

	mu       sync.Mutex
	games    []db.GameRecord
	disabled bool
	// users maps a device id to the account it resolves to.
	users map[string]string
	// resolveDelay stalls identity resolution, to prove a join does not wait on
	// it.
	resolveDelay time.Duration
	resolveErr   error
}

func (s *recordingStore) Enabled() bool { return !s.disabled }

func (s *recordingStore) RecordGame(_ context.Context, rec db.GameRecord) (string, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.games = append(s.games, rec)
	return "game-id", false, nil
}

func (s *recordingStore) ResolveIdentity(ctx context.Context, provider db.Provider, subject, name string) (db.User, error) {
	if s.resolveDelay > 0 {
		select {
		case <-time.After(s.resolveDelay):
		case <-ctx.Done():
			return db.User{}, ctx.Err()
		}
	}
	if s.resolveErr != nil {
		return db.User{}, s.resolveErr
	}
	if provider != db.ProviderDevice {
		return db.User{}, db.ErrNotFound
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.users == nil {
		s.users = map[string]string{}
	}
	id, ok := s.users[subject]
	if !ok {
		id = "user-" + subject
		s.users[subject] = id
	}
	return db.User{ID: id, DisplayName: name, IsGuest: true}, nil
}

func (s *recordingStore) recorded() []db.GameRecord {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]db.GameRecord(nil), s.games...)
}

// awaitRecords waits for the write-behind recorder to catch up. Recording is
// asynchronous by design, so a test that asserts immediately is asserting on a
// race rather than on behaviour.
func awaitRecords(t *testing.T, store *recordingStore, want int, d time.Duration) []db.GameRecord {
	t.Helper()
	deadline := time.Now().Add(d)
	for {
		got := store.recorded()
		if len(got) >= want {
			return got
		}
		if time.Now().After(deadline) {
			t.Fatalf("timed out with %d game records, want %d", len(got), want)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func testLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelError + 1}))
}

// newRecordingStack is a server with persistence on, and a recorder that is
// drained at the end of the test so nothing is left in flight.
func newRecordingStack(t *testing.T, store *recordingStore, tune ...func(*config.Config, *room.Pacing)) *testStack {
	t.Helper()
	recorder := room.NewRecorder(store, testLogger())
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = recorder.Shutdown(ctx)
	})
	return newStackWith(t, stackOpts{recorder: recorder, users: store}, tune...)
}

// hostAPrivateGame seats two humans at a private table — it takes at least two
// to deal — and starts the game. Only the host is returned; the partner is
// driven by an autopilot goroutine so the table can play to a finish.
func hostAPrivateGame(t *testing.T, s *testStack, code string, extra map[string]any) *testClient {
	t.Helper()
	host := s.dial("Nabin")
	if extra == nil {
		extra = map[string]any{}
	}
	// The joiner is the room's creator; a plain join would be rejected now that
	// only an explicit create opens a fresh table.
	extra["create"] = true
	host.join(code, extra)
	host.awaitType(2*time.Second, protocol.TypeJoined)

	guest := s.dial("guest")
	guest.join(code, nil)
	guest.awaitType(2*time.Second, protocol.TypeJoined)

	host.await(2*time.Second, "a startable lobby", func(f frame) bool {
		return f.Type == protocol.TypeLobby && f.boolean("canStart")
	})
	host.send(map[string]any{"type": protocol.TypeStart})
	host.awaitType(2*time.Second, protocol.TypeView)

	go autopilotGuest(guest, make(chan struct{}))
	return host
}

// TestServerGameIsRecordedOnce is the main path: a private table played to the
// last hand produces exactly one record, with the scoreboard the players saw.
func TestServerGameIsRecordedOnce(t *testing.T) {
	store := &recordingStore{}
	s := newRecordingStack(t, store)

	host := hostAPrivateGame(t, s, "7QF2", nil)
	final := host.drive(20 * time.Second)
	if final.Phase != engine.PhaseGameOver {
		t.Fatalf("game ended in phase %q", final.Phase)
	}

	records := awaitRecords(t, store, 1, 5*time.Second)
	if len(records) != 1 {
		t.Fatalf("recorded %d games, want exactly 1", len(records))
	}
	rec := records[0]

	if !rec.Completed {
		t.Error("a game played to the final hand must be recorded as completed")
	}
	if rec.Mode != db.ModePrivate {
		t.Errorf("mode = %q, want %q", rec.Mode, db.ModePrivate)
	}
	if rec.Source != db.SourceServer {
		t.Errorf("source = %q, want %q", rec.Source, db.SourceServer)
	}
	if rec.RoomCode != "7QF2" {
		t.Errorf("room code = %q, want 7QF2", rec.RoomCode)
	}
	if rec.ClientGameID != "" {
		t.Errorf("clientGameID = %q, want empty: a server game is not an upload", rec.ClientGameID)
	}
	if rec.StartedAt.IsZero() || rec.FinishedAt.Before(rec.StartedAt) {
		t.Errorf("timestamps are wrong: started %v, finished %v", rec.StartedAt, rec.FinishedAt)
	}
	if rec.HandsTotal != engine.HandsPerGame {
		t.Errorf("handsTotal = %d, want %d", rec.HandsTotal, engine.HandsPerGame)
	}

	// ---- seats ----
	if len(rec.Seats) != 4 {
		t.Fatalf("recorded %d seats, want 4", len(rec.Seats))
	}
	places := map[int]bool{}
	humans, bots := 0, 0
	wantNames := map[int]string{0: "Nabin", 1: "guest"}
	for i, seat := range rec.Seats {
		if seat.Seat != i {
			t.Errorf("seats are out of order: index %d holds seat %d", i, seat.Seat)
		}
		if got, want := seat.FinalScore, final.Totals[i]; got != want {
			t.Errorf("seat %d final score = %v, want %v (the engine's total)", i, got, want)
		}
		if seat.Place < 1 || seat.Place > 4 {
			t.Errorf("seat %d has place %d, want 1..4", i, seat.Place)
		}
		places[seat.Place] = true
		if seat.IsBot {
			bots++
			if seat.BotDifficulty == "" {
				t.Errorf("bot on seat %d has no difficulty", i)
			}
			if seat.UserID != "" {
				t.Errorf("bot on seat %d carries account %q", i, seat.UserID)
			}
		} else {
			humans++
			if want, ok := wantNames[i]; ok && seat.DisplayName != want {
				t.Errorf("human on seat %d is named %q, want %q", i, seat.DisplayName, want)
			}
		}
	}
	if humans != 2 || bots != 2 {
		t.Errorf("recorded %d humans and %d bots, want 2 and 2", humans, bots)
	}
	if len(places) != 4 {
		t.Errorf("places are not 1..4: %v", places)
	}

	// The placings must agree with the ranking the players were shown.
	for _, rank := range final.Rankings {
		if got := rec.Seats[rank.Seat].Place; got != rank.Place {
			t.Errorf("seat %d recorded place %d, but the table ranked it %d",
				rank.Seat, got, rank.Place)
		}
	}

	// ---- per-hand scoreboard ----
	if got, want := len(rec.Hands), 4*engine.HandsPerGame; got != want {
		t.Fatalf("recorded %d hand rows, want %d", got, want)
	}
	running := [4]float64{}
	seen := map[[2]int]bool{}
	for _, hand := range rec.Hands {
		key := [2]int{hand.HandIndex, hand.Seat}
		if seen[key] {
			t.Fatalf("hand %d seat %d appears twice", hand.HandIndex, hand.Seat)
		}
		seen[key] = true
		if hand.HandIndex < 0 || hand.HandIndex >= engine.HandsPerGame {
			t.Fatalf("hand index %d out of range", hand.HandIndex)
		}
		if got, want := hand.ScoreDelta, final.RoundScores[hand.Seat][hand.HandIndex]; got != want {
			t.Errorf("hand %d seat %d delta = %v, want %v",
				hand.HandIndex, hand.Seat, got, want)
		}
		running[hand.Seat] = engine.Round1(running[hand.Seat] + hand.ScoreDelta)
		if hand.RunningTotal != running[hand.Seat] {
			t.Errorf("hand %d seat %d running total = %v, want %v",
				hand.HandIndex, hand.Seat, hand.RunningTotal, running[hand.Seat])
		}
	}
	for seat := 0; seat < 4; seat++ {
		if running[seat] != final.Totals[seat] {
			t.Errorf("seat %d hand rows sum to %v, but the game ended on %v",
				seat, running[seat], final.Totals[seat])
		}
	}

	// ---- trick detail ----
	if got, want := len(rec.Tricks), engine.HandsPerGame*engine.TricksPerHand; got != want {
		t.Errorf("recorded %d tricks, want %d", got, want)
	}
	for _, trick := range rec.Tricks {
		if len(trick.Plays) != 4 {
			t.Fatalf("hand %d trick %d has %d plays, want 4",
				trick.HandIndex, trick.TrickNumber, len(trick.Plays))
		}
		if trick.LeadSeat != trick.Plays[0].Seat {
			t.Errorf("hand %d trick %d leads with seat %d but the first play is seat %d",
				trick.HandIndex, trick.TrickNumber, trick.LeadSeat, trick.Plays[0].Seat)
		}
	}
}

// TestRestartRecordsASecondGameNotTwo is the double-count guard. Restarting
// after a game over must add one record, and the new game must start from a
// clean scoreboard rather than inheriting the previous one's hands.
func TestRestartRecordsASecondGameNotTwo(t *testing.T) {
	store := &recordingStore{}
	s := newRecordingStack(t, store)

	host := hostAPrivateGame(t, s, "7QF3", nil)
	first := host.drive(20 * time.Second)
	if first.Phase != engine.PhaseGameOver {
		t.Fatalf("first game ended in phase %q", first.Phase)
	}
	firstBatch := awaitRecords(t, store, 1, 5*time.Second)
	if len(firstBatch) != 1 {
		t.Fatalf("the first game produced %d records, want 1", len(firstBatch))
	}

	host.send(map[string]any{"type": protocol.TypeRestart})
	second := host.drive(20 * time.Second)
	if second.Phase != engine.PhaseGameOver {
		t.Fatalf("the restarted game ended in phase %q", second.Phase)
	}

	records := awaitRecords(t, store, 2, 5*time.Second)
	// Give any spurious extra write a moment to show up before declaring the
	// count correct.
	time.Sleep(200 * time.Millisecond)
	records = store.recorded()
	if len(records) != 2 {
		t.Fatalf("two games produced %d records, want exactly 2", len(records))
	}

	for i, rec := range records {
		if !rec.Completed {
			t.Errorf("record %d is not marked completed", i)
		}
		if got, want := len(rec.Hands), 4*engine.HandsPerGame; got != want {
			t.Errorf("record %d has %d hand rows, want %d — a restart must start "+
				"from a clean scoreboard", i, got, want)
		}
	}

	// The second record is the second game, not a re-send of the first.
	if !records[1].StartedAt.After(records[0].StartedAt) {
		t.Errorf("the restarted game starts at %v, not after the first's %v",
			records[1].StartedAt, records[0].StartedAt)
	}
	for seat := 0; seat < 4; seat++ {
		if got, want := records[1].Seats[seat].FinalScore, second.Totals[seat]; got != want {
			t.Errorf("second record seat %d scored %v, want %v", seat, got, want)
		}
	}
}

// TestAbandonedGameIsRecordedIncomplete covers §2.3: a table that closes
// mid-game still owes its players a row, marked as unfinished.
func TestAbandonedGameIsRecordedIncomplete(t *testing.T) {
	store := &recordingStore{}
	// A long scoreboard wait keeps the table parked between hands rather than
	// dealing on without us.
	s := newRecordingStack(t, store, func(_ *config.Config, p *room.Pacing) {
		p.HandAdvanceWait = 30 * time.Second
	})

	host := hostAPrivateGame(t, s, "7QF4", nil)
	view := host.driveUntilHandOver(20 * time.Second)
	if view.HandIndex != 0 {
		t.Fatalf("stopped on hand %d, want the first", view.HandIndex)
	}

	// The whole table goes away mid-game, which is the rage-quit case.
	s.hub.CloseAll()

	records := awaitRecords(t, store, 1, 5*time.Second)
	if len(records) != 1 {
		t.Fatalf("an abandoned game produced %d records, want 1", len(records))
	}
	rec := records[0]

	if rec.Completed {
		t.Error("a game that never reached a final scoreboard must not be marked completed")
	}
	if got, want := len(rec.Hands), 4; got != want {
		t.Errorf("recorded %d hand rows, want %d: the one hand that finished", got, want)
	}
	if rec.HandsTotal != 1 {
		t.Errorf("handsTotal = %d, want 1", rec.HandsTotal)
	}
	if len(rec.Seats) != 4 {
		t.Fatalf("recorded %d seats, want 4", len(rec.Seats))
	}
	for _, seat := range rec.Seats {
		if seat.Place != 0 {
			t.Errorf("seat %d has place %d; an abandoned game ranks nobody",
				seat.Seat, seat.Place)
		}
	}
	if rec.FinishedAt.IsZero() {
		t.Error("finishedAt must be set when the table closes")
	}
}

// TestGameNeverDealtIsNotRecorded: a lobby that closes without a deal is not a
// game and must not appear in anyone's history.
func TestGameNeverDealtIsNotRecorded(t *testing.T) {
	store := &recordingStore{}
	s := newRecordingStack(t, store)

	host := s.dial("Nabin")
	host.join("7QF5", map[string]any{"create": true})
	host.awaitType(2*time.Second, protocol.TypeJoined)
	host.awaitType(2*time.Second, protocol.TypeLobby)

	s.hub.CloseAll()
	time.Sleep(200 * time.Millisecond)

	if got := store.recorded(); len(got) != 0 {
		t.Fatalf("a table that never dealt recorded %d games, want 0", len(got))
	}
}

// TestNoPersistenceConfiguredPlaysNormally is the airtight case: with no store
// at all a full game runs exactly as it always has. Any nil dereference in the
// recording path lands here.
func TestNoPersistenceConfiguredPlaysNormally(t *testing.T) {
	cases := map[string]stackOpts{
		"no recorder at all": {},
		"recorder over a disabled store": {
			recorder: room.NewRecorder(&recordingStore{disabled: true}, testLogger()),
			users:    &recordingStore{disabled: true},
		},
		"recorder over db.Nop": {
			recorder: room.NewRecorder(db.Nop{}, testLogger()),
			users:    db.Nop{},
		},
	}

	for name, opts := range cases {
		t.Run(name, func(t *testing.T) {
			s := newStackWith(t, opts)

			host := hostAPrivateGame(t, s, "7QF6", map[string]any{
				"deviceId": "device-abcdef123456",
			})
			final := host.drive(20 * time.Second)
			if final.Phase != engine.PhaseGameOver {
				t.Fatalf("game ended in phase %q", final.Phase)
			}

			// And a restart, because that is the other path into the recorder.
			host.send(map[string]any{"type": protocol.TypeRestart})
			again := host.drive(20 * time.Second)
			if again.Phase != engine.PhaseGameOver {
				t.Fatalf("the restarted game ended in phase %q", again.Phase)
			}
		})
	}
}

// TestSeatIsAttributedToAnAccount is §4.1 end to end: a device id on the join
// frame becomes a user id on the seat's row in the recorded game.
func TestSeatIsAttributedToAnAccount(t *testing.T) {
	store := &recordingStore{}
	s := newRecordingStack(t, store)

	host := hostAPrivateGame(t, s, "7QF7", map[string]any{
		"deviceId": "device-abcdef123456",
	})
	if final := host.drive(20 * time.Second); final.Phase != engine.PhaseGameOver {
		t.Fatalf("game ended in phase %q", final.Phase)
	}

	records := awaitRecords(t, store, 1, 5*time.Second)
	seat := records[0].Seats[0]
	if seat.IsBot {
		t.Fatal("seat 0 is the human host")
	}
	if want := "user-device-abcdef123456"; seat.UserID != want {
		t.Fatalf("seat 0 user id = %q, want %q", seat.UserID, want)
	}
}

// TestSlowIdentityLookupDoesNotDelayTheJoin is the ordering guarantee from
// §4.1: identity is an enrichment of the session, never a precondition. A
// database that takes longer than the whole join must not be felt by the
// player, and the answer still lands on the seat afterwards.
func TestSlowIdentityLookupDoesNotDelayTheJoin(t *testing.T) {
	const lookupDelay = 400 * time.Millisecond
	store := &recordingStore{resolveDelay: lookupDelay}
	s := newRecordingStack(t, store)

	host := s.dial("Nabin")
	start := time.Now()
	host.join("7QF8", map[string]any{"deviceId": "device-abcdef123456", "create": true})
	host.awaitType(2*time.Second, protocol.TypeJoined)
	seated := time.Since(start)

	if seated >= lookupDelay {
		t.Fatalf("the join took %v with a %v account lookup in front of it; "+
			"seating must not wait on the database", seated, lookupDelay)
	}

	// The late answer still reaches the seat, so the game is attributed. A
	// private table needs two humans to deal, so the host brings a partner.
	guest := s.dial("guest")
	guest.join("7QF8", nil)
	guest.awaitType(2*time.Second, protocol.TypeJoined)
	go autopilotGuest(guest, make(chan struct{}))

	host.await(2*time.Second, "a startable lobby", func(f frame) bool {
		return f.Type == protocol.TypeLobby && f.boolean("canStart")
	})

	// Let the 400ms account lookup land on the seat before any cards are
	// dealt, so the attribution is in place ahead of the final scoreboard.
	time.Sleep(600 * time.Millisecond)

	host.send(map[string]any{"type": protocol.TypeStart})
	if final := host.drive(20 * time.Second); final.Phase != engine.PhaseGameOver {
		t.Fatalf("game ended in phase %q", final.Phase)
	}

	records := awaitRecords(t, store, 1, 5*time.Second)
	if want := "user-device-abcdef123456"; records[0].Seats[0].UserID != want {
		t.Fatalf("seat 0 user id = %q, want %q — a late lookup must still attach",
			records[0].Seats[0].UserID, want)
	}
}

// TestFailedIdentityLookupStillSeats: a broken database costs an attribution,
// never a seat.
func TestFailedIdentityLookupStillSeats(t *testing.T) {
	store := &recordingStore{resolveErr: errors.New("postgres is on fire")}
	s := newRecordingStack(t, store)

	host := hostAPrivateGame(t, s, "7QF9", map[string]any{
		"deviceId": "device-abcdef123456",
	})
	if final := host.drive(20 * time.Second); final.Phase != engine.PhaseGameOver {
		t.Fatalf("game ended in phase %q", final.Phase)
	}

	records := awaitRecords(t, store, 1, 5*time.Second)
	if got := records[0].Seats[0].UserID; got != "" {
		t.Fatalf("seat 0 user id = %q, want empty when the lookup failed", got)
	}
}

// TestSlowStoreDoesNotStallTheTable is the §5 promise from the table's side: a
// database that has effectively stopped answering must cost history and nothing
// else. The recorder's queue is filled first so the table's own record is
// dropped rather than queued, which is the worst case.
func TestSlowStoreDoesNotStallTheTable(t *testing.T) {
	store := &stalledStore{entered: make(chan struct{}, 64)}
	recorder := room.NewRecorder(store, testLogger())
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
		defer cancel()
		_ = recorder.Shutdown(ctx)
	})
	s := newStackWith(t, stackOpts{recorder: recorder})

	// Wedge every worker and overflow the queue before the game even starts.
	for i := 0; i < 2048; i++ {
		recorder.Submit(db.GameRecord{Mode: db.ModeOnline, RoomCode: "FULL"})
	}

	host := hostAPrivateGame(t, s, "7QFB", nil)
	start := time.Now()
	final := host.drive(20 * time.Second)
	elapsed := time.Since(start)

	if final.Phase != engine.PhaseGameOver {
		t.Fatalf("game ended in phase %q", final.Phase)
	}
	// The same five hands against a healthy store take well under a second at
	// test pacing; the point is that a wedged database did not add a wait.
	if elapsed > 15*time.Second {
		t.Fatalf("the game took %v against a stalled store", elapsed)
	}

	// And a restart still works afterwards, so nothing in the room was left in
	// a half-recorded state by the drop.
	host.send(map[string]any{"type": protocol.TypeRestart})
	if again := host.drive(20 * time.Second); again.Phase != engine.PhaseGameOver {
		t.Fatalf("the restarted game ended in phase %q", again.Phase)
	}
}

// stalledStore accepts a write and never finishes it, which is what a database
// that has stopped answering looks like from here.
type stalledStore struct {
	db.Nop
	entered chan struct{}
	release chan struct{}
}

func (s *stalledStore) Enabled() bool { return true }

func (s *stalledStore) RecordGame(ctx context.Context, _ db.GameRecord) (string, bool, error) {
	select {
	case s.entered <- struct{}{}:
	default:
	}
	select {
	case <-s.release:
	case <-ctx.Done():
	}
	return "", false, errors.New("stalled store: gave up")
}
