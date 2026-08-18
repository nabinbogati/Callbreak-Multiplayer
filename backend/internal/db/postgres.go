package db

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Options tunes the Postgres store. Every field has a zero value that means
// "the sensible default", so a caller that has nothing to say can pass
// Options{}.
type Options struct {
	MaxConns int32 // 0 = pgx default
	// RecordTricks turns on card-level replay. It is off by default because it
	// is roughly 260 rows a game against the four a scoreboard needs, and most
	// products never read it. GameRecord.Tricks is ignored when false.
	RecordTricks bool
}

// Postgres is the real Store. It holds a pool and no other state: everything
// that has to be consistent is made consistent by a transaction or by a single
// statement, never by a mutex in this process. That is what makes two replicas
// recording two games at the same instant a non-event.
type Postgres struct {
	pool *pgxpool.Pool
	log  *slog.Logger
	opts Options
}

var _ Store = (*Postgres)(nil)

// connectTimeout bounds the initial handshake. Startup should fail fast and
// let the caller decide whether a missing database is fatal (§5); it should not
// hang a deployment waiting on a host that is never coming back.
const connectTimeout = 10 * time.Second

// OpenPostgres connects, verifies, applies migrations and returns a live Store.
//
// Verification is a real round trip rather than a lazy pool: a caller running
// with DATABASE_REQUIRED=true wants to know at boot that the credentials work,
// not on the first game that finishes. Migrations run here for the same reason
// — one code path, no separate migration binary to keep in step with the
// deploy, and by the time this returns the schema matches the binary.
func OpenPostgres(ctx context.Context, url string, log *slog.Logger, opts Options) (Store, error) {
	if log == nil {
		log = slog.Default()
	}

	cfg, err := pgxpool.ParseConfig(url)
	if err != nil {
		// The URL almost certainly contains a password, so the caller gets the
		// shape of the problem and not the string.
		return nil, fmt.Errorf("db: DATABASE_URL is not a valid Postgres URL: %w", redactURL(err))
	}
	if opts.MaxConns > 0 {
		cfg.MaxConns = opts.MaxConns
	}
	// A connection that has been idle for half an hour is usually one a load
	// balancer or a cloud provider has already silently dropped.
	cfg.MaxConnIdleTime = 30 * time.Minute
	cfg.MaxConnLifetime = time.Hour

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("db: creating the connection pool: %w", redactURL(err))
	}

	pingCtx, cancel := context.WithTimeout(ctx, connectTimeout)
	defer cancel()
	if err := pool.Ping(pingCtx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("db: cannot reach Postgres: %w", redactURL(err))
	}

	p := &Postgres{pool: pool, log: log, opts: opts}
	if err := migrate(ctx, pool, log); err != nil {
		pool.Close()
		return nil, err
	}

	log.Info("persistence enabled", "max_conns", pool.Config().MaxConns, "record_tricks", opts.RecordTricks)
	return p, nil
}

// Enabled reports that this store persists. The Nop answers false, and callers
// branch on that rather than on a nil check.
func (p *Postgres) Enabled() bool { return true }

// Close drains the pool. Safe to call more than once.
func (p *Postgres) Close() error {
	p.pool.Close()
	return nil
}

// ------------------------------------------------------------------- errors

// fail turns a driver error into one of this package's sentinels.
//
// Nothing outside the db package should ever see a *pgconn.PgError: the socket
// layer and the REST handlers turn errors into wire codes, and a constraint
// name or a column list leaking into a client response is both a bad API and a
// small information disclosure. The detail is logged here instead, once, where
// there is enough context to say what was being attempted.
func (p *Postgres) fail(op string, err error) error {
	if err == nil {
		return nil
	}
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		return ErrNotFound
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		// Not a database problem — the caller went away or ran out of time.
		return err
	}

	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		p.log.Error("database error", "op", op, "code", pgErr.Code,
			"constraint", pgErr.ConstraintName, "msg", pgErr.Message)
		switch pgErr.Code {
		case pgerrUniqueViolation, pgerrExclusionViolation:
			return ErrConflict
		case pgerrForeignKeyViolation:
			// A seat or an identity pointing at a user that does not exist is
			// the caller's mistake, and "conflict" is the honest answer.
			return ErrConflict
		}
		return fmt.Errorf("db: %s failed", op)
	}

	p.log.Error("database error", "op", op, "err", err)
	return fmt.Errorf("db: %s failed", op)
}

// SQLSTATE classes worth naming. The rest are indistinguishable to a caller.
const (
	pgerrUniqueViolation     = "23505"
	pgerrForeignKeyViolation = "23503"
	pgerrExclusionViolation  = "23P01"
)

// redactURL strips the credentials out of a connection error. pgx helpfully
// includes the DSN it tried, password and all, and connection errors are
// exactly the ones that end up in a log aggregator.
func redactURL(err error) error {
	if err == nil {
		return nil
	}
	msg := err.Error()
	scheme := strings.Index(msg, "://")
	if scheme < 0 {
		return err
	}
	// A DSN has at most one userinfo section, and it is the part between the
	// scheme and the first '@'.
	at := strings.Index(msg[scheme:], "@")
	if at < 0 {
		return err
	}
	return errors.New(msg[:scheme+3] + "***" + msg[scheme+at:])
}

// -------------------------------------------------------------- transactions

// inTx runs fn inside a transaction, rolling back on any error or panic.
//
// pgx has pgx.BeginFunc, but this version takes the operation name so a failure
// is logged with the thing that failed rather than with "tx".
func (p *Postgres) inTx(ctx context.Context, op string, fn func(tx pgx.Tx) error) error {
	tx, err := p.pool.Begin(ctx)
	if err != nil {
		return p.fail(op, err)
	}
	defer func() {
		// Rollback after a successful commit is a documented no-op, so this
		// needs no "did we commit" flag. WithoutCancel so a cancelled request
		// still releases the transaction rather than leaking it until the
		// connection is reaped.
		_ = tx.Rollback(context.WithoutCancel(ctx))
	}()

	if err := fn(tx); err != nil {
		return err // already mapped by fn, or a sentinel it chose deliberately
	}
	if err := tx.Commit(ctx); err != nil {
		return p.fail(op, err)
	}
	return nil
}

// ------------------------------------------------------------------ cursors

// cursor is a keyset position in a history listing: the last row the client
// saw. Offsets are not used anywhere, because a game finishing while somebody
// scrolls would shift every subsequent page by one and silently hide a row.
type cursor struct {
	FinishedAt time.Time `json:"t"`
	GameID     string    `json:"g"`
}

// encode makes the cursor opaque. It is base64 of JSON rather than
// "timestamp:uuid" so that a client cannot construct one by hand and come to
// depend on its shape — the format has to stay free to change.
func (c cursor) encode() string {
	raw, err := json.Marshal(c)
	if err != nil {
		return "" // impossible for these two fields; an empty cursor just means "start again"
	}
	return base64.RawURLEncoding.EncodeToString(raw)
}

// decodeCursor parses a cursor the caller handed back. A malformed one is a
// client bug rather than a server failure, so it reports ErrNotFound and the
// REST layer answers 404 instead of 500.
func decodeCursor(s string) (cursor, error) {
	var c cursor
	raw, err := base64.RawURLEncoding.DecodeString(s)
	if err != nil {
		return c, ErrNotFound
	}
	if err := json.Unmarshal(raw, &c); err != nil {
		return c, ErrNotFound
	}
	if c.GameID == "" || c.FinishedAt.IsZero() {
		return c, ErrNotFound
	}
	return c, nil
}
