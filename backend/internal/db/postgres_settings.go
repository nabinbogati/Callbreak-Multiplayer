package db

import (
	"context"

	"github.com/jackc/pgx/v5"
)

// Runtime settings live in one small key/value table so that the settings
// package can round-trip them without either side knowing the other's schema.
// These two methods satisfy the settings package's Persistence interface by
// shape — the interface lives there precisely so db does not have to import
// it (settings imports room, which imports db; a db->settings import would be
// a cycle).

// LoadSettings returns every runtime setting row, keyed by its wire name.
// An empty map (not nil) means no override is stored.
func (p *Postgres) LoadSettings(ctx context.Context) (map[string]string, error) {
	rows, err := p.pool.Query(ctx, `SELECT key, value FROM runtime_settings`)
	if err != nil {
		return nil, p.fail("load runtime settings", err)
	}
	defer rows.Close()

	out := map[string]string{}
	for rows.Next() {
		var key, value string
		if err := rows.Scan(&key, &value); err != nil {
			return nil, p.fail("load runtime settings", err)
		}
		out[key] = value
	}
	return out, p.fail("load runtime settings", rows.Err())
}

// SaveSettings stores a full settings snapshot, replacing whatever was there
// before. The row set is kept exactly equal to the map, so a dashboard that
// edits one field still ends up with a coherent whole.
func (p *Postgres) SaveSettings(ctx context.Context, values map[string]string) error {
	return p.inTx(ctx, "save runtime settings", func(tx pgx.Tx) error {
		if len(values) == 0 {
			_, err := tx.Exec(ctx, `DELETE FROM runtime_settings`)
			return err
		}

		keys := make([]string, 0, len(values))
		for k := range values {
			keys = append(keys, k)
		}
		if _, err := tx.Exec(ctx,
			`DELETE FROM runtime_settings WHERE key <> ALL($1::text[])`, keys); err != nil {
			return err
		}
		for key, value := range values {
			if _, err := tx.Exec(ctx, `
				INSERT INTO runtime_settings (key, value, updated_at)
				VALUES ($1, $2, now())
				ON CONFLICT (key) DO UPDATE
				SET value = EXCLUDED.value, updated_at = now()`, key, value); err != nil {
				return err
			}
		}
		return nil
	})
}
