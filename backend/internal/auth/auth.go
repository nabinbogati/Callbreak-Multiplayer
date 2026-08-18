// Package auth issues and verifies the credentials a player carries.
//
// Three kinds, all minted the same way. A guest identity is minted on first
// connect and remembered by the client; a per-seat resume token lets a player
// reclaim a specific seat after a drop; and a session token names a persisted
// account (users.id) for the REST API in docs/API.md. All are HMAC-signed with
// the server secret and carry an expiry, which is all the state we need —
// nothing here touches a database.
//
// Format: base64url(payload) "." base64url(hmac-sha256(payload)). The payload is
// compact JSON. This is a JWT in spirit without the algorithm-negotiation
// footguns: there is exactly one algorithm and it is not client-selectable.
//
// The kind field is what keeps the three apart. Every Verify* rejects a token
// of another kind with ErrWrongKind, so a guest token can never be presented as
// a session and read someone's history, and a session can never claim a seat.
package auth

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

var (
	ErrMalformed = errors.New("auth: malformed token")
	ErrSignature = errors.New("auth: bad signature")
	ErrExpired   = errors.New("auth: token expired")
	ErrWrongKind = errors.New("auth: token is for a different purpose")
)

const (
	kindGuest   = "g"
	kindResume  = "r"
	kindSession = "u"

	// A guest identity outlives a long session but not a lost device.
	GuestTTL = 30 * 24 * time.Hour
	// A resume token only has to survive a reconnect, and a shorter life limits
	// how long a leaked one is worth anything.
	ResumeTTL = 6 * time.Hour
	// A session names a real account, so it lasts as long as a guest identity
	// did: the app should not log a player out for coming back after a holiday.
	// The client refreshes it on launch via POST /v1/auth/refresh, so an active
	// player never sees it expire at all.
	SessionTTL = 30 * 24 * time.Hour
)

type claims struct {
	Kind    string `json:"k"`
	Subject string `json:"s"`
	Room    string `json:"r,omitempty"`
	Seat    int    `json:"t,omitempty"`
	Expires int64  `json:"e"`
	Nonce   string `json:"n,omitempty"`
}

// Signer mints and validates tokens. Safe for concurrent use.
type Signer struct {
	secret []byte
	now    func() time.Time
}

func NewSigner(secret []byte) *Signer {
	return &Signer{secret: secret, now: time.Now}
}

// GuestID is a stable pseudonymous player identity.
type GuestID string

// NewGuestID mints a fresh random player id.
func NewGuestID() GuestID {
	buf := make([]byte, 12)
	if _, err := rand.Read(buf); err != nil {
		panic("auth: no entropy available: " + err.Error())
	}
	return GuestID("p_" + hex.EncodeToString(buf))
}

// IssueGuest returns a token asserting the bearer is this player.
func (s *Signer) IssueGuest(id GuestID) string {
	return s.sign(claims{
		Kind:    kindGuest,
		Subject: string(id),
		Expires: s.now().Add(GuestTTL).Unix(),
	})
}

// VerifyGuest returns the player id carried by a guest token.
func (s *Signer) VerifyGuest(token string) (GuestID, error) {
	c, err := s.verify(token)
	if err != nil {
		return "", err
	}
	if c.Kind != kindGuest {
		return "", ErrWrongKind
	}
	return GuestID(c.Subject), nil
}

// ResolveGuest accepts whatever the client sent and always yields a usable
// identity: the one in a valid token, or a brand new one. An expired or forged
// token is not an error the player should see — they simply become someone new,
// which is the correct behaviour for an anonymous guest system.
func (s *Signer) ResolveGuest(token string) (id GuestID, minted string) {
	if token != "" {
		if existing, err := s.VerifyGuest(token); err == nil {
			return existing, s.IssueGuest(existing)
		}
	}
	fresh := NewGuestID()
	return fresh, s.IssueGuest(fresh)
}

// Seat is the claim carried by a resume token.
type Seat struct {
	Player GuestID
	Room   string
	Seat   int
}

