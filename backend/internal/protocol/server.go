package protocol

import (
	"encoding/json"

	"github.com/nabin31bogati/callbreak/backend/internal/engine"
)

// Server frames are built here rather than in the game packages so every
// outbound shape is defined in one file next to the client's expectations.

// Joined confirms a seat. The two tokens are the client's credentials: the
// guest token identifies the player across tables, the resume token identifies
// this specific seat and is what makes reconnecting possible.
type Joined struct {
	Type        string `json:"type"`
	Seat        int    `json:"seat"`
	Room        string `json:"room"`
	IsHost      bool   `json:"isHost"`
	PlayerID    string `json:"playerId"`
	GuestToken  string `json:"guestToken"`
	ResumeToken string `json:"resumeToken"`
	Reconnected bool   `json:"reconnected"`

	// ReconnectGraceMs is how long this seat is held after a drop before it is
	// given to a bot for good. The client needs it to know how long to keep
	// retrying, and to tell the player how long they have.
	ReconnectGraceMs int64 `json:"reconnectGraceMs"`
}

// LobbySeat is one row of the pre-game lobby.
type LobbySeat struct {
	Seat      int               `json:"seat"`
	Name      string            `json:"name"`
	Kind      engine.PlayerKind `json:"kind"`
	Connected bool              `json:"connected"`
	IsYou     bool              `json:"isYou"`
	IsHost    bool              `json:"isHost"`
}

// Lobby is the pre-game state of a table, private or quickplay.
//
// Quickplay players are seated in a real table from the moment they arrive
// rather than held in an anonymous queue, so they see each other's names while
// the table fills — which is the whole point of waiting with other people.
type Lobby struct {
	Type     string      `json:"type"`
	Room     string      `json:"room"`
	Mode     Mode        `json:"mode"`
	HostSeat int         `json:"hostSeat"`
	IsHost   bool        `json:"isHost"`
	CanStart bool        `json:"canStart"`
	Started  bool        `json:"started"`
	Seats    []LobbySeat `json:"seats"`

	// HumansSeated counts the people currently present, and MinPlayers is how
	// many the table needs before it can deal at all. Quickplay will not start a
	// game one human plays against three bots — that is what the offline mode is
	// for — so the client uses these to say what is still being waited on.
	HumansSeated int `json:"humansSeated"`
	MinPlayers   int `json:"minPlayers"`

	// HandsPerGame is the table's current match length, changeable from the
	// lobby before play begins. It is what the game deals when the table
	// starts, so the lobby picker shows it.
	HandsPerGame int `json:"handsPerGame"`
}

// Error is a rejection. Fatal means the connection is about to close; the
// client should surface the message rather than silently retry. Endpoint is
// only set for ErrRedirect, and tells the client where to reconnect.
type Error struct {
	Type     string `json:"type"`
	Code     string `json:"code"`
	Message  string `json:"message"`
	Fatal    bool   `json:"fatal"`
	Endpoint string `json:"endpoint,omitempty"`
}

// Pong echoes a client ping so the app can measure round-trip time.
type Pong struct {
	Type         string `json:"type"`
	T            int64  `json:"t"`
	ServerTimeMs int64  `json:"serverTimeMs"`
}

func NewJoined(seat int, room string, isHost bool, playerID, guest, resume string, reconnected bool) Joined {
	return Joined{
		Type: TypeJoined, Seat: seat, Room: room, IsHost: isHost,
		PlayerID: playerID, GuestToken: guest, ResumeToken: resume,
		Reconnected: reconnected,
	}
}

func NewError(code, message string, fatal bool) Error {
	return Error{Type: TypeError, Code: code, Message: message, Fatal: fatal}
}

func NewRedirect(endpoint string) Error {
	return Error{
		Type:     TypeError,
		Code:     ErrRedirect,
		Message:  "This table is hosted on another server node.",
		Fatal:    true,
		Endpoint: endpoint,
	}
}

// EncodeView wraps a redacted view in a `view` frame. The view's own keys are
// hoisted to the top level, which is the shape RemoteSession._onMessage reads:
// it passes the whole message straight to GameView.from_dict.
func EncodeView(v *engine.View) ([]byte, error) {
	body, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	// body is a JSON object; splice in the type key without a second full
	// marshal of the (comparatively large) view.
	out := make([]byte, 0, len(body)+16)
	out = append(out, `{"type":"view",`...)
	out = append(out, body[1:]...)
	return out, nil
}

// EncodeEvent wraps an engine event in an `event` frame.
func EncodeEvent(e engine.Event) ([]byte, error) {
	body := e.Wire()
	body["type"] = TypeEvent
	return json.Marshal(body)
}

// Custom server-side events that have no engine counterpart. They ride the same
// `event` frame so the client's existing decoder path handles them, and unknown
// event names are ignored there rather than throwing.
const (
	EventCountdown  = "countdown"
	EventReadyState = "readyState"
	EventSeatChange = "seatChanged"
	EventAutoplay   = "autoplay"
)

// Countdown announces the seconds remaining before a quickplay table deals.
func Countdown(seconds int) []byte {
	return mustEncode(map[string]any{
		"type": TypeEvent, "event": EventCountdown, "seconds": seconds,
	})
}

// CountdownCancelled retracts a countdown, which happens when a player leaves
// and takes the table back below its minimum. Without it a client would sit
// showing "starting in 3…" for a game that is no longer coming.
func CountdownCancelled() []byte {
	return mustEncode(map[string]any{
		"type": TypeEvent, "event": EventCountdown, "seconds": 0, "cancelled": true,
	})
}

// AutoplayChanged announces that the server has taken over a seat, or given it
// back. Every client gets it: the player themselves needs to know they are no
// longer playing, and the others deserve to know why that seat is suddenly
// instant.
func AutoplayChanged(seat int, name string, on bool) []byte {
	return mustEncode(map[string]any{
		"type": TypeEvent, "event": EventAutoplay,
		"seat": seat, "name": name, "autoplay": on,
	})
}

// ReadyState reports how many seats have consented to move on, so the client
// can render "2 of 3 ready" between hands.
func ReadyState(ready, total int, waitingFor []int) []byte {
	return mustEncode(map[string]any{
		"type": TypeEvent, "event": EventReadyState,
		"ready": ready, "total": total, "waitingFor": waitingFor,
	})
}

// SeatChange announces that a seat changed hands — a player dropped and a bot
// took over, or a player reconnected and took it back.
func SeatChange(seat int, kind engine.PlayerKind, name string, connected bool) []byte {
	return mustEncode(map[string]any{
		"type": TypeEvent, "event": EventSeatChange,
		"seat": seat, "kind": kind, "name": name, "connected": connected,
	})
}

// mustEncode is safe for these literal maps: every value is a plain JSON type,
// so encoding cannot fail.
func mustEncode(v map[string]any) []byte {
	data, err := json.Marshal(v)
	if err != nil {
		panic("protocol: static frame failed to encode: " + err.Error())
	}
	return data
}

// Encode marshals any server frame, panicking only on programmer error (a frame
// containing something unencodable), which no runtime input can cause.
func Encode(frame any) []byte {
	data, err := json.Marshal(frame)
	if err != nil {
		panic("protocol: server frame failed to encode: " + err.Error())
	}
	return data
}
