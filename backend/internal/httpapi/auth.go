package httpapi

import (
	"errors"
	"net/http"

	"github.com/nabin31bogati/callbreak/backend/internal/db"
	"github.com/nabin31bogati/callbreak/backend/internal/protocol"
)

// Device id bounds. Long enough that a uuid v4 fits comfortably, short enough
// that nobody is storing an essay, and restricted to characters that are safe
// everywhere they will be echoed — a log line, a URL, a query parameter.
const (
	minDeviceIDLen = 8
	maxDeviceIDLen = 128
)

// validDeviceID reports whether id is 8–128 characters of [A-Za-z0-9_-].
//
// This runs before the database is touched. The store would reject a hostile id
// too, but there is no reason to spend a round trip finding that out, and
// keeping the rule here means it is one readable function rather than an
// inference about a column type.
func validDeviceID(id string) bool {
	if len(id) < minDeviceIDLen || len(id) > maxDeviceIDLen {
		return false
	}
	for i := 0; i < len(id); i++ {
		c := id[i]
		switch {
		case c >= 'a' && c <= 'z',
			c >= 'A' && c <= 'Z',
			c >= '0' && c <= '9',
			c == '_', c == '-':
		default:
			return false
		}
	}
	return true
}

// handleDeviceAuth is the guest login path: a device id in, an account and a
// session token out. It creates the account the first time it sees the id and
// returns the same one forever after, which is what makes it safe for the
// client to call on every launch.
func (s *Server) handleDeviceAuth(w http.ResponseWriter, r *http.Request) {
	var req deviceAuthRequest
	if !decodeBody(w, r, maxAuthBody, &req) {
		return
	}
	if !validDeviceID(req.DeviceID) {
		writeError(w, http.StatusBadRequest, codeBadRequest,
			"That device id is not valid. It must be 8 to 128 letters, digits, dashes or underscores.")
		return
	}

	// One sanitiser for display names across the whole server, so a name looks
	// the same at a table as it does in a profile.
	name := protocol.SanitizeName(req.DisplayName)

	ctx := r.Context()
	user, err := s.store.ResolveIdentity(ctx, db.ProviderDevice, req.DeviceID, name)
	if err != nil {
		storeError(w, s.log, "ResolveIdentity", err)
		return
	}

	// Best-effort: a failed touch is not worth failing a sign-in over.
	if err := s.store.TouchLastSeen(ctx, user.ID); err != nil {
		s.log.Debug("could not touch last seen", "user", user.ID, "err", err)
	}

	s.writeSession(w, r, user)
}

// handleRefresh trades a valid session for a fresh one. The client calls it on
// launch, which is what keeps an active player from ever meeting the expiry.
func (s *Server) handleRefresh(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	userID := userIDFrom(ctx)

	// The token is signed, but the account behind it may since have been merged
	// away or removed; the lookup is what makes a stale token fail closed.
	user, err := s.store.UserByID(ctx, userID)
	if err != nil {
		if errors.Is(err, db.ErrNotFound) {
			writeError(w, http.StatusUnauthorized, codeUnauthorized, msgUnauthorized)
			return
		}
		storeError(w, s.log, "UserByID", err)
		return
	}
	if err := s.store.TouchLastSeen(ctx, user.ID); err != nil {
		s.log.Debug("could not touch last seen", "user", user.ID, "err", err)
	}

	s.writeSession(w, r, user)
}

// validAccountID reports whether s looks like the uuid `users.id` is minted as,
// 8-4-4-4-12 with hyphens. The store does the real validation; this only turns
// an id that was clearly typed in by hand into a 400 the player can read,
// rather than a 404 that reads like the id was lost.
func validAccountID(s string) bool {
	if len(s) != 36 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch i {
		case 8, 13, 18, 23:
			if c != '-' {
				return false
			}
		default:
			hex := (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
			if !hex {
				return false
			}
		}
	}
	return true
}

