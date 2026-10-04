// Package protocol defines the JSON wire format shared by the game server and
// the Godot client.
//
// The normative description lives in PROTOCOL.md; this file is the
// implementation of it. Two rules govern every change here:
//
//  1. Adding a field is safe. the client's decoders read the keys they know
//     and ignore the rest, so new server fields reach old clients harmlessly.
//  2. Renaming or removing a field is a breaking change and needs a version
//     bump, because the client will throw while decoding the frame.
package protocol

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

// Version is the protocol revision this server speaks. Clients send it in the
// join frame; anything older is served the v1 subset (no lobby, no queue).
const Version = 2

// Frame type names, client → server.
const (
	TypeJoin    = "join"
	TypeStart   = "start"
	TypeBid     = "bid"
	TypePlay    = "play"
	TypeNext    = "next"
	TypeRestart = "restart"
	TypeLeave   = "leave"
	TypePing    = "ping"
	// TypeAwake cancels autoplay: the player is back at the controls. Sent on
	// any interaction, not just a move, so tapping anywhere is enough to take
	// the seat back.
	TypeAwake = "awake"
	// TypeHands changes the table's match length from the lobby, before play
	// has begun. Any seated player may send it while the table is still
	// waiting; the last value wins and is picked up when the game deals.
	TypeHands = "hands"
)

// Frame type names, server → client.
const (
	TypeJoined = "joined"
	TypeLobby  = "lobby"
	TypeView   = "view"
	TypeEvent  = "event"
	TypeError  = "error"
	TypePong   = "pong"
)

// Mode is which product surface the connection is playing.
type Mode string

const (
	// ModePrivate is an invite-only table addressed by a short room code.
	ModePrivate Mode = "private"
	// ModeOnline is quickplay: the server picks the table.
	ModeOnline Mode = "online"
)

// QuickplayRoom is the sentinel the client sends as a room code when it wants
// matchmaking. The join sheet uppercases whatever the user typed, so the value
// arrives in this form (see godot/scripts/ui/screens/join_sheet.gd).
const QuickplayRoom = "QUICKPLAY"

// Error codes. Clients switch on these; the message is for humans only.
const (
	ErrBadFrame       = "bad_frame"
	ErrUnsupported    = "unsupported_version"
	ErrRoomFull       = "room_full"
	ErrRoomNotFound   = "room_not_found"
	ErrGameStarted    = "game_started"
	ErrNotYourTurn    = "not_your_turn"
	ErrIllegalMove    = "illegal_move"
	ErrNotHost        = "not_host"
	ErrRoomNotReady   = "room_not_ready"
	ErrRateLimited    = "rate_limited"
	ErrRedirect       = "redirect"
	ErrServerDraining = "server_draining"
	ErrUnauthorized   = "unauthorized"
	ErrCapacity       = "at_capacity"
	ErrInternal       = "internal"
)

// Limits on anything a client controls the size of. Enforced at decode time so
// oversized junk never reaches the game logic.
const (
	MaxFrameBytes = 4096
	MaxNameRunes  = 24
	MaxRoomRunes  = 12
)

// ClientFrame is the decoded union of every client → server message. Optional
// fields are pointers so "absent" and "zero" stay distinguishable — a bid of 0
// is a different thing from no bid at all.
type ClientFrame struct {
	Type string `json:"type"`
	V    int    `json:"v,omitempty"`

	// join
	Room         string `json:"room,omitempty"`
	Mode         Mode   `json:"mode,omitempty"`
	Name         string `json:"name,omitempty"`
	Difficulty   string `json:"difficulty,omitempty"`
	FillWithBots *bool  `json:"fillWithBots,omitempty"`
	// HandsPerGame picks the length of a fresh table: 3 (quickplay) or 5
	// (normal play). It only matters when this join creates a new table — an
	// existing one keeps whatever hand count it was created with. Absent or
	// invalid values resolve to DefaultHandsPerGame; see ResolveHandsPerGame.
	HandsPerGame *int `json:"handsPerGame,omitempty"`
	// Deal picks how a fresh table shuffles and distributes the deck: "fair",
	// "physical" or "balanced". Like HandsPerGame it only matters at table
	// creation; an existing table keeps the deal it was created with. Absent or
	// unrecognized values resolve to "fair" (see ResolveDeal).
	Deal        string `json:"deal,omitempty"`
	ResumeToken string `json:"resumeToken,omitempty"`
	GuestToken  string `json:"guestToken,omitempty"`
	// DeviceID is the id the app generates once on first launch and keeps
	// forever. It is optional. When it is present and persistence is on, the
	// gateway resolves it to an account and this seat's games are attributed to
	// that account. An old client, a malformed value and no database all lead
	// to the same place: an ordinary seat whose games are recorded with no
	// account (docs/PERSISTENCE.md §4.1). Decoding clears anything invalid
	// rather than rejecting the frame — nobody is kept out of a card game over
	// a bad id.
	DeviceID string `json:"deviceId,omitempty"`
	// Create marks this private-join as opening a brand-new table. Absent or
	// false it is join-only: an unknown room is an error (ErrRoomNotFound), not
	// something to mint silently — a mistyped or stale code must never spawn an
	// empty room nobody can find.
	Create bool `json:"create,omitempty"`

	// bid / play
	Bid  *int   `json:"bid,omitempty"`
	Card string `json:"card,omitempty"`

	// hands — the lobby match-length change.
	Hands int `json:"hands,omitempty"`

	// ping
	T int64 `json:"t,omitempty"`
}

