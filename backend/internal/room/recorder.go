package room

import (
	"context"
	"errors"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"

	"github.com/nabin31bogati/callbreak/backend/internal/db"
)

// Recorder is the write-behind path from a live table to Postgres.
//
// The rule it exists to enforce is the one in docs/PERSISTENCE.md §5: a
// database problem must never stop a game. A room actor owns its table's state
// exclusively and is the only thing that can move a trick along, so it must
// never wait on a query. It therefore hands a finished game to Submit, which
// puts the record on a bounded queue and returns immediately — always, even
// when the queue is full and even when Postgres has been unreachable for an
// hour. Dropping history is a cost; stalling a table is not acceptable.
//
// Everything after Submit happens on the recorder's own goroutines. Nothing in
// here touches room state, which is what keeps the actor's single-ownership
// argument intact.
type Recorder struct {
	store   db.Store
	log     *slog.Logger
	queue   chan db.GameRecord
	quit    chan struct{}
	wg      sync.WaitGroup
	stopped atomic.Bool
	once    sync.Once

	// timeout bounds one RecordGame call. Generous — this is off the hot path —
	// but finite, so a wedged connection cannot pin a worker forever.
	timeout time.Duration
}

// Recorder tuning. The queue is deliberately small: a backlog of hundreds of
// games means the database has been gone for a long time, and the useful
// response then is to shed load loudly rather than to hoard records in memory.
const (
	recorderQueueSize    = 256
	recorderWorkers      = 2
	recorderWriteTimeout = 10 * time.Second
)

// Recorder metrics live here rather than in internal/obs so persistence
// instrumentation stays with the code that produces it.
var (
	gamesRecorded = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "callbreak_games_recorded_total",
		Help: "Games written to persistent storage, by mode.",
	}, []string{"mode"})
	gameRecordsDropped = promauto.NewCounter(prometheus.CounterOpts{
		Name: "callbreak_game_records_dropped_total",
		Help: "Games discarded without being written because the recorder queue was full or shut down.",
	})
	gameRecordsFailed = promauto.NewCounter(prometheus.CounterOpts{
		Name: "callbreak_game_records_failed_total",
		Help: "Games discarded after the write and its retry both failed.",
	})
	gameRecordQueueDepth = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "callbreak_game_record_queue_depth",
		Help: "Games waiting to be written to persistent storage.",
	})
)

// NewRecorder starts the write-behind workers.
//
// A nil or disabled store yields a live *Recorder whose Submit is a no-op, so
// the whole feature disappears cleanly when no DATABASE_URL is configured and
// callers never have to branch on it.
func NewRecorder(store db.Store, log *slog.Logger) *Recorder {
	if log == nil {
		log = slog.Default()
	}
	if store == nil || !store.Enabled() {
		return &Recorder{log: log}
	}
	r := &Recorder{
		store:   store,
		log:     log,
		queue:   make(chan db.GameRecord, recorderQueueSize),
		quit:    make(chan struct{}),
		timeout: recorderWriteTimeout,
	}
	r.wg.Add(recorderWorkers)
	for i := 0; i < recorderWorkers; i++ {
		go r.worker()
	}
	return r
}

// enabled reports whether this recorder writes anything. Nil-safe, because a
// room may legitimately have no recorder at all.
func (r *Recorder) enabled() bool { return r != nil && r.queue != nil }

// Submit queues a game to be written. It never blocks and never panics: a full
// queue means the record is dropped with a log and a metric, which is the whole
// point — the caller is a room actor with a table waiting on it.
func (r *Recorder) Submit(rec db.GameRecord) {
	if !r.enabled() || r.stopped.Load() {
		return
	}
	select {
	case r.queue <- rec:
		gameRecordQueueDepth.Set(float64(len(r.queue)))
	default:
		gameRecordsDropped.Inc()
		r.log.Warn("dropping a game record: the recorder queue is full",
			"mode", string(rec.Mode), "room", rec.RoomCode, "queue", cap(r.queue))
	}
}

// Shutdown stops accepting records and waits for the queue to drain, giving up
// when ctx expires. Anything still queued at that point is lost, which is the
// correct trade against holding a shutdown open indefinitely.
func (r *Recorder) Shutdown(ctx context.Context) error {
	if !r.enabled() {
		return nil
	}
	r.once.Do(func() {
		r.stopped.Store(true)
		close(r.quit)
	})

	done := make(chan struct{})
	go func() {
		r.wg.Wait()
		close(done)
	}()

	select {
	case <-done:
		return nil
	case <-ctx.Done():
		if pending := len(r.queue); pending > 0 {
			gameRecordsDropped.Add(float64(pending))
			r.log.Warn("recorder shutdown timed out with records still queued", "pending", pending)
		}
		return ctx.Err()
	}
}

// Close is Shutdown with a fixed grace period, for callers that have no context
// to hand.
func (r *Recorder) Close() error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return r.Shutdown(ctx)
}

func (r *Recorder) worker() {
	defer r.wg.Done()
	for {
		select {
		case rec := <-r.queue:
			gameRecordQueueDepth.Set(float64(len(r.queue)))
			r.write(rec)
		case <-r.quit:
			// Drain whatever is already queued before exiting, so a graceful
			// shutdown flushes rather than discards.
			for {
				select {
				case rec := <-r.queue:
					gameRecordQueueDepth.Set(float64(len(r.queue)))
					r.write(rec)
				default:
					return
				}
			}
		}
	}
}

// write persists one record, retrying once. A second failure is dropped: this
// is history, and the queue behind it belongs to games that are also finished.
func (r *Recorder) write(rec db.GameRecord) {
	const attempts = 2
	for attempt := 1; attempt <= attempts; attempt++ {
		ctx, cancel := context.WithTimeout(context.Background(), r.timeout)
		// Server-played games carry no ClientGameID, so the duplicate flag can
		// never be set here; it exists for the upload path.
		id, _, err := r.store.RecordGame(ctx, rec)
		cancel()

		switch {
		case err == nil:
			gamesRecorded.WithLabelValues(string(rec.Mode)).Inc()
			r.log.Debug("recorded a game",
				"game", id, "mode", string(rec.Mode), "room", rec.RoomCode,
				"completed", rec.Completed, "hands", rec.HandsTotal)
			return
		case errors.Is(err, db.ErrDisabled):
			// Persistence went away underneath us. Retrying cannot help.
			return
		case attempt < attempts:
			r.log.Warn("game record write failed, retrying",
				"mode", string(rec.Mode), "room", rec.RoomCode, "err", err)
		default:
			gameRecordsFailed.Inc()
			r.log.Error("giving up on a game record",
				"mode", string(rec.Mode), "room", rec.RoomCode, "err", err)
		}
	}
}
