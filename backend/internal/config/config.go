// Package config resolves runtime settings from the environment.
//
// Every field has a default that makes `go run ./cmd/server` work with no
// environment at all, so local development needs no setup file. Anything that
// would be unsafe to default — the token signing secret in production — is
// validated in Validate rather than silently guessed.
package config

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	Addr      string
	Env       string // "development" or "production"
	LogLevel  string
	PublicURL string // how clients reach *this* node, for redirects
	NodeID    string

	RedisURL    string
	DatabaseURL string

	// DatabaseRequired turns a database that will not connect into a startup
	// failure instead of a degradation. Off by default because PERSISTENCE.md §5
	// is explicit that a database problem must never stop a game — losing history
	// beats refusing to deal. A deployment that would rather not serve at all
	// than serve without history sets this to true.
	DatabaseRequired bool
	// DBMaxConns bounds the Postgres pool. Recording is a handful of short
	// transactions per finished game, so a small pool is plenty; the number
	// exists mainly so a fleet of replicas cannot collectively exhaust the
	// server's connection limit.
	DBMaxConns int
	// RecordTricks stores card-level replay detail. Off by default: it is ~260
	// rows per game (PERSISTENCE.md §2.1) and most products never read it, while
	// the per-hand scoreboard is what a history screen actually renders. The
	// table exists either way, so turning this on is a config change and not a
	// migration.
	RecordTricks bool

	JWTSecret []byte

	// AdminToken protects the admin dashboard and its API. Empty disables the
	// whole surface — the route simply is not mounted — so a deployment that
	// never sets it is not silently exposed.
	AdminToken string

	// Table pacing. Defaults mirror the pacing constants in the Godot client
	// (godot/scripts/net/game_session.gd) so a networked table feels the same
	// as the offline one.
	BotThinkMin    time.Duration
	BotThinkExtra  time.Duration
	TrickLinger    time.Duration
	StartCountdown time.Duration

	// Turn clocks. A seat that blows its deadline is played by a bot.
	BidTimeout time.Duration
	// PlayTimeouts is indexed by how many cards are already down in the
	// current trick — the leader gets the longest to think, the last seat to
	// play the least.
	PlayTimeouts [4]time.Duration

	// How long a dropped player keeps their seat before it is given up.
	ReconnectGrace time.Duration
	// How long everyone else waits for stragglers between hands.
	HandAdvanceWait time.Duration
	// How long an empty room lives before it is collected.
	RoomIdleTTL time.Duration
	// DealGrace is added to the first bidder's bid clock so the dealing
	// animation does not eat into their thinking time.
	DealGrace time.Duration

	// Quickplay: once MatchMinPlayers are seated, wait this long for more before
	// dealing with bots on the empty seats.
	MatchFillWait time.Duration
	// Quickplay will not deal below this many humans. One human against three
	// bots is the offline mode, not a match against people.
	MatchMinPlayers int

	MaxRooms         int
	MaxConnsPerIP    int
	MsgRatePerSecond float64
	MsgBurst         int
	// APIRatePerMinute caps REST requests per account (and per address on the
	// one unauthenticated endpoint). The client's own traffic is a profile open
	// and a history scroll, so a couple of requests a second is already far more
	// headroom than a person generates; the limit is here to stop a stuck retry
	// loop or a scripted client from turning into database load.
	APIRatePerMinute int
	ShutdownGrace    time.Duration
	AllowedOrigins   []string
	EnablePprof      bool
}

func Load() (Config, error) {
	c := Config{
		Addr:             env("ADDR", ":8080"),
		Env:              env("ENV", "development"),
		LogLevel:         env("LOG_LEVEL", "info"),
		PublicURL:        env("PUBLIC_URL", ""),
		NodeID:           env("NODE_ID", ""),
		RedisURL:         env("REDIS_URL", ""),
		DatabaseURL:      env("DATABASE_URL", ""),
		DatabaseRequired: envBool("DATABASE_REQUIRED", false),
		DBMaxConns:       envInt("DB_MAX_CONNS", 10),
		RecordTricks:     envBool("RECORD_TRICKS", false),
		BotThinkMin:      envDuration("BOT_THINK_MIN", 550*time.Millisecond),
		BotThinkExtra:    envDuration("BOT_THINK_EXTRA", 450*time.Millisecond),
		TrickLinger:      envDuration("TRICK_LINGER", 1100*time.Millisecond),
		StartCountdown:   envDuration("START_COUNTDOWN", 3*time.Second),
		BidTimeout:       envDuration("BID_TIMEOUT", 5*time.Second),
		PlayTimeouts: envDurationList4("PLAY_TIMEOUTS", [4]time.Duration{
			10 * time.Second, 8 * time.Second, 6 * time.Second, 5 * time.Second,
		}),
		ReconnectGrace:   envDuration("RECONNECT_GRACE", 2*time.Minute),
		HandAdvanceWait:  envDuration("HAND_ADVANCE_WAIT", 5*time.Second),
		RoomIdleTTL:      envDuration("ROOM_IDLE_TTL", 5*time.Minute),
		DealGrace:        envDuration("DEAL_GRACE", 3500*time.Millisecond),
		MatchFillWait:    envDuration("MATCH_FILL_WAIT", 5*time.Second),
		MatchMinPlayers:  envInt("MATCH_MIN_PLAYERS", 2),
		MaxRooms:         envInt("MAX_ROOMS", 50_000),
		MaxConnsPerIP:    envInt("MAX_CONNS_PER_IP", 64),
		MsgRatePerSecond: envFloat("MSG_RATE_PER_SECOND", 20),
		MsgBurst:         envInt("MSG_BURST", 40),
		APIRatePerMinute: envInt("API_RATE_PER_MINUTE", 120),
		ShutdownGrace:    envDuration("SHUTDOWN_GRACE", 20*time.Second),
		AllowedOrigins:   envList("ALLOWED_ORIGINS", nil),
		EnablePprof:      envBool("ENABLE_PPROF", false),
		AdminToken:       os.Getenv("ADMIN_TOKEN"),
	}

	// PORT is what most PaaS providers inject; it wins over ADDR when present.
	if port := os.Getenv("PORT"); port != "" {
		c.Addr = ":" + port
	}
	if c.NodeID == "" {
		c.NodeID = randomID("node")
	}

	secret := os.Getenv("JWT_SECRET")
	if secret == "" {
		if c.IsProduction() {
			return c, fmt.Errorf("config: JWT_SECRET is required in production")
		}
		// A per-process secret is fine for development: tokens stop being valid
		// on restart, which is exactly what you want while iterating.
		secret = randomID("dev")
	}
	c.JWTSecret = []byte(secret)

	return c, c.validate()
}

