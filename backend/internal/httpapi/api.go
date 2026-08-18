// Package httpapi is the REST surface that sits beside the websocket.
//
// The socket carries play; everything that is request/response — signing in,
// reading a profile, listing history, uploading a game that was played offline
// — lives here, mounted on the same mux as /ws and /healthz. docs/API.md is the
// normative description of every byte this package emits, and docs/PERSISTENCE.md
// explains why the shapes are what they are.
//
// Two properties are worth calling out because they shape the whole package:
//
//   - It never depends on a database being there. With no DATABASE_URL the
//     server still starts, still deals cards, and every /v1 route answers 503
//     persistence_disabled. A database problem must never stop a game.
//   - It never trusts a client with somebody else's identity. The account comes
//     from a signed session token and nothing else; POST /v1/games in
//     particular rewrites the payload's seat ownership from that token rather
//     than believing what was uploaded.
package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/nabin31bogati/callbreak/backend/internal/auth"
	"github.com/nabin31bogati/callbreak/backend/internal/config"
	"github.com/nabin31bogati/callbreak/backend/internal/db"
	"github.com/nabin31bogati/callbreak/backend/internal/room"
	"github.com/nabin31bogati/callbreak/backend/internal/settings"
)

// Body caps. A request larger than this is not a request, it is an attack or a
// bug; either way it should not become memory. The upload limit is generous —
// a five-hand game with four seats is a couple of kilobytes.
const (
	maxAuthBody   = 8 << 10
	maxUploadBody = 64 << 10
)

// Server holds everything the routes need.
type Server struct {
	cfg    config.Config
	store  db.Store
	signer *auth.Signer
	log    *slog.Logger
	limit  *keyLimiter

	// The admin surface. Nil until Admin is called, which is what opts a
	// server in — see admin.go.
	adminHub      *room.Hub
	adminSettings *settings.Store
	adminToken    string
}

func NewServer(cfg config.Config, store db.Store, signer *auth.Signer, log *slog.Logger) *Server {
	return &Server{
		cfg:    cfg,
		store:  store,
		signer: signer,
		log:    log.With("component", "httpapi"),
		limit:  newKeyLimiter(cfg.APIRatePerMinute),
	}
}

// Admin enables the admin dashboard and its API, gated behind token. It is a
// deliberate opt-in: a server that never calls it mounts none of the /admin
// routes, so an unconfigured deployment is not silently exposed.
func (s *Server) Admin(hub *room.Hub, st *settings.Store, token string) {
	s.adminHub = hub
	s.adminSettings = st
	s.adminToken = token
}

// Handler mounts the v1 API. Method-qualified patterns mean a GET to a POST-only
// route is a 405 from the mux rather than something a handler has to check.
func (s *Server) Handler(mux *http.ServeMux) {
	// The only unauthenticated route: it is how a client gets a token in the
	// first place, so it is limited by address instead of by account.
	mux.Handle("POST /v1/auth/device", s.public(s.handleDeviceAuth))

	mux.Handle("POST /v1/auth/refresh", s.private(s.handleRefresh))
	mux.Handle("POST /v1/auth/link", s.private(s.handleLink))
	mux.Handle("POST /v1/auth/restore", s.private(s.handleRestore))

	mux.Handle("GET /v1/me", s.private(s.handleGetMe))
	mux.Handle("PATCH /v1/me", s.private(s.handlePatchMe))
	mux.Handle("GET /v1/me/stats", s.private(s.handleStats))
	mux.Handle("GET /v1/me/games", s.private(s.handleHistory))
	mux.Handle("POST /v1/me/merge/{id}", s.private(s.handleMergeAbandoned))
	mux.Handle("DELETE /v1/me/abandoned/{id}", s.private(s.handleDeleteAbandoned))

	mux.Handle("GET /v1/games/{id}", s.private(s.handleGame))
	mux.Handle("POST /v1/games", s.private(s.handleUpload))

	if s.adminToken != "" {
		mux.Handle("GET /admin", s.adminPage())
		mux.Handle("GET /v1/admin/rooms", s.admin(s.handleAdminRooms))
		mux.Handle("GET /v1/admin/rooms/{id}", s.admin(s.handleAdminRoom))
		mux.Handle("GET /v1/admin/games", s.admin(s.handleAdminGames))
		mux.Handle("GET /v1/admin/games/{id}", s.admin(s.handleAdminGame))
		mux.Handle("GET /v1/admin/settings", s.admin(s.handleAdminSettings))
		mux.Handle("PUT /v1/admin/settings", s.admin(s.handleAdminSettingsPut))
	}
}

// ------------------------------------------------------------------- chains

// public wraps a route that runs before there is an account.
func (s *Server) public(h http.HandlerFunc) http.Handler {
	return s.recoverPanics(s.logRequest(s.requireStore(s.limitByIP(h))))
}

// private wraps a route that requires a session token. Authentication runs
// before rate limiting so the bucket is per account rather than per address:
// four players behind one café router must not share an allowance.
func (s *Server) private(h http.HandlerFunc) http.Handler {
	return s.recoverPanics(s.logRequest(s.requireStore(s.authenticate(s.limitByUser(h)))))
}

// --------------------------------------------------------------- middleware

// recoverPanics keeps one broken request from taking the process down. This
// binary is also holding every live table in memory, so a nil dereference in a
// history handler must cost one response, not everybody's game.
func (s *Server) recoverPanics(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			rec := recover()
			if rec == nil {
				return
			}
			// http.ErrAbortHandler is the documented way to abandon a response;
			// it is not a bug and must be re-panicked for the server to see it.
			if err, ok := rec.(error); ok && errors.Is(err, http.ErrAbortHandler) {
				panic(rec)
			}
			s.log.Error("panic in api handler",
				"method", r.Method, "path", r.URL.Path, "panic", rec)
			writeError(w, http.StatusInternalServerError, codeInternal, msgInternal)
		}()
		next.ServeHTTP(w, r)
	})
}

