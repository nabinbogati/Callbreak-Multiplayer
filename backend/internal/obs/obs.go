// Package obs wires up logging, metrics and health endpoints.
//
// Everything the operator needs to answer "is it up, is it busy, is it slow"
// lives here so the game packages can stay free of instrumentation plumbing.
package obs

import (
	"log/slog"
	"net/http"
	"os"
	"strings"
	"sync/atomic"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// NewLogger returns a structured JSON logger, or a human-readable one in
// development where it is read by a person rather than a log pipeline.
func NewLogger(level, env string) *slog.Logger {
	opts := &slog.HandlerOptions{Level: parseLevel(level)}
	if strings.EqualFold(env, "production") {
		return slog.New(slog.NewJSONHandler(os.Stdout, opts))
	}
	return slog.New(slog.NewTextHandler(os.Stdout, opts))
}

func parseLevel(level string) slog.Level {
	switch strings.ToLower(level) {
	case "debug":
		return slog.LevelDebug
	case "warn", "warning":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}

// Metrics are process-wide, registered once at init. Counters and gauges are
// cheap enough to update on every message; the histograms are deliberately few.
var (
	RoomsActive = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "callbreak_rooms_active",
		Help: "Tables currently held in memory on this node.",
	})
	PlayersConnected = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "callbreak_players_connected",
		Help: "Open player websockets on this node.",
	})
	QueueDepth = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "callbreak_matchmaking_open_tables",
		Help: "Quickplay tables currently filling with players.",
	})
	MessagesIn = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "callbreak_ws_messages_in_total",
		Help: "Client frames accepted, by type.",
	}, []string{"type"})
	MessagesOut = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "callbreak_ws_messages_out_total",
		Help: "Server frames sent, by type.",
	}, []string{"type"})
	ProtocolErrors = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "callbreak_protocol_errors_total",
		Help: "Error frames sent to clients, by code.",
	}, []string{"code"})
	SendDrops = promauto.NewCounter(prometheus.CounterOpts{
		Name: "callbreak_ws_send_drops_total",
		Help: "Connections dropped for failing to keep up with their send queue.",
	})
	TurnTimeouts = promauto.NewCounter(prometheus.CounterOpts{
		Name: "callbreak_turn_timeouts_total",
		Help: "Turns played by the server because a human ran out of time.",
	})
	AutoplayEntered = promauto.NewCounter(prometheus.CounterOpts{
		Name: "callbreak_autoplay_entered_total",
		Help: "Seats handed to autoplay after a player let their turn clock expire.",
	})
	BotTakeovers = promauto.NewCounter(prometheus.CounterOpts{
		Name: "callbreak_bot_takeovers_total",
		Help: "Seats handed to a bot after a disconnect.",
	})
	Reconnects = promauto.NewCounter(prometheus.CounterOpts{
		Name: "callbreak_reconnects_total",
		Help: "Seats reclaimed with a resume token.",
	})
	GamesStarted = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "callbreak_games_started_total",
		Help: "Games dealt, by mode.",
	}, []string{"mode"})
	GamesFinished = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "callbreak_games_finished_total",
		Help: "Games played to the final hand, by mode.",
	}, []string{"mode"})
	RoomStep = promauto.NewHistogram(prometheus.HistogramOpts{
		Name:    "callbreak_room_step_seconds",
		Help:    "Time a room actor spends handling one message, including fan-out.",
		Buckets: prometheus.ExponentialBuckets(0.0001, 3, 8),
	})
)

// Health tracks readiness separately from liveness: a draining node is still
// alive (it must finish its games) but must stop receiving new traffic.
type Health struct {
	ready atomic.Bool
}

func NewHealth() *Health {
	h := &Health{}
	h.ready.Store(true)
	return h
}

// Drain marks the node unready so the load balancer stops sending new players.
func (h *Health) Drain() { h.ready.Store(false) }

func (h *Health) Ready() bool { return h.ready.Load() }

// Handler mounts /healthz, /readyz and /metrics on mux.
func (h *Health) Handler(mux *http.ServeMux) {
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, _ *http.Request) {
		if !h.Ready() {
			http.Error(w, "draining", http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ready"))
	})
	mux.Handle("GET /metrics", promhttp.Handler())
}
