package db

import (
	"context"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
)

const (
	// defaultHistoryLimit is a screenful.
	defaultHistoryLimit = 20
	// maxHistoryLimit caps what a client can ask for. Each game drags four seat
	// rows behind it, so an unbounded limit is an unbounded second query.
	maxHistoryLimit = 100
)

// historySelect is the page-of-games half of History.
//
// Everything in the WHERE and the ORDER BY comes from game_seats, including
// mode and finished_at, which is why those two are denormalised onto the seat.
// The plan is then a single backwards range scan of game_seats_history_idx with
// no sort node above it: the index already holds the rows in the order asked
// for, so LIMIT stops the scan after twenty-one rows however many thousand
// games the player has. games is joined only to decorate the rows that survive.
//
// The mode and cursor predicates are appended below rather than written inline
// as a parameter-dependent OR. A predicate whose truth depends on a parameter
// is opaque to the planner, and it would give up the very index the mode filter
// exists to use.
const historySelect = `
SELECT gs.game_id, gs.seat, gs.final_score, gs.place, gs.total_bid, gs.total_tricks,
       gs.mode, gs.finished_at,
       g.room_code, g.completed, g.started_at, g.hands_total
FROM game_seats gs
JOIN games g ON g.id = gs.game_id
WHERE gs.user_id = $1`

// History returns one page of a player's games, newest first.
func (p *Postgres) History(ctx context.Context, q HistoryQuery) (HistoryPage, error) {
	if !validUUID(q.UserID) {
		return HistoryPage{}, ErrNotFound
	}
	if q.Mode != "" && !q.Mode.Valid() {
		return HistoryPage{}, ErrNotFound
	}

	limit := q.Limit
	if limit <= 0 {
		limit = defaultHistoryLimit
	}
	if limit > maxHistoryLimit {
		limit = maxHistoryLimit
	}

	sql := historySelect
	args := []any{q.UserID}
	if q.Mode != "" {
		args = append(args, string(q.Mode))
		sql += "\n  AND gs.mode = $2"
	}
	if q.Cursor != "" {
		c, err := decodeCursor(q.Cursor)
		if err != nil {
			return HistoryPage{}, err
		}
		// A row comparison rather than two ANDed predicates. Only the tuple
		// form maps onto one index range; `finished_at <= t AND (finished_at <
		// t OR id < g)` describes the same rows but the planner has to filter
		// rather than seek.
		args = append(args, c.FinishedAt, c.GameID)
		sql += rowCursorPredicate(len(args))
	}
	// One row more than asked for. If it comes back there is another page, and
	// it is discarded — cheaper and more honest than a second COUNT that could
	// disagree with the page it describes.
	args = append(args, limit+1)
	sql += "\nORDER BY gs.finished_at DESC, gs.game_id DESC\nLIMIT $" + strconv.Itoa(len(args))

	rows, err := p.pool.Query(ctx, sql, args...)
	if err != nil {
		return HistoryPage{}, p.fail("read history", err)
	}
	games, err := scanSummaries(rows)
	if err != nil {
		return HistoryPage{}, p.fail("read history", err)
	}

	page := HistoryPage{Games: games}
	if len(page.Games) > limit {
		last := page.Games[limit-1]
		page.NextCursor = cursor{FinishedAt: last.FinishedAt, GameID: last.GameID}.encode()
		page.Games = page.Games[:limit]
	}
	if err := p.attachPlayers(ctx, page.Games); err != nil {
		return HistoryPage{}, err
	}
	return page, nil
}

// rowCursorPredicate builds the keyset comparison for the two args ending at n.
func rowCursorPredicate(n int) string {
	return "\n  AND (gs.finished_at, gs.game_id) < ($" + strconv.Itoa(n-1) + ", $" + strconv.Itoa(n) + ")"
}

// scanSummaries reads the page-of-games result set.
func scanSummaries(rows pgx.Rows) ([]GameSummary, error) {
	defer rows.Close()

	out := []GameSummary{}
	for rows.Next() {
		var g GameSummary
		var mode string
		if err := rows.Scan(&g.GameID, &g.Seat, &g.FinalScore, &g.Place, &g.TotalBid,
			&g.TotalTricks, &mode, &g.FinishedAt,
			&g.RoomCode, &g.Completed, &g.StartedAt, &g.HandsTotal); err != nil {
			return nil, err
		}
		g.Mode = Mode(mode)
		out = append(out, g)
	}
	return out, rows.Err()
}

