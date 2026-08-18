// Package settings holds the server's runtime-tunable defaults.
//
// Config from the environment is a startup snapshot; these are the same knobs
// a running server may change without a restart. They split into two groups:
// the pacing and turn clocks every table runs on, and the quickplay match
// defaults (minimum humans, fill window). Both only apply to tables created
// *after* a change — a live table keeps the pacing it was dealt, the same way
// it keeps the hand count it was created with.
//
// Persistence is optional and supplied by the caller through Persistence. With
// one attached, stored values win over the process defaults on startup and
// every Update is written through before it is applied, so a fleet restarts
// onto the settings an operator last saved rather than the ones someone
// launched it with.
package settings

import (
	"context"
	"fmt"
	"log/slog"
	"strconv"
	"sync"
	"time"

	"github.com/nabin31bogati/callbreak/backend/internal/room"
)

// Values is one full set of tunable defaults. Zero fields are invalid; every
// field must be populated before the store is built (normally from config).
type Values struct {
	BotThinkMin     time.Duration
	BotThinkExtra   time.Duration
	TrickLinger     time.Duration
	StartCountdown  time.Duration
	BidTimeout      time.Duration
	PlayTimeouts    [4]time.Duration
	ReconnectGrace  time.Duration
	HandAdvanceWait time.Duration
	RoomIdleTTL     time.Duration
	DealGrace       time.Duration
	MatchFillWait   time.Duration
	MatchMinPlayers int
}

// Pacing projects the table-tuning half of the values into the room package's
// Pacing, which is what a new table is created with.
func (v Values) Pacing() room.Pacing {
	return room.Pacing{
		BotThinkMin:     v.BotThinkMin,
		BotThinkExtra:   v.BotThinkExtra,
		TrickLinger:     v.TrickLinger,
		BidTimeout:      v.BidTimeout,
		PlayTimeouts:    v.PlayTimeouts,
		ReconnectGrace:  v.ReconnectGrace,
		HandAdvanceWait: v.HandAdvanceWait,
		IdleTTL:         v.RoomIdleTTL,
		StartCountdown:  v.StartCountdown,
		DealGrace:       v.DealGrace,
	}
}

// Validate reports why v cannot be applied, or nil when it is a legal set.
func (v Values) Validate() error {
	for name, d := range map[string]time.Duration{
		"botThinkMin":     v.BotThinkMin,
		"botThinkExtra":   v.BotThinkExtra,
		"trickLinger":     v.TrickLinger,
		"startCountdown":  v.StartCountdown,
		"bidTimeout":      v.BidTimeout,
		"reconnectGrace":  v.ReconnectGrace,
		"handAdvanceWait": v.HandAdvanceWait,
		"roomIdleTTL":     v.RoomIdleTTL,
		"dealGrace":       v.DealGrace,
		"matchFillWait":   v.MatchFillWait,
	} {
		if d <= 0 {
			return fmt.Errorf("settings: %s must be a positive duration", name)
		}
	}
	for i, d := range v.PlayTimeouts {
		if d <= 0 {
			return fmt.Errorf("settings: playTimeouts[%d] must be a positive duration", i)
		}
	}
	if v.MatchMinPlayers < 1 || v.MatchMinPlayers > 4 {
		return fmt.Errorf("settings: matchMinPlayers must be between 1 and 4")
	}
	return nil
}

// Persistence is where the store keeps a saved Values. It is optional: a nil
// implementation means the store holds process memory and nothing survives a
// restart. The exchange type is a plain map so the package can live here
// without either side importing the other.
//
// Keys are the wire names (the same lowerCamelCase names the REST API uses);
// values are Go duration strings or integers, exactly as an operator would
// type them. A stored key with a value the binary no longer understands is
// ignored rather than fatal, which is what lets a newer dashboard talk to an
// older server and back again.
type Persistence interface {
	LoadSettings(ctx context.Context) (map[string]string, error)
	SaveSettings(ctx context.Context, values map[string]string) error
}