// IssueResume returns a token that reclaims one seat at one table. The nonce
// keeps two tokens for the same seat from being byte-identical, so a token
// re-issued after a reconnect does not collide in logs or caches.
func (s *Signer) IssueResume(player GuestID, room string, seat int) string {
	nonce := make([]byte, 6)
	if _, err := rand.Read(nonce); err != nil {
		panic("auth: no entropy available: " + err.Error())
	}
	return s.sign(claims{
		Kind:    kindResume,
		Subject: string(player),
		Room:    room,
		Seat:    seat,
		Expires: s.now().Add(ResumeTTL).Unix(),
		Nonce:   base64.RawURLEncoding.EncodeToString(nonce),
	})
}

// VerifyResume checks a resume token and returns the seat it claims. The caller
// still has to confirm that seat is actually held by that player — a valid
// token for a game that has since ended must not seat anybody.
func (s *Signer) VerifyResume(token string) (Seat, error) {
	c, err := s.verify(token)
	if err != nil {
		return Seat{}, err
	}
	if c.Kind != kindResume {
		return Seat{}, ErrWrongKind
	}
	if c.Seat < 0 || c.Seat > 3 {
		return Seat{}, ErrMalformed
	}
	return Seat{Player: GuestID(c.Subject), Room: c.Room, Seat: c.Seat}, nil
}

// ---------------------------------------------------------------- sessions

// IssueSession returns a token asserting the bearer is the account with this
// users.id, plus the moment it stops being valid. The expiry is returned rather
// than left for the client to parse out of the payload: the token body is ours
// to change, and docs/API.md promises an expiresAt field beside it.
//
// userID is a surrogate key (PERSISTENCE.md §1.2). Nothing about the device or
// the login provider is carried here, which is what lets a guest link Google
// later without any token in flight becoming wrong.
func (s *Signer) IssueSession(userID string) (token string, expires time.Time) {
	// Truncated to the second so the expiry we report is exactly the expiry we
	// signed; the claim carries a Unix timestamp and nothing finer.
	expires = s.now().Add(SessionTTL).Truncate(time.Second)
	return s.sign(claims{
		Kind:    kindSession,
		Subject: userID,
		Expires: expires.Unix(),
	}), expires
}

// VerifySession returns the users.id carried by a session token. A guest or
// resume token is rejected with ErrWrongKind — those name a pseudonymous player
// or a seat, never an account, and treating one as the other would hand the
// bearer someone else's history.
func (s *Signer) VerifySession(token string) (userID string, err error) {
	c, err := s.verify(token)
	if err != nil {
		return "", err
	}
	if c.Kind != kindSession {
		return "", ErrWrongKind
	}
	return c.Subject, nil
}

// ------------------------------------------------------------------ internals

func (s *Signer) sign(c claims) string {
	payload, err := json.Marshal(c)
	if err != nil {
		panic("auth: claims failed to encode: " + err.Error())
	}
	body := base64.RawURLEncoding.EncodeToString(payload)
	return body + "." + base64.RawURLEncoding.EncodeToString(s.mac([]byte(body)))
}

func (s *Signer) verify(token string) (claims, error) {
	body, sig, ok := strings.Cut(token, ".")
	if !ok || body == "" || sig == "" {
		return claims{}, ErrMalformed
	}
	want, err := base64.RawURLEncoding.DecodeString(sig)
	if err != nil {
		return claims{}, ErrMalformed
	}
	// Constant-time compare: a timing oracle here would let an attacker forge a
	// token byte by byte.
	if subtle.ConstantTimeCompare(want, s.mac([]byte(body))) != 1 {
		return claims{}, ErrSignature
	}

	payload, err := base64.RawURLEncoding.DecodeString(body)
	if err != nil {
		return claims{}, ErrMalformed
	}
	var c claims
	if err := json.Unmarshal(payload, &c); err != nil {
		return claims{}, ErrMalformed
	}
	if c.Subject == "" {
		return claims{}, ErrMalformed
	}
	if s.now().Unix() >= c.Expires {
		return claims{}, fmt.Errorf("%w at %d", ErrExpired, c.Expires)
	}
	return c, nil
}

func (s *Signer) mac(body []byte) []byte {
	h := hmac.New(sha256.New, s.secret)
	h.Write(body)
	return h.Sum(nil)
}
