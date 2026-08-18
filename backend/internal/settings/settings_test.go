package settings

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"
)

func quietLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelError + 1}))
}

func baseValues() Values {
	return Values{
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

// memPersist is an in-memory settings.Persistence.
type memPersist struct {
	mu   sync.Mutex
	rows map[string]string
	fail bool
}

func newMemPersist() *memPersist { return &memPersist{rows: map[string]string{}} }

func (m *memPersist) LoadSettings(context.Context) (map[string]string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make(map[string]string, len(m.rows))
	for k, v := range m.rows {
		out[k] = v
	}
	return out, nil
}

func (m *memPersist) SaveSettings(_ context.Context, values map[string]string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.fail {
		return errors.New("persist failed")
	}
	for k, v := range values {
		m.rows[k] = v
	}
	return nil
}

var _ Persistence = (*memPersist)(nil)

// TestValidate rejects nonsense values and accepts the defaults.
func TestValidate(t *testing.T) {
	if err := baseValues().Validate(); err != nil {
		t.Fatalf("defaults should validate: %v", err)
	}
	v := baseValues()
	v.BidTimeout = 0
	if err := v.Validate(); err == nil {
		t.Fatal("zero bidTimeout should be rejected")
	}
	v = baseValues()
	v.MatchMinPlayers = 5
	if err := v.Validate(); err == nil {
		t.Fatal("min players of 5 should be rejected")
	}
	v = baseValues()
	v.PlayTimeouts[2] = -time.Second
	if err := v.Validate(); err == nil {
		t.Fatal("negative play timeout should be rejected")
	}
}

// TestWithOverlay applies only the keys present and ignores unknown ones.
func TestWithOverlay(t *testing.T) {
	v, err := baseValues().WithOverlay(map[string]string{
		"bidTimeout":      "7s",
		"matchMinPlayers": "3",
		"somethingNew":    "who knows",
	})
	if err != nil {
		t.Fatalf("overlay failed: %v", err)
	}
	if v.BidTimeout != 7*time.Second {
		t.Fatalf("bidTimeout = %v, want 7s", v.BidTimeout)
	}
	if v.MatchMinPlayers != 3 {
		t.Fatalf("matchMinPlayers = %d, want 3", v.MatchMinPlayers)
	}
	if v.TrickLinger != baseValues().TrickLinger {
		t.Fatalf("untouched field must keep its value")
	}
}

// TestWithOverlayBadValue fails on a malformed known key.
func TestWithOverlayBadValue(t *testing.T) {
	_, err := baseValues().WithOverlay(map[string]string{"bidTimeout": "banana"})
	if err == nil {
		t.Fatal("a non-duration value should fail the overlay")
	}
}

// TestEncodeRoundTrip shows Encode -> WithOverlay reproduces the values.
func TestEncodeRoundTrip(t *testing.T) {
	base := baseValues()
	v, err := base.WithOverlay(base.Encode())
	if err != nil {
		t.Fatalf("round trip failed: %v", err)
	}
	if v != base {
		t.Fatalf("round trip changed values:\n got %+v\nwant %+v", v, base)
	}
}

// TestUpdatePersistsThenApplies writes through to persistence and only applies
// once the write has succeeded.
func TestUpdatePersistsThenApplies(t *testing.T) {
	per := newMemPersist()
	s, err := New(baseValues(), per, quietLogger())
	if err != nil {
		t.Fatal(err)
	}

	next := baseValues()
	next.BidTimeout = 9 * time.Second
	if err := s.Update(next); err != nil {
		t.Fatalf("update failed: %v", err)
	}
	if v, _, _ := s.Get(); v.BidTimeout != 9*time.Second {
		t.Fatalf("update did not apply")
	}
	if _, ok := per.rows[KeyBidTimeout]; !ok {
		t.Fatal("update did not persist")
	}
	if s.Source() != SourceDatabase {
		t.Fatalf("source = %q, want database", s.Source())
	}
}

// TestUpdateRollsBackOnPersistFailure refuses to apply a change its database
// could not store.
func TestUpdateRollsBackOnPersistFailure(t *testing.T) {
	per := newMemPersist()
	per.fail = true
	s, err := New(baseValues(), per, quietLogger())
	if err != nil {
		t.Fatal(err)
	}

	next := baseValues()
	next.BidTimeout = 9 * time.Second
	if err := s.Update(next); err == nil {
		t.Fatal("update should fail when persistence fails")
	}
	if v, _, _ := s.Get(); v.BidTimeout != baseValues().BidTimeout {
		t.Fatal("failed update must not change the applied values")
	}
}

// TestNewLoadsStoredValues verifies a persisted set wins over process defaults.
func TestNewLoadsStoredValues(t *testing.T) {
	per := newMemPersist()
	per.rows[KeyBidTimeout] = "6s"
	per.rows[KeyMatchMinPlayers] = "4"

	s, err := New(baseValues(), per, quietLogger())
	if err != nil {
		t.Fatal(err)
	}
	v, source, updated := s.Get()
	if v.BidTimeout != 6*time.Second || v.MatchMinPlayers != 4 {
		t.Fatalf("stored values did not win: %+v", v)
	}
	if source != SourceDatabase || updated.IsZero() {
		t.Fatalf("should report database source after load: %s %v", source, updated)
	}
}

// TestNewFallsBackOnCorruptStore runs process defaults when the stored set no
// longer parses, rather than failing to boot.
func TestNewFallsBackOnCorruptStore(t *testing.T) {
	per := newMemPersist()
	per.rows[KeyBidTimeout] = "not-a-duration"
	s, err := New(baseValues(), per, quietLogger())
	if err != nil {
		t.Fatal(err)
	}
	if v, source, _ := s.Get(); v.BidTimeout != baseValues().BidTimeout || source != SourceEnv {
		t.Fatalf("corrupt store should fall back to defaults: %+v %q", v, source)
	}
}

// TestNoPersistenceAppliesInMemory: without a Persistence, Update applies and
// reports source runtime.
func TestNoPersistenceAppliesInMemory(t *testing.T) {
	s, err := New(baseValues(), nil, quietLogger())
	if err != nil {
		t.Fatal(err)
	}
	next := baseValues()
	next.MatchMinPlayers = 3
	if err := s.Update(next); err != nil {
		t.Fatalf("update without persistence should apply: %v", err)
	}
	if v, source, _ := s.Get(); v.MatchMinPlayers != 3 || source != SourceRuntime {
		t.Fatalf("got %+v from %q", v, source)
	}
	if s.Persisted() {
		t.Fatal("a store with no persistence must report not persisted")
	}
}

// TestPacingProjection keeps Pacing() in step with room.Pacing.
func TestPacingProjection(t *testing.T) {
	s, err := New(baseValues(), nil, quietLogger())
	if err != nil {
		t.Fatal(err)
	}
	p := s.Pacing()
	if p.BidTimeout != baseValues().BidTimeout || p.PlayTimeouts[0] != baseValues().PlayTimeouts[0] {
		t.Fatalf("pacing projection wrong: %+v", p)
	}
}