// logRequest records one line per request at debug level. Tokens never appear:
// the Authorization header is not read here, and the query string is logged by
// its keys rather than wholesale.
func (s *Server) logRequest(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		s.log.Debug("api request",
			"method", r.Method,
			"path", r.URL.Path,
			"status", rec.status,
			"user", userIDFrom(r.Context()),
			"ms", time.Since(started).Milliseconds(),
		)
	})
}

// requireStore answers every /v1 route with 503 when there is no database,
// before any handler can touch one. PERSISTENCE.md §5: no DATABASE_URL means
// the server runs and REST says persistence_disabled — it is a supported
// deployment, not a failure, and the socket is unaffected.
func (s *Server) requireStore(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !s.store.Enabled() {
			writeError(w, http.StatusServiceUnavailable, codePersistenceDisabled, msgDisabled)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// authenticate resolves the bearer token to a users.id and puts it in the
// request context. Every failure looks the same from outside — a client cannot
// learn whether a token was forged, expired or simply of the wrong kind.
func (s *Server) authenticate(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token, ok := bearerToken(r)
		if !ok {
			writeError(w, http.StatusUnauthorized, codeUnauthorized, msgUnauthorized)
			return
		}
		userID, err := s.signer.VerifySession(token)
		if err != nil || userID == "" {
			// Deliberately not logging the token, nor which of the three ways it
			// failed, at anything above debug.
			s.log.Debug("rejected session token", "path", r.URL.Path, "err", err)
			writeError(w, http.StatusUnauthorized, codeUnauthorized, msgUnauthorized)
			return
		}
		next.ServeHTTP(w, r.WithContext(withUserID(r.Context(), userID)))
	})
}

func (s *Server) limitByUser(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !s.limit.allow("u:" + userIDFrom(r.Context())) {
			writeError(w, http.StatusTooManyRequests, codeRateLimited, msgRateLimited)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) limitByIP(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !s.limit.allow("ip:" + clientIP(r)) {
			writeError(w, http.StatusTooManyRequests, codeRateLimited, msgRateLimited)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// statusRecorder remembers the status code for the log line.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (w *statusRecorder) WriteHeader(status int) {
	w.status = status
	w.ResponseWriter.WriteHeader(status)
}

// ------------------------------------------------------------------ context

type contextKey struct{}

var userIDKey contextKey

func withUserID(ctx context.Context, id string) context.Context {
	return context.WithValue(ctx, userIDKey, id)
}

// userIDFrom returns the authenticated account, or "" on an unauthenticated
// route. Handlers behind private() can rely on it being set.
func userIDFrom(ctx context.Context) string {
	id, _ := ctx.Value(userIDKey).(string)
	return id
}

// ------------------------------------------------------------------ helpers

// bearerToken pulls the credential out of an Authorization header. The scheme
// is compared case-insensitively because RFC 7235 says it is case-insensitive,
// and clients do vary.
func bearerToken(r *http.Request) (string, bool) {
	header := r.Header.Get("Authorization")
	scheme, rest, ok := strings.Cut(header, " ")
	if !ok || !strings.EqualFold(scheme, "Bearer") {
		return "", false
	}
	token := strings.TrimSpace(rest)
	return token, token != ""
}

// clientIP mirrors the socket's version: proxy headers first, socket address
// last. Only the first hop of X-Forwarded-For is meaningful.
func clientIP(r *http.Request) string {
	if v := r.Header.Get("X-Real-IP"); v != "" {
		return v
	}
	if v := r.Header.Get("X-Forwarded-For"); v != "" {
		if first, _, ok := strings.Cut(v, ","); ok {
			return strings.TrimSpace(first)
		}
		return strings.TrimSpace(v)
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// decodeBody reads a JSON request body under a size cap, answering the client
// itself on failure. Unknown fields are accepted on purpose: docs/API.md
// promises that adding a field is safe, and that promise has to hold in both
// directions or a newer client cannot talk to an older server.
func decodeBody(w http.ResponseWriter, r *http.Request, limit int64, dst any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, limit)
	err := json.NewDecoder(r.Body).Decode(dst)
	switch {
	case err == nil:
		return true
	case errors.Is(err, io.EOF):
		writeError(w, http.StatusBadRequest, codeBadRequest, "That request needs a JSON body.")
	default:
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			// 400 rather than 413: docs/API.md gives bad_request exactly one
			// status, and a client switching on the code should not have to
			// learn a second one for the same class of mistake.
			writeError(w, http.StatusBadRequest, codeBadRequest, msgTooLarge)
			return false
		}
		writeError(w, http.StatusBadRequest, codeBadRequest, msgBadJSON)
	}
	return false
}

// decodeIgnoringErrors reads a body for a route whose answer does not depend on
// it — today, only the reserved link endpoint. The body is drained under the
// same cap either way so the connection stays reusable.
func decodeIgnoringErrors(r *http.Request, dst any) error {
	body := io.LimitReader(r.Body, maxAuthBody)
	err := json.NewDecoder(body).Decode(dst)
	_, _ = io.Copy(io.Discard, body)
	return err
}

// identitiesOf reads a user's sign-in methods for the response body. A failure
// here is not worth failing the whole request over — the profile still renders
// without the account tab's list, and every caller has already done the work
// that mattered.
func (s *Server) identitiesOf(ctx context.Context, userID string) []db.Identity {
	ids, err := s.store.IdentitiesOf(ctx, userID)
	if err != nil {
		s.log.Warn("could not read identities", "user", userID, "err", err)
		return nil
	}
	return ids
}
