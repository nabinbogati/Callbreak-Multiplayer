package db

import (
	"context"
	"fmt"
	"io/fs"
	"log/slog"
	"sort"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/nabin31bogati/callbreak/backend/migrations"
)

// migrateLockKey is the argument to pg_advisory_lock. Advisory locks share one
// 64-bit namespace with everything else in the database, so the value is an
// arbitrary constant chosen to be recognisable in pg_locks rather than
// something meaningful — "cbrk" in hex, with room to spare.
const migrateLockKey int64 = 0x63627263_6d696772

// migration is one numbered file from the embedded FS.
type migration struct {
	version int
	name    string
	sql     string
}

// migrate brings the database up to the schema embedded in the binary.
//
// Three properties matter, and each costs one line:
//
//   - Forward only. There are no down migrations, because a down migration is a
//     script nobody has ever run against production data and it is reached only
//     in the moment you can least afford to find that out. A mistake is fixed by
//     a new numbered file.
//   - Serialised across replicas. Two pods starting together would otherwise
//     both see an empty schema_migrations and both try to CREATE TABLE users.
//     A session-level advisory lock held for the whole run means the second one
//     waits, then finds there is nothing left to do.
//   - One transaction per migration. A file that fails leaves the database on
//     the last version that fully applied, never half of the next one.
func migrate(ctx context.Context, pool *pgxpool.Pool, log *slog.Logger) error {
	all, err := loadMigrations()
	if err != nil {
		return err
	}

	// The lock is session scoped, so it has to be taken and released on one
	// pinned connection rather than on the pool.
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return fmt.Errorf("db: acquiring a connection for migrations: %w", err)
	}
	defer conn.Release()

	if _, err := conn.Exec(ctx, `SELECT pg_advisory_lock($1)`, migrateLockKey); err != nil {
		return fmt.Errorf("db: taking the migration lock: %w", err)
	}
	defer func() {
		// Releasing explicitly rather than relying on the connection closing
		// keeps the lock out of pg_locks for the life of the pool, which makes
		// a genuinely stuck migration easy to spot.
		if _, err := conn.Exec(context.WithoutCancel(ctx),
			`SELECT pg_advisory_unlock($1)`, migrateLockKey); err != nil {
			log.Warn("could not release the migration lock", "err", err)
		}
	}()

	// The ledger has to exist before it can be consulted, and creating it is
	// itself idempotent, so it sits outside the numbered set.
	const ledger = `
		CREATE TABLE IF NOT EXISTS schema_migrations (
			version     integer PRIMARY KEY,
			name        text        NOT NULL,
			applied_at  timestamptz NOT NULL DEFAULT now()
		)`
	if _, err := conn.Exec(ctx, ledger); err != nil {
		return fmt.Errorf("db: creating schema_migrations: %w", err)
	}

	applied, err := appliedVersions(ctx, conn.Conn())
	if err != nil {
		return err
	}

	for _, m := range all {
		if _, done := applied[m.version]; done {
			continue
		}
		if err := applyOne(ctx, conn.Conn(), m); err != nil {
			return err
		}
		log.Info("applied migration", "version", m.version, "name", m.name)
	}
	return nil
}

// applyOne runs a single migration and records it, atomically. Recording the
// version in the same transaction as the DDL is what makes a crash mid-run
// safe: either both happened or neither did.
func applyOne(ctx context.Context, conn *pgx.Conn, m migration) error {
	tx, err := conn.Begin(ctx)
	if err != nil {
		return fmt.Errorf("db: migration %04d: %w", m.version, err)
	}
	defer tx.Rollback(context.WithoutCancel(ctx)) //nolint:errcheck // no-op after commit

	if _, err := tx.Exec(ctx, m.sql); err != nil {
		return fmt.Errorf("db: migration %04d (%s): %w", m.version, m.name, err)
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO schema_migrations (version, name) VALUES ($1, $2)`,
		m.version, m.name,
	); err != nil {
		return fmt.Errorf("db: recording migration %04d: %w", m.version, err)
	}
	return tx.Commit(ctx)
}

func appliedVersions(ctx context.Context, conn *pgx.Conn) (map[int]struct{}, error) {
	rows, err := conn.Query(ctx, `SELECT version FROM schema_migrations`)
	if err != nil {
		return nil, fmt.Errorf("db: reading schema_migrations: %w", err)
	}
	defer rows.Close()

	applied := make(map[int]struct{})
	for rows.Next() {
		var v int
		if err := rows.Scan(&v); err != nil {
			return nil, fmt.Errorf("db: reading schema_migrations: %w", err)
		}
		applied[v] = struct{}{}
	}
	return applied, rows.Err()
}

// loadMigrations reads and orders the embedded files. Filenames are
// NNNN_name.sql; the number is the version and ordering is numeric rather than
// lexical so that migration 10 cannot sort before migration 9 if someone ever
// widens the prefix.
func loadMigrations() ([]migration, error) {
	entries, err := fs.ReadDir(migrations.FS, ".")
	if err != nil {
		return nil, fmt.Errorf("db: reading embedded migrations: %w", err)
	}

	out := make([]migration, 0, len(entries))
	seen := make(map[int]string, len(entries))
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".sql") {
			continue
		}
		prefix, rest, ok := strings.Cut(strings.TrimSuffix(e.Name(), ".sql"), "_")
		if !ok {
			return nil, fmt.Errorf("db: migration %q is not named NNNN_description.sql", e.Name())
		}
		version, err := strconv.Atoi(prefix)
		if err != nil {
			return nil, fmt.Errorf("db: migration %q has a non-numeric version: %w", e.Name(), err)
		}
		if other, dup := seen[version]; dup {
			return nil, fmt.Errorf("db: migrations %q and %q share version %d", other, e.Name(), version)
		}
		seen[version] = e.Name()

		body, err := fs.ReadFile(migrations.FS, e.Name())
		if err != nil {
			return nil, fmt.Errorf("db: reading migration %q: %w", e.Name(), err)
		}
		out = append(out, migration{version: version, name: rest, sql: string(body)})
	}

	sort.Slice(out, func(i, j int) bool { return out[i].version < out[j].version })
	return out, nil
}