func (c Config) IsProduction() bool { return strings.EqualFold(c.Env, "production") }

// RedisEnabled reports whether the shared registry is configured. Without it
// the server still works, single-node.
func (c Config) RedisEnabled() bool { return c.RedisURL != "" }

// PostgresEnabled reports whether match history should be persisted.
func (c Config) PostgresEnabled() bool { return c.DatabaseURL != "" }

func (c Config) validate() error {
	if c.MaxRooms <= 0 {
		return fmt.Errorf("config: MAX_ROOMS must be positive")
	}
	if c.MsgRatePerSecond <= 0 || c.MsgBurst <= 0 {
		return fmt.Errorf("config: message rate limits must be positive")
	}
	if c.BidTimeout <= 0 {
		return fmt.Errorf("config: turn timeouts must be positive")
	}
	for _, d := range c.PlayTimeouts {
		if d <= 0 {
			return fmt.Errorf("config: turn timeouts must be positive")
		}
	}
	if c.MatchMinPlayers < 1 || c.MatchMinPlayers > 4 {
		return fmt.Errorf("config: MATCH_MIN_PLAYERS must be between 1 and 4")
	}
	if c.DBMaxConns <= 0 {
		return fmt.Errorf("config: DB_MAX_CONNS must be positive")
	}
	if c.APIRatePerMinute <= 0 {
		// Zero would silently reject every REST request rather than disable the
		// limiter, which is the opposite of what anyone typing it would mean.
		return fmt.Errorf("config: API_RATE_PER_MINUTE must be positive")
	}
	if c.DatabaseRequired && !c.PostgresEnabled() {
		return fmt.Errorf("config: DATABASE_REQUIRED is set but DATABASE_URL is empty")
	}
	if c.IsProduction() && len(c.AllowedOrigins) == 0 {
		// Browsers are not a target today (the client is a Godot app, which
		// sends no Origin), but leaving this open in production would let any
		// web page drive a socket on a user's behalf.
		return fmt.Errorf("config: ALLOWED_ORIGINS is required in production")
	}
	return nil
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envInt(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

func envFloat(key string, def float64) float64 {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.ParseFloat(v, 64); err == nil {
			return n
		}
	}
	return def
}

func envBool(key string, def bool) bool {
	if v := os.Getenv(key); v != "" {
		if b, err := strconv.ParseBool(v); err == nil {
			return b
		}
	}
	return def
}

func envDuration(key string, def time.Duration) time.Duration {
	if v := os.Getenv(key); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
	}
	return def
}

// envDurationList4 parses a comma-separated list of exactly four durations,
// e.g. "10s,8s,6s,5s". Falls back to def wholesale if the count does not
// match or any entry fails to parse — a partial override is more surprising
// than no override.
func envDurationList4(key string, def [4]time.Duration) [4]time.Duration {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	parts := strings.Split(v, ",")
	if len(parts) != len(def) {
		return def
	}
	var out [4]time.Duration
	for i, p := range parts {
		d, err := time.ParseDuration(strings.TrimSpace(p))
		if err != nil {
			return def
		}
		out[i] = d
	}
	return out
}

func envList(key string, def []string) []string {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	parts := strings.Split(v, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

func randomID(prefix string) string {
	buf := make([]byte, 8)
	if _, err := rand.Read(buf); err != nil {
		// crypto/rand does not fail on any platform we target; if it somehow
		// does, a predictable id is worse than crashing at startup.
		panic("config: no entropy available: " + err.Error())
	}
	return prefix + "-" + hex.EncodeToString(buf)
}