// attachPlayers fills in the other three seats for a page of games.
//
// One query for the whole page, not one per game. A history screen showing
// twenty games would otherwise issue twenty-one queries, and the N+1 would only
// become visible under the load where it hurts.
func (p *Postgres) attachPlayers(ctx context.Context, games []GameSummary) error {
	if len(games) == 0 {
		return nil
	}
	ids := make([]string, len(games))
	index := make(map[string]int, len(games))
	for i, g := range games {
		ids[i] = g.GameID
		index[g.GameID] = i
	}

	rows, err := p.pool.Query(ctx, `
		SELECT game_id, seat, user_id, display_name, is_bot, final_score, place
		FROM game_seats
		WHERE game_id = ANY($1::uuid[])
		ORDER BY game_id, seat`, ids)
	if err != nil {
		return p.fail("read history", err)
	}
	defer rows.Close()

	for rows.Next() {
		var gameID string
		var pl GamePlayer
		var userID *string
		if err := rows.Scan(&gameID, &pl.Seat, &userID, &pl.DisplayName, &pl.IsBot,
			&pl.FinalScore, &pl.Place); err != nil {
			return p.fail("read history", err)
		}
		if userID != nil {
			pl.UserID = *userID
		}
		if i, ok := index[gameID]; ok {
			games[i].Players = append(games[i].Players, pl)
		}
	}
	return p.fail("read history", rows.Err())
}

// Game returns one game with its per-hand scoreboard, from userID's point of
// view.
//
// The user is part of the lookup, not a check applied afterwards. A game id is
// a uuid and so is unguessable, but "unguessable" is not an authorisation
// model: ids get shared, logged and pasted into support tickets, and none of
// that should hand over somebody else's results.
func (p *Postgres) Game(ctx context.Context, userID, gameID string) (GameDetail, error) {
	if !validUUID(userID) || !validUUID(gameID) {
		return GameDetail{}, ErrNotFound
	}

	var d GameDetail
	var mode string
	err := p.pool.QueryRow(ctx, `
		SELECT gs.game_id, gs.seat, gs.final_score, gs.place, gs.total_bid, gs.total_tricks,
		       gs.mode, gs.finished_at,
		       g.room_code, g.completed, g.started_at, g.hands_total
		FROM game_seats gs
		JOIN games g ON g.id = gs.game_id
		WHERE gs.game_id = $1 AND gs.user_id = $2`, gameID, userID,
	).Scan(&d.GameID, &d.Seat, &d.FinalScore, &d.Place, &d.TotalBid, &d.TotalTricks,
		&mode, &d.FinishedAt, &d.RoomCode, &d.Completed, &d.StartedAt, &d.HandsTotal)
	if err != nil {
		// pgx.ErrNoRows here means either "no such game" or "not your game",
		// and the caller is told neither.
		return GameDetail{}, p.fail("read game", err)
	}
	d.Mode = Mode(mode)

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
		return GameDetail{}, p.fail("read game", err)
	}
	defer rows.Close()

	d.Hands = []HandRecord{}
	for rows.Next() {
		var h HandRecord
		if err := rows.Scan(&h.HandIndex, &h.Seat, &h.Bid, &h.TricksWon,
			&h.ScoreDelta, &h.RunningTotal); err != nil {
			return GameDetail{}, p.fail("read game", err)
		}
		d.Hands = append(d.Hands, h)
	}
	if err := rows.Err(); err != nil {
		return GameDetail{}, p.fail("read game", err)
	}
	return d, nil
}

// Stats returns every scope in AllScopes order, synthesising zeroed rows for
// scopes the player has never played.
//
// Always five rows, always in the same order, so the profile screen renders its
// scope selector from the response without needing to know what the scopes are
// or which of them happen to have data. A missing row and a row of zeroes mean
// the same thing to a reader; making the caller handle both would be a trap.
func (p *Postgres) Stats(ctx context.Context, userID string) ([]Stats, error) {
	if !validUUID(userID) {
		return nil, ErrNotFound
	}

	rows, err := p.pool.Query(ctx, `
		SELECT scope, games_played, games_completed, games_won, games_lost, best_place,
		       hands_played, total_bid, bids_made, bids_failed, highest_bid, total_tricks,
		       total_score,
		       COALESCE(highest_game_score, 0), COALESCE(lowest_game_score, 0),
		       COALESCE(highest_hand_score, 0),
		       current_win_streak, best_win_streak, last_played_at
		FROM user_stats WHERE user_id = $1`, userID)
	if err != nil {
		return nil, p.fail("read statistics", err)
	}
	defer rows.Close()

	found := make(map[string]Stats, len(AllScopes))
	for rows.Next() {
		var s Stats
		var lastPlayed *time.Time
		if err := rows.Scan(&s.Scope, &s.GamesPlayed, &s.GamesCompleted, &s.GamesWon,
			&s.GamesLost, &s.BestPlace, &s.HandsPlayed, &s.TotalBid, &s.BidsMade,
			&s.BidsFailed, &s.HighestBid, &s.TotalTricks, &s.TotalScore,
			&s.HighestGameScore, &s.LowestGameScore, &s.HighestHandScore,
			&s.CurrentWinStreak, &s.BestWinStreak, &lastPlayed); err != nil {
			return nil, p.fail("read statistics", err)
		}
		if lastPlayed != nil {
			s.LastPlayedAt = *lastPlayed
		}
		found[s.Scope] = s
	}
	if err := rows.Err(); err != nil {
		return nil, p.fail("read statistics", err)
	}

	out := make([]Stats, 0, len(AllScopes))
	for _, scope := range AllScopes {
		s, ok := found[scope]
		if !ok {
			s = Stats{Scope: scope}
		}
		out = append(out, s)
	}
	return out, nil
}
