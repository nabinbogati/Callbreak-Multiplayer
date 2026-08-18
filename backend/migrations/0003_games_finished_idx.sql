-- The admin history list walks the games table directly (no user filter), so
-- it needs its own path: newest-first by (finished_at, id), which is exactly
-- the ORDER BY and the keyset cursor's tuple comparison. Without this index a
-- page is a sort of the whole table, which stops being free the day the
-- history grows.
CREATE INDEX games_finished_at_idx
    ON games (finished_at DESC, id DESC);