// wire names, shared between the store, its persistence layer and the API.
const (
	KeyBotThinkMin     = "botThinkMin"
	KeyBotThinkExtra   = "botThinkExtra"
	KeyTrickLinger     = "trickLinger"
	KeyStartCountdown  = "startCountdown"
	KeyBidTimeout      = "bidTimeout"
	KeyPlayTimeout0    = "playTimeout0"
	KeyPlayTimeout1    = "playTimeout1"
	KeyPlayTimeout2    = "playTimeout2"
	KeyPlayTimeout3    = "playTimeout3"
	KeyReconnectGrace  = "reconnectGrace"
	KeyHandAdvanceWait = "handAdvanceWait"
	KeyRoomIdleTTL     = "roomIdleTTL"
	KeyDealGrace       = "dealGrace"
	KeyMatchFillWait   = "matchFillWait"
	KeyMatchMinPlayers = "matchMinPlayers"
)

// Source names where the current values came from, for the dashboard to show.
const (
	SourceEnv      = "env"      // startup config, never saved
	SourceDatabase = "database" // loaded from, and written through to, persistence
	SourceRuntime  = "runtime"  // changed live; no persistence, so it is gone on restart
)

// Store is a concurrency-safe holder of the current Values, plus its optional
// persistence. Reads never block on writes.
type Store struct {
	log *slog.Logger
	per Persistence

	mu      sync.RWMutex
	v       Values
	source  string
	updated time.Time
}

// New builds a store around a validated starting Values. initial is normally
// the process config; if persistence is attached and holds a saved set, the
// saved set wins and the store starts sourced from the database.
func New(initial Values, per Persistence, log *slog.Logger) (*Store, error) {
	if log == nil {
		log = slog.Default()
	}
	s := &Store{log: log.With("component", "settings"), per: per, v: initial, source: SourceEnv}

	if per == nil {
		if err := s.v.Validate(); err != nil {
			return nil, err
		}
		return s, nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	stored, err := per.LoadSettings(ctx)
	if err != nil {
		// A read failure is worth being loud about: the server is about to run
		// on settings an operator may have changed, and not know it.
		log.Error("could not load runtime settings; using process defaults", "err", err)
		return s, s.v.Validate()
	}
	if len(stored) == 0 {
		return s, s.v.Validate()
	}
	overlay, err := initial.WithOverlay(stored)
	if err != nil {
		// Same rule as a partial env override: a saved set that no longer parses
		// is more surprising than the defaults it was overriding.
		log.Error("stored runtime settings are invalid; using process defaults", "err", err)
		return s, s.v.Validate()
	}
	s.v = overlay
	s.source = SourceDatabase
	s.updated = time.Now()
	return s, nil
}

// WithOverlay returns v with every key present in m applied. Keys the receiver
// does not know are ignored. A malformed value for a known key is an error and
// stops the whole overlay, so a hand-edited row cannot silently half-apply.
func (v Values) WithOverlay(m map[string]string) (Values, error) {
	get := func(key string) (time.Duration, bool, error) {
		raw, ok := m[key]
		if !ok {
			return 0, false, nil
		}
		d, err := time.ParseDuration(raw)
		if err != nil {
			return 0, true, fmt.Errorf("settings: %s is not a duration: %q", key, raw)
		}
		return d, true, nil
	}
	apply := func(key string, dst *time.Duration) error {
		d, ok, err := get(key)
		if err != nil {
			return err
		}
		if ok {
			*dst = d
		}
		return nil
	}

	for key, dst := range map[string]*time.Duration{
		KeyBotThinkMin:     &v.BotThinkMin,
		KeyBotThinkExtra:   &v.BotThinkExtra,
		KeyTrickLinger:     &v.TrickLinger,
		KeyStartCountdown:  &v.StartCountdown,
		KeyBidTimeout:      &v.BidTimeout,
		KeyReconnectGrace:  &v.ReconnectGrace,
		KeyHandAdvanceWait: &v.HandAdvanceWait,
		KeyRoomIdleTTL:     &v.RoomIdleTTL,
		KeyDealGrace:       &v.DealGrace,
		KeyMatchFillWait:   &v.MatchFillWait,
	} {
		if err := apply(key, dst); err != nil {
			return v, err
		}
	}
	for i := 0; i < 4; i++ {
		if err := apply(playKey(i), &v.PlayTimeouts[i]); err != nil {
			return v, err
		}
	}
	if raw, ok := m[KeyMatchMinPlayers]; ok {
		n, err := strconv.Atoi(raw)
		if err != nil {
			return v, fmt.Errorf("settings: %s is not a number: %q", KeyMatchMinPlayers, raw)
		}
		v.MatchMinPlayers = n
	}
	return v, nil
}

// Encode serialises v to the persistence wire form.
func (v Values) Encode() map[string]string {
	return map[string]string{
		KeyBotThinkMin:     v.BotThinkMin.String(),
		KeyBotThinkExtra:   v.BotThinkExtra.String(),
		KeyTrickLinger:     v.TrickLinger.String(),
		KeyStartCountdown:  v.StartCountdown.String(),
		KeyBidTimeout:      v.BidTimeout.String(),
		KeyPlayTimeout0:    v.PlayTimeouts[0].String(),
		KeyPlayTimeout1:    v.PlayTimeouts[1].String(),
		KeyPlayTimeout2:    v.PlayTimeouts[2].String(),
		KeyPlayTimeout3:    v.PlayTimeouts[3].String(),
		KeyReconnectGrace:  v.ReconnectGrace.String(),
		KeyHandAdvanceWait: v.HandAdvanceWait.String(),
		KeyRoomIdleTTL:     v.RoomIdleTTL.String(),
		KeyDealGrace:       v.DealGrace.String(),
		KeyMatchFillWait:   v.MatchFillWait.String(),
		KeyMatchMinPlayers: strconv.Itoa(v.MatchMinPlayers),
	}
}

func playKey(i int) string {
	return [4]string{KeyPlayTimeout0, KeyPlayTimeout1, KeyPlayTimeout2, KeyPlayTimeout3}[i]
}

// Get returns a copy of the current values with where they came from.
func (s *Store) Get() (Values, string, time.Time) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.v, s.source, s.updated
}

