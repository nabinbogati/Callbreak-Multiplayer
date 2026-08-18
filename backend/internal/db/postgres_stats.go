package db

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// statsDelta is one seat's contribution to one scope. Every finished game
// produces two of these per human seat — one for the mode, one for ScopeAll —
// and they are the only input the counters ever take.
type statsDelta struct {
	userID string
	scope  string

	completed bool
	won       bool // completed and placed first
	lost      bool // completed and placed below first
	place     int  // 0 when the game never ranked anyone

	handsPlayed int
	totalBid    int
	bidsMade    int
	bidsFailed  int
	highestBid  int
	totalTricks int
	finalScore  float64

	// gameScore and handScore are nil for an abandoned game. An unfinished
	// table must never set a score record (§2.3), and nil rather than 0 says so
	// without pretending a zero was scored — Call Break scores go negative, so
	// 0 is a real value and cannot double as "no data".
	gameScore *float64
	handScore *float64

	finishedAt time.Time
}

// applyStatsSQL folds one delta into one counter row.
//
// Every figure is computed by the database from the row already there and the
// row being proposed. Reading the counters into Go, adding, and writing them
// back would lose an update the first time two of a player's games finished at
// the same instant on two replicas — and "two games finishing at once" is not
// exotic for someone playing on a phone and a tablet.
//
// The maxima are GREATEST/LEAST rather than an IF in Go for the same reason.
// Both ignore NULL arguments in Postgres, which is exactly what is wanted for
// the three nullable record columns: the first completed game sets them with no
// special case, and an abandoned game passes NULL and leaves them alone.
//
// best_place needs the extra NULLIF because there 0 is a sentinel for "never
// ranked" rather than a real place, so a plain LEAST would make every player's
// best place 0 forever.
const applyStatsSQL = `
INSERT INTO user_stats (
	user_id, scope,
	games_played, games_completed, games_won, games_lost, best_place,
	hands_played, total_bid, bids_made, bids_failed, highest_bid, total_tricks,
	total_score, highest_game_score, lowest_game_score, highest_hand_score,
	current_win_streak, best_win_streak, last_played_at
) VALUES (
	$1, $2,
	1,
	CASE WHEN $3 THEN 1 ELSE 0 END,
	CASE WHEN $4 THEN 1 ELSE 0 END,
	CASE WHEN $5 THEN 1 ELSE 0 END,
	$6,
	$7, $8, $9, $10, $11, $12,
	$13, $14, $14, $15,
	CASE WHEN $4 THEN 1 ELSE 0 END,
	CASE WHEN $4 THEN 1 ELSE 0 END,
	$16
)
ON CONFLICT (user_id, scope) DO UPDATE SET
	games_played       = user_stats.games_played + 1,
	games_completed    = user_stats.games_completed + EXCLUDED.games_completed,
	games_won          = user_stats.games_won + EXCLUDED.games_won,
	games_lost         = user_stats.games_lost + EXCLUDED.games_lost,
	best_place         = COALESCE(LEAST(NULLIF(user_stats.best_place, 0), NULLIF(EXCLUDED.best_place, 0)), 0),
	hands_played       = user_stats.hands_played + EXCLUDED.hands_played,
	total_bid          = user_stats.total_bid + EXCLUDED.total_bid,
	bids_made          = user_stats.bids_made + EXCLUDED.bids_made,
	bids_failed        = user_stats.bids_failed + EXCLUDED.bids_failed,
	highest_bid        = GREATEST(user_stats.highest_bid, EXCLUDED.highest_bid),
	total_tricks       = user_stats.total_tricks + EXCLUDED.total_tricks,
	total_score        = user_stats.total_score + EXCLUDED.total_score,
	highest_game_score = GREATEST(user_stats.highest_game_score, EXCLUDED.highest_game_score),
	lowest_game_score  = LEAST(user_stats.lowest_game_score, EXCLUDED.lowest_game_score),
	highest_hand_score = GREATEST(user_stats.highest_hand_score, EXCLUDED.highest_hand_score),
	-- A win extends the streak, a loss ends it, and an abandoned game leaves it
	-- exactly where it was: you cannot lose a streak by having the wifi drop.
	current_win_streak = CASE WHEN $4 THEN user_stats.current_win_streak + 1
	                          WHEN $5 THEN 0
	                          ELSE user_stats.current_win_streak END,
	best_win_streak    = GREATEST(user_stats.best_win_streak,
	                              CASE WHEN $4 THEN user_stats.current_win_streak + 1
	                                   WHEN $5 THEN 0
	                                   ELSE user_stats.current_win_streak END),
	last_played_at     = GREATEST(user_stats.last_played_at, EXCLUDED.last_played_at)`

// applyStats writes one delta. It must run inside the transaction that inserted
// the game, so that a game and the counters it moved are committed together or
// not at all.
func (p *Postgres) applyStats(ctx context.Context, tx pgx.Tx, d statsDelta) error {
	_, err := tx.Exec(ctx, applyStatsSQL,
		d.userID, d.scope,
		d.completed, d.won, d.lost, d.place,
		d.handsPlayed, d.totalBid, d.bidsMade, d.bidsFailed, d.highestBid, d.totalTricks,
		d.finalScore, d.gameScore, d.handScore,
		d.finishedAt,
	)
	return p.fail("update statistics", err)
}

