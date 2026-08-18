package httpapi

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"

	"github.com/nabin31bogati/callbreak/backend/internal/db"
)

// The error vocabulary from docs/API.md. Clients switch on the code, so these
// strings are part of the wire contract; the message beside them is for a human
// and may be reworded freely.
const (
	codeBadRequest          = "bad_request"
	codeUnauthorized        = "unauthorized"
	codeNotFound            = "not_found"
	codeConflict            = "conflict"
	codeRateLimited         = "rate_limited"
	codeNotImplemented      = "not_implemented"
	codePersistenceDisabled = "persistence_disabled"
	codeInternal            = "internal"
)

// errorEnvelope is the body of every non-2xx response:
//
//	{"error": {"code": "...", "message": "..."}}
//
// It is an object rather than a bare string so it can grow — the reserved
// conflict response for POST /v1/auth/link adds existingUserId beside the code,
// and a client that ignores unknown keys keeps working either way.
type errorEnvelope struct {
	Error errorBody `json:"error"`
}

type errorBody struct {
	Code    string `json:"code"`
	Message string `json:"message"`
	// ExistingUserID accompanies a conflict: the account that already owns the
	// identity the caller tried to link. Omitted everywhere else.
	ExistingUserID string `json:"existingUserId,omitempty"`
}

// writeError sends one error envelope. Every non-2xx answer in this package
// goes through here so no handler can invent a different shape.
func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, errorEnvelope{Error: errorBody{Code: code, Message: message}})
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	// A write failure here means the client hung up mid-response; there is
	// nothing useful left to say to them.
	_ = json.NewEncoder(w).Encode(body)
}

// Stock messages. Human sentences, in the same register as the socket's
// rejections ("That room code is not valid.").
const (
	msgUnauthorized = "Sign in again to continue."
	msgDisabled     = "This server has no database configured, so profiles and history are unavailable."
	msgRateLimited  = "You are sending requests too quickly. Try again in a moment."
	msgInternal     = "Something went wrong on our side. Please try again."
	msgNotFound     = "That game is not in your history."
	msgBadJSON      = "That request body is not valid JSON."
	msgTooLarge     = "That request body is too large."
)

// storeError translates a db error into the documented response.
//
// ErrDisabled is deliberately a 503 rather than a 500: persistence being off is
// a supported deployment (PERSISTENCE.md §5), not a fault. The route guard
// already answers 503 when the store reports itself disabled, and this catches
// the same condition arriving from a store that only discovers it per call.
func storeError(w http.ResponseWriter, log *slog.Logger, op string, err error) {
	switch {
	case errors.Is(err, db.ErrDisabled):
		writeError(w, http.StatusServiceUnavailable, codePersistenceDisabled, msgDisabled)
	case errors.Is(err, db.ErrNotFound):
		writeError(w, http.StatusNotFound, codeNotFound, msgNotFound)
	case errors.Is(err, db.ErrConflict):
		writeError(w, http.StatusConflict, codeConflict,
			"That account is already linked to someone else.")
	default:
		// Only unexpected failures are worth a log line at error level; the
		// three above are ordinary outcomes.
		log.Error("store call failed", "op", op, "err", err)
		writeError(w, http.StatusInternalServerError, codeInternal, msgInternal)
	}
}