// Pacing implements room.PacingSource, so the hub reads live pacing per table.
func (s *Store) Pacing() room.Pacing {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.v.Pacing()
}

// MatchMinPlayers implements match.Params.
func (s *Store) MatchMinPlayers() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.v.MatchMinPlayers
}

// MatchFillWait implements match.Params.
func (s *Store) MatchFillWait() time.Duration {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.v.MatchFillWait
}

// Persisted reports whether the store will round-trip changes through a
// database. The dashboard shows it so an operator knows whether a saved value
// survives a restart.
func (s *Store) Persisted() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.per != nil
}

// Source reports where the current values came from: SourceEnv when nothing
// has been saved, SourceDatabase once a stored (or just-updated) set is live.
func (s *Store) Source() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.source
}

// Update validates and applies a new Values. When persistence is attached the
// write happens first and a failure is returned unchanged, so a saved set can
// never disagree with what the process is running on — an operator who sees
// "saved" on the dashboard knows the fleet restarted onto it.
func (s *Store) Update(v Values) error {
	if err := v.Validate(); err != nil {
		return err
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	per := s.per
	if per != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := per.SaveSettings(ctx, v.Encode()); err != nil {
			s.log.Error("could not persist runtime settings; change not applied", "err", err)
			return fmt.Errorf("settings: saving to the database failed: %w", err)
		}
		s.source = SourceDatabase
	} else {
		// No persistence: the value lives in this process and dies with it. Say
		// so, because "database" would quietly promise something that is not true.
		s.source = SourceRuntime
	}
	s.v = v
	s.updated = time.Now()
	s.log.Info("runtime settings updated", "values", v)
	return nil
}