// DefaultHandsPerGame is how many hands a table plays when the join frame
// does not specify, or specifies something invalid. It has to independently
// agree with engine.HandsPerGame's value of 5 — protocol has zero internal
// dependencies and stays that way, so this is not derived from that constant.
const DefaultHandsPerGame = 5

// ValidHandsPerGame reports whether v is a hand count a client may request.
func ValidHandsPerGame(v int) bool { return v == 3 || v == 5 }

// ResolveHandsPerGame turns the join frame's optional field into a concrete
// hand count, defaulting anything absent or invalid to DefaultHandsPerGame.
// This never rejects a join: an old client that omits the field, or a
// malformed value, degrades gracefully to the full game rather than erroring
// — a hand count is a preference, not something to gate play on.
func ResolveHandsPerGame(v *int) int {
	if v != nil && ValidHandsPerGame(*v) {
		return *v
	}
	return DefaultHandsPerGame
}

// Deal presets a client may request for a fresh table. Kept as strings here
// because protocol stays independent of the engine; the ws package maps them to
// engine.DealConfig via engine.DealConfigFromPreset.
const (
	DealFair     = "fair"
	DealPhysical = "physical"
	DealBalanced = "balanced"
)

// ResolveDeal turns the join frame's optional deal preset into a concrete one,
// defaulting anything absent or unrecognized to DealFair. A deal choice is a
// preference, never a reason to reject a join — an old client that omits the
// field degrades gracefully to the provably fair shuffle it always had.
func ResolveDeal(v string) string {
	switch v {
	case DealPhysical, DealBalanced:
		return v
	default:
		return DealFair
	}
}

var errUnknownType = errors.New("protocol: unknown frame type")

// DecodeClient parses and validates one client frame. Everything it returns is
// safe to hand to the game logic: the type is known, strings are within their
// limits, and required fields for the type are present.
func DecodeClient(data []byte) (ClientFrame, error) {
	if len(data) > MaxFrameBytes {
		return ClientFrame{}, fmt.Errorf("protocol: frame of %d bytes exceeds the %d byte limit", len(data), MaxFrameBytes)
	}

	var f ClientFrame
	if err := json.Unmarshal(data, &f); err != nil {
		return ClientFrame{}, fmt.Errorf("protocol: malformed frame: %w", err)
	}

	switch f.Type {
	case TypeJoin:
		f.Room = strings.ToUpper(strings.TrimSpace(f.Room))
		if f.Room == "" {
			return f, errors.New("protocol: join needs a room")
		}
		if len([]rune(f.Room)) > MaxRoomRunes {
			return f, errors.New("protocol: room code is too long")
		}
		f.Name = SanitizeName(f.Name)
		if f.Mode == "" {
			// Older clients do not send a mode; infer it from the room code the
			// join sheet produces.
			if f.Room == QuickplayRoom {
				f.Mode = ModeOnline
			} else {
				f.Mode = ModePrivate
			}
		}
		if f.Mode != ModePrivate && f.Mode != ModeOnline {
			return f, fmt.Errorf("protocol: unknown mode %q", f.Mode)
		}
		if !ValidDeviceID(f.DeviceID) {
			f.DeviceID = ""
		}
	case TypeBid:
		if f.Bid == nil {
			return f, errors.New("protocol: bid needs a value")
		}
	case TypeHands:
		if !ValidHandsPerGame(f.Hands) {
			return f, errors.New("protocol: invalid hands value")
		}
	case TypePlay:
		if f.Card == "" {
			return f, errors.New("protocol: play needs a card")
		}
		if len(f.Card) > 4 {
			return f, errors.New("protocol: malformed card id")
		}
	case TypeStart, TypeNext, TypeRestart, TypeLeave, TypePing, TypeAwake:
		// No payload to validate.
	default:
		return f, fmt.Errorf("%w: %q", errUnknownType, f.Type)
	}
	return f, nil
}

// Device id bounds. The same rule the REST surface applies to
// POST /v1/auth/device, so one id is either acceptable to both entry points or
// to neither.
const (
	MinDeviceIDLen = 8
	MaxDeviceIDLen = 128
)

// ValidDeviceID reports whether an id is one the server will look up: 8 to 128
// characters of [A-Za-z0-9_-]. A uuid v4, which is what the client generates,
// passes.
//
// The character set is restrictive on purpose. This value is an opaque key the
// client chose, it reaches a database lookup, and nothing downstream ever needs
// to display it — so there is no reason to accept anything but the alphabet a
// uuid or a base64url token is made of. An empty id is not "invalid", it is
// absent; callers test for empty separately.
func ValidDeviceID(id string) bool {
	if len(id) < MinDeviceIDLen || len(id) > MaxDeviceIDLen {
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

// SanitizeName trims a display name to something safe to show other players:
// no control characters, no runaway length, never empty.
func SanitizeName(name string) string {
	cleaned := strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, name)
	cleaned = strings.TrimSpace(cleaned)

	runes := []rune(cleaned)
	if len(runes) > MaxNameRunes {
		cleaned = string(runes[:MaxNameRunes])
	}
	if cleaned == "" {
		return "Guest"
	}
	return cleaned
}
