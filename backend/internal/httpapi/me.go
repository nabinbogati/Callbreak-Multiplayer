package httpapi

import (
	"errors"
	"net/http"
	"strconv"

	"github.com/nabin31bogati/callbreak/backend/internal/db"
	"github.com/nabin31bogati/callbreak/backend/internal/protocol"
)

// History paging bounds. The default is a screenful; the ceiling is what keeps
// one request from turning into an unbounded scan, and it is clamped rather
// than rejected so a client asking for too much still gets a useful page.
const (
	defaultHistoryLimit = 20
	maxHistoryLimit     = 50
)

// handleGetMe returns the caller's profile.
func (s *Server) handleGetMe(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	userID := userIDFrom(ctx)

	user, err := s.store.UserByID(ctx, userID)
	if err != nil {
		if errors.Is(err, db.ErrNotFound) {
			// The token is well-formed but names nobody: the account was merged
			// away or removed. That is a credentials problem, not a missing page.
			writeError(w, http.StatusUnauthorized, codeUnauthorized, msgUnauthorized)
			return
		}
		storeError(w, s.log, "UserByID", err)
		return
	}

	writeJSON(w, http.StatusOK, userResponse{
		User: newUserJSON(user, s.identitiesOf(ctx, user.ID)),
	})
}

// handleMergeAbandoned folds the abandoned guest account {id} into the caller
// — the "bring those games with me" half of the choice the profile offers right
// after a restore. The store only accepts an account with no identities (a
// restore's residue), so this can never absorb a signed-in account.
func (s *Server) handleMergeAbandoned(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !validAccountID(id) {
		writeError(w, http.StatusBadRequest, codeBadRequest,
			"That account id does not look right.")
		return
	}

	ctx := r.Context()
	user, err := s.store.MergeGuest(ctx, userIDFrom(ctx), id)
	if err != nil {
		if errors.Is(err, db.ErrNotFound) {
			// The offer is stale — already merged, already discarded, or the id
			// was never an abandoned account at all. A 404 with this reading
			// covers all three without confirming which.
			writeError(w, http.StatusNotFound, codeNotFound,
				"That account is already gone.")
			return
		}
		storeError(w, s.log, "MergeGuest", err)
		return
	}

	writeJSON(w, http.StatusOK, userResponse{
		User: newUserJSON(user, s.identitiesOf(ctx, user.ID)),
	})
}

// handleDeleteAbandoned discards the abandoned guest account {id} — the "leave
// those games behind" half of the post-restore choice. Games shared with other
// humans survive, with the discarded install's seat unattributed; only a
// no-identity guest is deletable at all.
func (s *Server) handleDeleteAbandoned(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !validAccountID(id) {
		writeError(w, http.StatusBadRequest, codeBadRequest,
			"That account id does not look right.")
		return
	}

	if err := s.store.DeleteAbandoned(r.Context(), id); err != nil {
		if errors.Is(err, db.ErrNotFound) {
			writeError(w, http.StatusNotFound, codeNotFound,
				"That account is already gone.")
			return
		}
		storeError(w, s.log, "DeleteAbandoned", err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// handlePatchMe changes the display name.
func (s *Server) handlePatchMe(w http.ResponseWriter, r *http.Request) {
	var req patchMeRequest
	if !decodeBody(w, r, maxAuthBody, &req) {
		return
	}
	if req.DisplayName == nil {
		// An absent field is a malformed request rather than a rename to
		// nothing — silently renaming somebody because their client sent {} is
		// exactly the kind of thing nobody can debug from the outside.
		writeError(w, http.StatusBadRequest, codeBadRequest,
			"Send a displayName to change your name.")
		return
	}

	// The same sanitiser the socket uses on a join: control characters stripped,
	// trimmed, capped at 24 runes, never empty.
	name := protocol.SanitizeName(*req.DisplayName)

	ctx := r.Context()
	user, err := s.store.UpdateDisplayName(ctx, userIDFrom(ctx), name)
	if err != nil {
		if errors.Is(err, db.ErrNotFound) {
			writeError(w, http.StatusUnauthorized, codeUnauthorized, msgUnauthorized)
			return
		}
		storeError(w, s.log, "UpdateDisplayName", err)
		return
	}

	writeJSON(w, http.StatusOK, userResponse{
		User: newUserJSON(user, s.identitiesOf(ctx, user.ID)),
	})
}

// handleStats returns every scope in db.AllScopes order.
//
// The store already promises that, but the promise is re-imposed here: the
// profile tab renders a fixed set of cards, and a brand-new account with no
// rows at all must produce the same five entries as a veteran's. Filling the
// gaps server-side is what lets the client render without null checks.
func (s *Server) handleStats(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	rows, err := s.store.Stats(ctx, userIDFrom(ctx))
	if err != nil {
		storeError(w, s.log, "Stats", err)
		return
	}

	byScope := make(map[string]db.Stats, len(rows))
	for _, row := range rows {
		byScope[row.Scope] = row
	}

	scopes := make([]statsJSON, 0, len(db.AllScopes))
	for _, scope := range db.AllScopes {
		row, ok := byScope[scope]
		if !ok {
			row = db.Stats{Scope: scope}
		}
		// Trust the order asked for, not the order stored.
		row.Scope = scope
		scopes = append(scopes, newStatsJSON(row))
	}

	writeJSON(w, http.StatusOK, statsResponse{Scopes: scopes})
}

// handleHistory returns one page of the caller's games, newest first.
func (s *Server) handleHistory(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	query := r.URL.Query()

	mode := db.Mode(query.Get("mode"))
	if mode != "" && !mode.Valid() {
		writeError(w, http.StatusBadRequest, codeBadRequest,
			"That is not a game mode. Use bots, private, online or lan.")
		return
	}

	limit, err := parseLimit(query.Get("limit"))
	if err != nil {
		writeError(w, http.StatusBadRequest, codeBadRequest,
			"That limit is not a number.")
		return
	}

	page, err := s.store.History(ctx, db.HistoryQuery{
		UserID: userIDFrom(ctx),
		Mode:   mode,
		Limit:  limit,
		// The cursor is the store's own keyset token; it goes back exactly as it
		// came out. Interpreting it here would make this package care about a
		// pagination scheme that is not its business.
		Cursor: query.Get("cursor"),
	})
	if err != nil {
		storeError(w, s.log, "History", err)
		return
	}

	games := make([]gameSummaryJSON, 0, len(page.Games))
	for _, g := range page.Games {
		games = append(games, newGameSummaryJSON(g))
	}

	writeJSON(w, http.StatusOK, historyResponse{
		Games:      games,
		NextCursor: page.NextCursor,
	})
}

// parseLimit clamps to 1..50, defaulting to a screenful. Out-of-range numbers
// are clamped rather than refused — a client asking for 500 wants "as many as
// you'll give me", and there is no reason to fail its history screen over it.
// Something that is not a number at all is a different matter: that is a bug in
// the caller and it should hear about it.
func parseLimit(raw string) (int, error) {
	if raw == "" {
		return defaultHistoryLimit, nil
	}
	n, err := strconv.Atoi(raw)
	if err != nil {
		return 0, err
	}
	if n < 1 {
		return 1, nil
	}
	if n > maxHistoryLimit {
		return maxHistoryLimit, nil
	}
	return n, nil
}
