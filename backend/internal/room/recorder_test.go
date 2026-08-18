package room

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"

	"github.com/nabin31bogati/callbreak/backend/internal/db"
)

// fakeStore is a db.Store that records what it was asked to write, with
// optional latency and failures. Embedding db.Nop means only the methods these
// tests exercise have to exist here.
type fakeStore struct {
	db.Nop

	mu     sync.Mutex
	games  []db.GameRecord
	calls  int
	delay  time.Duration
	failed int
	// failFirst makes the first n attempts fail, to exercise the retry.
	failFirst int
	// disabled reports the store as switched off, which is the no-Postgres path.
	disabled bool
}

func (f *fakeStore) Enabled() bool { return !f.disabled }

func (f *fakeStore) RecordGame(ctx context.Context, rec db.GameRecord) (string, bool, error) {
	f.mu.Lock()
	delay := f.delay
	f.calls++
	attempt := f.calls
	failFirst := f.failFirst
	f.mu.Unlock()

	if delay > 0 {
		select {
		case <-time.After(delay):
		case <-ctx.Done():
			return "", false, ctx.Err()
		}
	}
	if attempt <= failFirst {
		f.mu.Lock()
		f.failed++
		f.mu.Unlock()
		return "", false, errors.New("fake store: write failed")
	}

	f.mu.Lock()
	defer f.mu.Unlock()
	f.games = append(f.games, rec)
	return "game-id", false, nil
}

func (f *fakeStore) recorded() []db.GameRecord {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]db.GameRecord(nil), f.games...)
}

func (f *fakeStore) callCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls
}

func quietLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelError + 1}))
}

func shutdown(t *testing.T, r *Recorder, d time.Duration) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), d)
	defer cancel()
	if err := r.Shutdown(ctx); err != nil {
		t.Fatalf("recorder shutdown: %v", err)
	}
}

// TestRecorderWritesAndDrains is the happy path: what goes in comes out, and
// Shutdown flushes rather than discards.
func TestRecorderWritesAndDrains(t *testing.T) {
	store := &fakeStore{}
	rec := NewRecorder(store, quietLogger())

	for i := 0; i < 5; i++ {
		rec.Submit(db.GameRecord{Mode: db.ModeOnline, RoomCode: "ABCD", Completed: true})
	}
	shutdown(t, rec, 5*time.Second)

	if got := len(store.recorded()); got != 5 {
		t.Fatalf("wrote %d games, want 5", got)
	}
}

// TestRecorderRetriesOnceThenDrops pins the failure policy from §5: retried,
// then dropped with a log, never propagated back to a table.
func TestRecorderRetriesOnceThenDrops(t *testing.T) {
	// One failure: the retry saves it.
	store := &fakeStore{failFirst: 1}
	rec := NewRecorder(store, quietLogger())
	rec.Submit(db.GameRecord{Mode: db.ModePrivate})
	shutdown(t, rec, 5*time.Second)

	if got := len(store.recorded()); got != 1 {
		t.Fatalf("a write that succeeded on retry stored %d games, want 1", got)
	}
	if got := store.callCount(); got != 2 {
		t.Fatalf("store was called %d times, want 2 (the write and its retry)", got)
	}

	// Two failures: the record is dropped and nothing is retried forever.
	store = &fakeStore{failFirst: 2}
	rec = NewRecorder(store, quietLogger())
	rec.Submit(db.GameRecord{Mode: db.ModePrivate})
	shutdown(t, rec, 5*time.Second)

	if got := len(store.recorded()); got != 0 {
		t.Fatalf("stored %d games, want 0: both attempts failed", got)
	}
	if got := store.callCount(); got != 2 {
		t.Fatalf("store was called %d times, want exactly 2 attempts", got)
	}
}

// TestRecorderSubmitNeverBlocks is the load-bearing property. The caller is a
// room actor with a table waiting on it, so Submit has to return promptly even
// when every worker is stuck in a slow query and the queue is long past full.
func TestRecorderSubmitNeverBlocks(t *testing.T) {
	// Slow enough that no submission below can possibly be drained in time.
	store := &fakeStore{delay: time.Minute}
	rec := NewRecorder(store, quietLogger())
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
		defer cancel()
		_ = rec.Shutdown(ctx)
	})

	submissions := recorderQueueSize * 4
	start := time.Now()
	for i := 0; i < submissions; i++ {
		rec.Submit(db.GameRecord{Mode: db.ModeOnline, RoomCode: "ABCD"})
	}
	elapsed := time.Since(start)

	// Four queues' worth of records through a recorder whose workers are wedged
	// for a minute each. Anything but "instant" means Submit applied
	// backpressure to its caller, which is the one thing it must never do.
	if elapsed > 2*time.Second {
		t.Fatalf("%d submissions took %v against a wedged store; Submit must not block",
			submissions, elapsed)
	}
	if store.callCount() > recorderWorkers {
		t.Fatalf("store was entered %d times, want at most %d: the rest must have been dropped",
			store.callCount(), recorderWorkers)
	}
}

// TestRecorderDisabledIsInert covers the no-Postgres deployment: a recorder
// over a nil or disabled store is safe to hold and safe to call, and touches
// nothing.
func TestRecorderDisabledIsInert(t *testing.T) {
	for name, rec := range map[string]*Recorder{
		"nil store":      NewRecorder(nil, quietLogger()),
		"disabled store": NewRecorder(&fakeStore{disabled: true}, quietLogger()),
		"db.Nop":         NewRecorder(db.Nop{}, quietLogger()),
		"nil recorder":   nil,
	} {
		t.Run(name, func(t *testing.T) {
			if rec.enabled() {
				t.Fatal("recorder reports itself enabled")
			}
			rec.Submit(db.GameRecord{Mode: db.ModeOnline})
			if err := rec.Close(); err != nil {
				t.Fatalf("close: %v", err)
			}
			// Submitting after a close must also be inert rather than a panic on
			// a closed channel.
			rec.Submit(db.GameRecord{Mode: db.ModeOnline})
		})
	}
}

// TestRecorderSubmitAfterShutdown makes sure a table that finishes during the
// drain window is dropped quietly rather than panicking the room actor.
func TestRecorderSubmitAfterShutdown(t *testing.T) {
	store := &fakeStore{}
	rec := NewRecorder(store, quietLogger())
	shutdown(t, rec, 5*time.Second)

	rec.Submit(db.GameRecord{Mode: db.ModeOnline})
	if got := len(store.recorded()); got != 0 {
		t.Fatalf("stored %d games after shutdown, want 0", got)
	}
	// Repeated shutdowns are safe: main may call it on more than one path.
	shutdown(t, rec, time.Second)
}

// TestRecorderShutdownRespectsDeadline proves the drain is bounded — a wedged
// database must not hold a server shutdown open.
func TestRecorderShutdownRespectsDeadline(t *testing.T) {
	store := &fakeStore{delay: time.Minute}
	rec := NewRecorder(store, quietLogger())
	rec.Submit(db.GameRecord{Mode: db.ModeOnline})

	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	start := time.Now()
	if err := rec.Shutdown(ctx); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("shutdown returned %v, want a deadline error", err)
	}
	if elapsed := time.Since(start); elapsed > 5*time.Second {
		t.Fatalf("shutdown took %v; it must give up at its deadline", elapsed)
	}
}
