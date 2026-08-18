// Command server runs the Call Break game server.
//
// One binary serves both product modes: private tables addressed by a room
// code, and quickplay matchmaking. It works with no external dependencies at
// all — Redis and Postgres are optional, and their absence only costs
// multi-node routing and match history respectively.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/pprof"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/nabin31bogati/callbreak/backend/internal/auth"
	"github.com/nabin31bogati/callbreak/backend/internal/config"
	"github.com/nabin31bogati/callbreak/backend/internal/db"
	"github.com/nabin31bogati/callbreak/backend/internal/httpapi"
	"github.com/nabin31bogati/callbreak/backend/internal/match"
	"github.com/nabin31bogati/callbreak/backend/internal/obs"
	"github.com/nabin31bogati/callbreak/backend/internal/room"
	"github.com/nabin31bogati/callbreak/backend/internal/settings"
	// Aliased: internal/store is the Redis room registry, and the plain name is
	// wanted here for the db.Store that persistence hangs off.
	roomregistry "github.com/nabin31bogati/callbreak/backend/internal/store"
	"github.com/nabin31bogati/callbreak/backend/internal/ws"
)

func main() {
	if err := run(); err != nil {
		slog.Error("server exited", "err", err)
		os.Exit(1)
	}
}

func run() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}

	log := obs.NewLogger(cfg.LogLevel, cfg.Env)
	slog.SetDefault(log)
	log.Info("starting",
		"node", cfg.NodeID,
		"addr", cfg.Addr,
		"env", cfg.Env,
		"redis", cfg.RedisEnabled(),
		"postgres", cfg.PostgresEnabled(),
	)

	// Cancelled on shutdown; every room and the matchmaker hang off it.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// Rooms outlive the signal context by design: when a signal arrives we want
	// to drain gracefully, not tear tables down mid-trick, so they get their own
	// cancellable context that is cut only after the drain window.
	roomsCtx, closeRooms := context.WithCancel(context.Background())
	defer closeRooms()

	signer := auth.NewSigner(cfg.JWTSecret)
	health := obs.NewHealth()

	// Persistence is optional, and the default is the version of the server that
	// existed before it: no accounts, no history, tables that work. Nop satisfies
	// the whole Store interface by reporting ErrDisabled, so nothing downstream
	// has to branch on whether a database is there.
	var store db.Store = db.Nop{}
	if cfg.PostgresEnabled() {
		opened, err := db.OpenPostgres(ctx, cfg.DatabaseURL, log, db.Options{
			MaxConns:     int32(cfg.DBMaxConns),
			RecordTricks: cfg.RecordTricks,
		})
		switch {
		case err == nil:
			store = opened
		case cfg.DatabaseRequired:
			// The operator has said they would rather not serve at all than
			// serve without history. That is the only case where a database
			// problem is allowed to stop the process.
			return fmt.Errorf("connect to postgres: %w", err)
		default:
			// PERSISTENCE.md §5: a database problem must never stop a game. We
			// lose history, not gameplay — but loudly, because a server quietly
			// recording nothing is exactly the failure nobody notices for a week.
			log.Error("PERSISTENCE DISABLED: could not connect to postgres; "+
				"games will not be recorded and the REST API will answer 503. "+
				"Set DATABASE_REQUIRED=true to make this fatal instead",
				"err", err)
		}
	}
	defer func() {
		if err := store.Close(); err != nil {
			log.Warn("closing the database did not complete cleanly", "err", err)
		}
	}()
	// Reported separately from the "starting" line above, which can only say
	// what was configured. This one says what actually happened.
	log.Info("persistence",
		"enabled", store.Enabled(),
		"required", cfg.DatabaseRequired,
		"maxConns", cfg.DBMaxConns,
		"recordTricks", cfg.RecordTricks,
		"apiRatePerMinute", cfg.APIRatePerMinute,
	)

	pacing := room.Pacing{
		BotThinkMin:     cfg.BotThinkMin,
		BotThinkExtra:   cfg.BotThinkExtra,
		TrickLinger:     cfg.TrickLinger,
		BidTimeout:      cfg.BidTimeout,
		PlayTimeouts:    cfg.PlayTimeouts,
		ReconnectGrace:  cfg.ReconnectGrace,
		HandAdvanceWait: cfg.HandAdvanceWait,
		IdleTTL:         cfg.RoomIdleTTL,
		StartCountdown:  cfg.StartCountdown,
		DealGrace:       cfg.DealGrace,
	}

	// The live runtime defaults sit beside the startup config: every pacing
	// and quickplay knob the operator can change from the dashboard, sourced
	// from the environment on first boot and from the database thereafter.
	// The store implements settings.Persistence only when Postgres is up; a
	// Nop or a failed connection means the settings live in this process and
	// nothing survives a restart.
	var settingsPersist settings.Persistence
	if p, ok := store.(settings.Persistence); ok {
		settingsPersist = p
	}
	liveSettings, err := settings.New(settings.Values{
		BotThinkMin:     cfg.BotThinkMin,
		BotThinkExtra:   cfg.BotThinkExtra,
		TrickLinger:     cfg.TrickLinger,
		StartCountdown:  cfg.StartCountdown,
		BidTimeout:      cfg.BidTimeout,
		PlayTimeouts:    cfg.PlayTimeouts,
		ReconnectGrace:  cfg.ReconnectGrace,
		HandAdvanceWait: cfg.HandAdvanceWait,
		RoomIdleTTL:     cfg.RoomIdleTTL,
		DealGrace:       cfg.DealGrace,
		MatchFillWait:   cfg.MatchFillWait,
		MatchMinPlayers: cfg.MatchMinPlayers,
	}, settingsPersist, log)
	if err != nil {
		return err
	}
	log.Info("runtime settings", "source", liveSettings.Source(), "persisted", liveSettings.Persisted())

	hub := room.NewHub(roomsCtx, pacing, signer, log, cfg.MaxRooms)
	hub.PacingSource = liveSettings

	// Recording is downstream of play: the recorder owns a bounded queue and its
	// own goroutines, so a room actor hands a finished game over and returns to
	// dealing the next one no matter how slow Postgres is. Built even when the
	// store is a Nop, where Submit is a no-op and nothing has to branch.
	recorder := room.NewRecorder(store, log)
	hub.Recorder = recorder

	matcher := match.New(hub, log, cfg.MatchMinPlayers, cfg.MatchFillWait)
	matcher.Live = liveSettings

	gateway := ws.NewServer(cfg, hub, matcher, signer, log, health)
	// Lets the join frame's optional deviceId resolve to a users.id, so a seat in
	// a server-played game is attributed to an account. Identity is an enrichment
	// of the session and never a precondition for it: with no store this resolves
	// to nothing and play is unaffected.
	gateway.Users = store

	// The REST surface from docs/API.md: profiles, statistics, history, and the
	// upload path for games played offline. It shares the mux with /ws and
	// /healthz, and answers 503 persistence_disabled on every route when there is
	// no database rather than refusing to start.
	api := httpapi.NewServer(cfg, store, signer, log)
	if cfg.AdminToken != "" {
		api.Admin(hub, liveSettings, cfg.AdminToken)
		log.Info("admin dashboard enabled", "path", "/admin")
	}

	// The shared room registry is what makes more than one replica coherent: it
	// lets a node say "that table is over there" instead of quietly creating a
	// second table under the same code. Without it the server is still fully
	// functional, just single-node.
	if cfg.RedisEnabled() {
		endpoint := cfg.PublicURL
		if endpoint == "" {
			return errors.New("PUBLIC_URL is required alongside REDIS_URL: " +
				"other nodes need an address to redirect players to")
		}
		registry, err := roomregistry.NewRedis(ctx, cfg.RedisURL, endpoint, log)
		if err != nil {
			return fmt.Errorf("connect to redis: %w", err)
		}
		defer registry.Close()
		hub.Registry = registry
		gateway.Locator = registry
		log.Info("shared room registry enabled", "endpoint", endpoint)
	}

	mux := http.NewServeMux()
	health.Handler(mux)
	gateway.Handler(mux)
	api.Handler(mux)
	if cfg.EnablePprof {
		log.Warn("pprof is enabled; do not expose this port publicly")
		mux.HandleFunc("GET /debug/pprof/", pprof.Index)
		mux.HandleFunc("GET /debug/pprof/profile", pprof.Profile)
		mux.HandleFunc("GET /debug/pprof/trace", pprof.Trace)
	}

	srv := &http.Server{
		Addr:    cfg.Addr,
		Handler: mux,
		// Websockets do their own deadline management once upgraded; these only
		// bound the handshake, which is exactly what they should do.
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	serveErr := make(chan error, 1)
	go func() {
		log.Info("listening", "addr", cfg.Addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			serveErr <- err
			return
		}
		serveErr <- nil
	}()

	select {
	case err := <-serveErr:
		return err
	case <-ctx.Done():
	}

	// Drain: stop taking new players first so the load balancer routes elsewhere,
	// then tell the tables to wrap up.
	log.Info("shutting down", "grace", cfg.ShutdownGrace)
	health.Drain()

	shutdownCtx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownGrace)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Warn("http shutdown did not complete cleanly", "err", err)
	}

	hub.CloseAll()

	// Only now, with every table closed and its final scoreboard submitted, is
	// there a complete set of writes to flush. Draining before CloseAll would
	// leave exactly the games that ended during shutdown unrecorded.
	drainCtx, cancelDrain := context.WithTimeout(context.Background(), cfg.ShutdownGrace)
	defer cancelDrain()
	if err := recorder.Shutdown(drainCtx); err != nil {
		log.Warn("some finished games were not written before shutdown", "err", err)
	}

	closeRooms()
	log.Info("stopped")
	return nil
}
