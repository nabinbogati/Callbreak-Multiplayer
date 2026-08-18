package db

import (
	"context"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5"
)

// Admin history bounds. The list is paginated over the whole database, so the
// cap exists for the same reason History has one: an unbounded page is an
// unbounded response.
const (
	adminDefaultGameLimit = 20
	adminMaxGameLimit     = 100
)

// adminListSelect reads the game row only; players come from game_seats in a
// second query (attachPlayers), exactly like the per-player history path.
const adminListSelect = `
SELECT g.id, g.mode, g.source, g.room_code, g.completed, g.started_at,
       g.finished_at, g.hands_total
FROM games g`

// AdminGames lists every recorded game across all accounts, newest first.
//
// Where History filters by a user's seat, this walks the games table itself —
// there is no user, because there is no "you". The keyset cursor and the
// one-row-more limiter are the same scheme as History: newest first, tuple
// comparison on (finished_at, id), so a game landing mid-scroll never shifts
// the page.
func (p *Postgres) AdminGames(ctx context.Context, q AdminGameQuery) (AdminGamePage, error) {
	if q.Mode != "" && !q.Mode.Valid() {
		return AdminGamePage{}, ErrNotFound
	}
	if q.Source != "" && q.Source != SourceServer && q.Source != SourceClient {
		return AdminGamePage{}, ErrNotFound
	}

	limit := q.Limit
	if limit <= 0 {
		limit = adminDefaultGameLimit
	}
	if limit > adminMaxGameLimit {
		limit = adminMaxGameLimit
	}

	args := []any{}
	where := []string{}
	if q.Mode != "" {
		args = append(args, string(q.Mode))
		where = append(where, "g.mode = $"+strconv.Itoa(len(args)))
	}
	if q.Source != "" {
		args = append(args, string(q.Source))
		where = append(where, "g.source = $"+strconv.Itoa(len(args)))
	}
	if q.Cursor != "" {
		c, err := decodeCursor(q.Cursor)
		if err != nil {
			return AdminGamePage{}, err
		}
		args = append(args, c.FinishedAt, c.GameID)
		where = append(where, "(g.finished_at, g.id) < ($"+
			strconv.Itoa(len(args)-1)+", $"+strconv.Itoa(len(args))+")")
	}

	sql := adminListSelect
	if len(where) > 0 {
		sql += "\nWHERE " + strings.Join(where, "\n  AND ")
	}
	args = append(args, limit+1)
	sql += "\nORDER BY g.finished_at DESC, g.id DESC\nLIMIT $" + strconv.Itoa(len(args))

	rows, err := p.pool.Query(ctx, sql, args...)
	if err != nil {
		return AdminGamePage{}, p.fail("read admin history", err)
	}
	games, err := scanAdminSummaries(rows)
	if err != nil {
		return AdminGamePage{}, p.fail("read admin history", err)
	}

	page := AdminGamePage{Games: games}
	if len(page.Games) > limit {
		last := page.Games[limit-1]
		page.NextCursor = cursor{FinishedAt: last.FinishedAt, GameID: last.GameID}.encode()
		page.Games = page.Games[:limit]
	}
	if err := p.attachPlayers(ctx, page.Games); err != nil {
		return AdminGamePage{}, err
	}
	return page, nil
}

// scanAdminSummaries is scanSummaries plus the source column, which the admin
// list is the only reader of.
func scanAdminSummaries(rows pgx.Rows) ([]GameSummary, error) {
	defer rows.Close()

	out := []GameSummary{}
	for rows.Next() {
		var g GameSummary
		var mode, source string
		if err := rows.Scan(&g.GameID, &mode, &source, &g.RoomCode, &g.Completed,
			&g.StartedAt, &g.FinishedAt, &g.HandsTotal); err != nil {
			return nil, err
		}
		g.Mode = Mode(mode)
		g.Source = Source(source)
		out = append(out, g)
	}
	return out, rows.Err()
}

// AdminGame returns one game with its scoreboard, without scoping to a player
// — the dashboard's detail view. The per-player check lives in Game; this is
// the deliberate exception for the admin surface.
func (p *Postgres) AdminGame(ctx context.Context, gameID string) (GameDetail, error) {
	if !validUUID(gameID) {
		return GameDetail{}, ErrNotFound
	}

	var d GameDetail
	var mode, source string
	err := p.pool.QueryRow(ctx, `
		SELECT id, mode, source, room_code, completed, started_at, finished_at, hands_total
		FROM games WHERE id = $1`, gameID,
	).Scan(&d.GameID, &mode, &source, &d.RoomCode, &d.Completed,
		&d.StartedAt, &d.FinishedAt, &d.HandsTotal)
	if err != nil {
		return GameDetail{}, p.fail("read admin game", err)
	}
	d.Mode = Mode(mode)
	d.Source = Source(source)

	page := []GameSummary{d.GameSummary}
	if err := p.attachPlayers(ctx, page); err != nil {
		return GameDetail{}, err
	}
	d.Players = page[0].Players

	rows, err := p.pool.Query(ctx, `
		SELECT hand_index, seat, bid, tricks_won, score_delta, running_total
		FROM game_hands WHERE game_id = $1
		ORDER BY hand_index, seat`, gameID)
	if err != nil {
		return GameDetail{}, p.fail("read admin game", err)
	}
	defer rows.Close()

	d.Hands = []HandRecord{}
	for rows.Next() {
		var h HandRecord
		if err := rows.Scan(&h.HandIndex, &h.Seat, &h.Bid, &h.TricksWon,
			&h.ScoreDelta, &h.RunningTotal); err != nil {
			return GameDetail{}, p.fail("read admin game", err)
		}
		d.Hands = append(d.Hands, h)
	}
	if err := rows.Err(); err != nil {
		return GameDetail{}, p.fail("read admin game", err)
	}
	return d, nil
}