// handleRestore moves this install's device identity onto an account whose id
// the player saved — the "new phone, bring my history back" path (§1.6).
//
// It is private because it is running from *some* account already (the fresh
// guest this install created on first launch) and has to be sure it is that
// fresh guest, not a hijacker of a signed-in session: the store refuses to run
// out of a non-guest, and refuses to run into a linked account. A linked
// account restores by signing in.
func (s *Server) handleRestore(w http.ResponseWriter, r *http.Request) {
	var req restoreRequest
	if !decodeBody(w, r, maxAuthBody, &req) {
		return
	}
	if !validAccountID(req.AccountID) {
		writeError(w, http.StatusBadRequest, codeBadRequest,
			"That account id does not look right. Copy it from the Account tab on the device that owns the account.")
		return
	}

	ctx := r.Context()
	result, err := s.store.RestoreAccount(ctx, userIDFrom(ctx), req.AccountID)
	if err != nil {
		switch {
		case errors.Is(err, db.ErrNotGuest):
			writeError(w, http.StatusBadRequest, codeBadRequest,
				"Restore is for a fresh install. You are already signed in on this device.")
		case errors.Is(err, db.ErrNotFound):
			writeError(w, http.StatusNotFound, codeNotFound,
				"No guest account has that id. Check the id you saved.")
		default:
			storeError(w, s.log, "RestoreAccount", err)
		}
		return
	}

	// Same body as device/refresh — the token now names the restored account,
	// and the client's next `auth/device` resolves back to it through the
	// moved identity — plus the abandoned install when it still has games.
	token, expires := s.signer.IssueSession(result.User.ID)
	resp := restoreResponse{sessionResponse: sessionResponse{
		Token:     token,
		ExpiresAt: rfc3339(expires),
		User:      newUserJSON(result.User, s.identitiesOf(ctx, result.User.ID)),
	}}
	if result.Abandoned != nil {
		resp.Abandoned = &abandonedJSON{AccountID: result.Abandoned.ID, Games: result.Abandoned.Games}
	}
	writeJSON(w, http.StatusOK, resp)
}

// handleLink is reserved. It answers 501 today so the client can build the
// account tab — the button, the "coming soon" state, and the decoder for the
// success body — against its final shape rather than against a guess.
func (s *Server) handleLink(w http.ResponseWriter, r *http.Request) {
	var req linkRequest
	// The body is read and discarded so the request is fully consumed and the
	// connection stays reusable. A malformed body is not reported: the endpoint
	// does nothing yet, so there is nothing for a validation error to mean, and
	// a client's "coming soon" state should not depend on getting it right.
	_ = decodeIgnoringErrors(r, &req)

	// TODO(link): implement the upgrade path from PERSISTENCE.md §1.4.
	//
	//  1. Verify req.IDToken with the Firebase Admin SDK — signature, audience
	//     (our project id), issuer and expiry. Never trust the uid inside an
	//     unverified token; that is the whole security boundary of this
	//     endpoint.
	//  2. Map the verified provider to a db.Provider (ProviderGoogle,
	//     ProviderFacebook, ProviderApple) and take the Firebase uid as the
	//     subject.
	//  3. Call store.LinkIdentity(ctx, userIDFrom(ctx), provider, uid, email).
	//     It adds a row to user_identities and clears is_guest; no game, seat
	//     or statistic moves, which is what makes the upgrade a one-line insert.
	//  4. On db.ErrConflict the identity already belongs to another account.
	//     Answer 409 with codeConflict and set errorBody.ExistingUserID to that
	//     account, per docs/API.md. Never steal the identity and never silently
	//     discard either side: the client offers a merge (store.MergeUsers)
	//     behind an explicit confirmation.
	//  5. On success reply with exactly the sessionResponse below — a token for
	//     the same users.id, and the new provider present in user.identities.
	//
	// Nothing above needs a schema change; the tables and the Store methods are
	// already in place.
	writeError(w, http.StatusNotImplemented, codeNotImplemented, "Account upgrade is coming soon.")
}

// writeSession mints a token for user and writes the shared auth response body.
func (s *Server) writeSession(w http.ResponseWriter, r *http.Request, user db.User) {
	token, expires := s.signer.IssueSession(user.ID)
	writeJSON(w, http.StatusOK, sessionResponse{
		Token:     token,
		ExpiresAt: rfc3339(expires),
		User:      newUserJSON(user, s.identitiesOf(r.Context(), user.ID)),
	})
}