// recomputeStatsSQL rebuilds every scope for one user from the games they
// actually played.
//
// This is the authority the incremental path is an optimisation of: if the two
// ever disagree, this one is right. It exists because MergeUsers cannot add two
// users' counters together — a best streak of three plus a best streak of three
// is not six, and neither is a highest score — and because having it means a
// counter corrupted by a bug is one function call away from being repaired.
//
// The only interesting part is the streaks, which are a gaps-and-islands
// problem: number the user's completed games in finish order, number them again
// within wins and losses separately, and the difference is constant across a
// run of identical results. Grouping by that difference turns every unbroken
// streak into one row. The best streak is the longest winning run; the current
// streak is the winning run that reaches the last game, if the last game was a
// win.
const recomputeStatsSQL = `
WITH seat AS (
	SELECT gs.game_id, gs.seat, gs.place, gs.final_score, gs.total_bid,
	       gs.total_tricks, gs.hands_made, gs.mode, gs.finished_at, g.completed
	FROM game_seats gs
	JOIN games g ON g.id = gs.game_id
	WHERE gs.user_id = $1
), hand AS (
	SELECT gh.game_id, gh.seat,
	       count(*)::int       AS hands_played,
	       max(gh.bid)::int    AS highest_bid,
	       max(gh.score_delta) AS highest_hand_score
	FROM game_hands gh
	JOIN seat s ON s.game_id = gh.game_id AND s.seat = gh.seat
	GROUP BY gh.game_id, gh.seat
), scoped AS (
	-- Every game counts once under its own mode and once under 'all', which is
	-- what makes the two scopes stay in step with each other by construction.
	SELECT sc.scope, s.game_id, s.place, s.final_score, s.total_bid, s.total_tricks,
	       s.hands_made, s.completed, s.finished_at,
	       COALESCE(h.hands_played, 0) AS hands_played,
	       COALESCE(h.highest_bid, 0)  AS highest_bid,
	       h.highest_hand_score
	FROM seat s
	LEFT JOIN hand h ON h.game_id = s.game_id AND h.seat = s.seat
	CROSS JOIN LATERAL (VALUES (s.mode), ('all')) AS sc(scope)
), agg AS (
	SELECT scope,
	       count(*)::int                                              AS games_played,
	       (count(*) FILTER (WHERE completed))::int                   AS games_completed,
	       (count(*) FILTER (WHERE completed AND place = 1))::int     AS games_won,
	       (count(*) FILTER (WHERE completed AND place > 1))::int     AS games_lost,
	       COALESCE(min(place) FILTER (WHERE place > 0), 0)::smallint AS best_place,
	       COALESCE(sum(hands_played), 0)::int                        AS hands_played,
	       COALESCE(sum(total_bid), 0)::int                           AS total_bid,
	       COALESCE(sum(hands_made), 0)::int                          AS bids_made,
	       COALESCE(sum(hands_played - hands_made), 0)::int           AS bids_failed,
	       COALESCE(max(highest_bid), 0)::smallint                    AS highest_bid,
	       COALESCE(sum(total_tricks), 0)::int                        AS total_tricks,
	       COALESCE(sum(final_score), 0)                              AS total_score,
	       max(final_score) FILTER (WHERE completed)                  AS highest_game_score,
	       min(final_score) FILTER (WHERE completed)                  AS lowest_game_score,
	       max(highest_hand_score) FILTER (WHERE completed)           AS highest_hand_score,
	       max(finished_at)                                           AS last_played_at
	FROM scoped
	GROUP BY scope
), ordered AS (
	SELECT scope, (place = 1) AS won,
	       row_number() OVER w AS rn,
	       row_number() OVER w
	         - row_number() OVER (PARTITION BY scope, (place = 1) ORDER BY finished_at, game_id) AS island
	FROM scoped
	WHERE completed AND place > 0
	WINDOW w AS (PARTITION BY scope ORDER BY finished_at, game_id)
), runs AS (
	SELECT scope, won, count(*)::int AS len, max(rn) AS last_rn
	FROM ordered
	GROUP BY scope, won, island
), streak AS (
	SELECT r.scope,
	       COALESCE(max(r.len) FILTER (WHERE r.won), 0)                       AS best,
	       COALESCE(max(r.len) FILTER (WHERE r.won AND r.last_rn = t.total), 0) AS current
	FROM runs r
	JOIN (SELECT scope, max(rn) AS total FROM ordered GROUP BY scope) t ON t.scope = r.scope
	GROUP BY r.scope, t.total
)
INSERT INTO user_stats (
	user_id, scope,
	games_played, games_completed, games_won, games_lost, best_place,
	hands_played, total_bid, bids_made, bids_failed, highest_bid, total_tricks,
	total_score, highest_game_score, lowest_game_score, highest_hand_score,
	current_win_streak, best_win_streak, last_played_at
)
SELECT $1, a.scope,
       a.games_played, a.games_completed, a.games_won, a.games_lost, a.best_place,
       a.hands_played, a.total_bid, a.bids_made, a.bids_failed, a.highest_bid, a.total_tricks,
       a.total_score, a.highest_game_score, a.lowest_game_score, a.highest_hand_score,
       COALESCE(s.current, 0), COALESCE(s.best, 0), a.last_played_at
FROM agg a
LEFT JOIN streak s ON s.scope = a.scope`

// recomputeStats rebuilds userID's counters from game_seats and game_hands.
//
// Delete-then-insert rather than an upsert per scope: a scope the user no
// longer has any games in must end up absent, not stale, and after a merge that
// is a real possibility. Both statements are in the caller's transaction, so
// nobody ever observes the gap.
func (p *Postgres) recomputeStats(ctx context.Context, tx pgx.Tx, userID string) error {
	if _, err := tx.Exec(ctx, `DELETE FROM user_stats WHERE user_id = $1`, userID); err != nil {
		return p.fail("recompute statistics", err)
	}
	if _, err := tx.Exec(ctx, recomputeStatsSQL, userID); err != nil {
		return p.fail("recompute statistics", err)
	}
	return nil
}
