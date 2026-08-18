package room

import (
	"time"

	"github.com/nabin31bogati/callbreak/backend/internal/auth"
	"github.com/nabin31bogati/callbreak/backend/internal/engine"
	"github.com/nabin31bogati/callbreak/backend/internal/obs"
	"github.com/nabin31bogati/callbreak/backend/internal/protocol"
)

// message is anything the outside world can ask a table to do. Every one of
// them is applied on the actor goroutine, in arrival order.
type message interface{ isRoomMessage() }

// JoinRequest asks for a seat.
type JoinRequest struct {
	Client     Client
	Player     auth.GuestID
	Name       string
	Difficulty engine.Difficulty
	// UserID is the persistent account behind this player, when the gateway
	// resolved one from a device id. Empty is always valid and always harmless:
	// the seat plays identically and its game is recorded without an account.
	UserID string
	// ResumeSeat, when non-nil, is a verified claim on a specific seat.
	ResumeSeat *int
	// Seat, when non-nil, forces a seat assignment. The matchmaker uses it to
	// seat a whole table at once; ordinary joins leave it nil.
	Seat *int
	// Host marks this joiner as the table's host regardless of seat order.
	Host bool
}

// JoinResult is what the caller learns about its seat.
type JoinResult struct {
	Seat        int
	IsHost      bool
	Reconnected bool
	// Err is a protocol error code when the join was refused.
	Err     string
	ErrText string
}

type joinMsg struct {
	req   JoinRequest
	reply chan JoinResult
}

type actionMsg struct {
	client Client
	seat   int
	frame  protocol.ClientFrame
}

type disconnectMsg struct {
	client Client
	seat   int
}

type leaveMsg struct {
	client Client
	seat   int
}

type startCountdownMsg struct{ after time.Duration }

type resyncMsg struct {
	client Client
	seat   int
}

type attachUserMsg struct {
	client Client
	seat   int
	userID string
}

func (joinMsg) isRoomMessage()           {}
func (actionMsg) isRoomMessage()         {}
func (disconnectMsg) isRoomMessage()     {}
func (leaveMsg) isRoomMessage()          {}
func (startCountdownMsg) isRoomMessage() {}
func (resyncMsg) isRoomMessage()         {}
func (attachUserMsg) isRoomMessage()     {}

// Join asks for a seat and waits for the actor's answer. It returns a refusal
// rather than an error when the table cannot take the player, so the caller can
// forward a precise protocol code.
func (r *Room) Join(req JoinRequest) JoinResult {
	reply := make(chan JoinResult, 1)
	if !r.post(joinMsg{req: req, reply: reply}) {
		return JoinResult{Err: protocol.ErrRoomNotFound, ErrText: "That table is no longer available."}
	}
	select {
	case res := <-reply:
		return res
	case <-r.closed:
		return JoinResult{Err: protocol.ErrRoomNotFound, ErrText: "That table is no longer available."}
	}
}

// Action delivers a gameplay frame from a seated client.
func (r *Room) Action(client Client, seat int, frame protocol.ClientFrame) {
	r.post(actionMsg{client: client, seat: seat, frame: frame})
}

// Disconnected reports that a client's socket closed. The seat is held for the
// reconnect grace window before it is given up.
func (r *Room) Disconnected(client Client, seat int) {
	r.post(disconnectMsg{client: client, seat: seat})
}

// StartCountdown schedules an automatic deal, used by quickplay once a table is
// formed.
func (r *Room) StartCountdown(after time.Duration) {
	r.post(startCountdownMsg{after: after})
}

// Resync pushes the current table state to one client.
//
// The gateway calls this right after it has sent the `joined` frame, so the
// client learns its seat number before it receives a lobby or a view that is
// only meaningful relative to that seat.
func (r *Room) Resync(client Client, seat int) {
	r.post(resyncMsg{client: client, seat: seat})
}

// AttachUser records the account behind an already-seated player.
//
// The gateway resolves a device id to an account without ever making the join
// wait for the database (docs/PERSISTENCE.md §4.1), so the answer can land
// after the player is at the table. This is how it gets there. It is
// best-effort by construction: a table that has closed simply ignores it.
func (r *Room) AttachUser(client Client, seat int, userID string) {
	if userID == "" {
		return
	}
	r.post(attachUserMsg{client: client, seat: seat, userID: userID})
}

// ------------------------------------------------------------------ dispatch

func (r *Room) handle(m message) {
	// A status read is not table activity. Counting it as one would let a
	// dashboard polling every few seconds keep an abandoned table alive past
	// its idle TTL, which is exactly the room the admin surface is meant to
	// show as gone.
	if msg, ok := m.(statusMsg); ok {
		msg.reply <- r.buildStatus()
		return
	}

	r.lastActivity = time.Now()
	r.idleAt = r.lastActivity.Add(r.pacing.IdleTTL)

	switch msg := m.(type) {
	case joinMsg:
		msg.reply <- r.applyJoin(msg.req)
	case actionMsg:
		r.applyAction(msg)
	case disconnectMsg:
		r.applyDisconnect(msg)
	case leaveMsg:
		r.applyLeave(msg)
	case startCountdownMsg:
		r.applyStartCountdown(msg.after)
	case resyncMsg:
		r.applyResync(msg)
	case attachUserMsg:
		r.applyAttachUser(msg)
	}
}

// applyAttachUser binds an account to a seat that is still held by the socket
// that asked for it. The ownership check is the same one every other message
// makes: a late answer must never land on whoever holds the seat now.
func (r *Room) applyAttachUser(msg attachUserMsg) {
	if msg.seat < 0 || msg.seat > 3 || r.seats[msg.seat].client != msg.client {
		return
	}
	if r.seats[msg.seat].kind != engine.KindHuman {
		return
	}
	r.seats[msg.seat].userID = msg.userID
	r.noteSeatUser(msg.seat, msg.userID)
}

// applyResync sends one client everything it needs to render the table right
// now: the lobby, any countdown already running, and a view once play is under
// way.
//
// It has to be complete, not just current, because a client is confirmed
// asynchronously — the matchmaker seats a whole quickplay table in one pass,
// and a table can start its countdown before the last player's `joined` frame
// has even been written. Anything broadcast in that window would otherwise be
// lost to the seats that were not yet listening.
func (r *Room) applyResync(msg resyncMsg) {
	if msg.seat < 0 || msg.seat > 3 || r.seats[msg.seat].client != msg.client {
		return
	}
	r.seats[msg.seat].confirmed = true
	r.sendTo(msg.seat, protocol.Encode(r.lobbyFor(msg.seat)))

	if !r.countdownAt.IsZero() {
		remaining := time.Until(r.countdownAt)
		if remaining < 0 {
			remaining = 0
		}
		r.sendTo(msg.seat, protocol.Countdown(int(remaining.Round(time.Second)/time.Second)))
	}

	if r.started {
		r.fanOutViews()
		if r.game.Phase == engine.PhaseHandOver {
			ready, total, waiting := r.readyTally()
			r.sendTo(msg.seat, protocol.ReadyState(ready, total, waiting))
		}
	}
}

func (r *Room) applyAction(msg actionMsg) {
	// A frame from a socket that no longer owns the seat is stale — it raced a
	// reconnect. Dropping it is the only safe move.
	if msg.seat < 0 || msg.seat > 3 || r.seats[msg.seat].client != msg.client {
		return
	}
	seat := msg.seat

	switch msg.frame.Type {
	case protocol.TypeStart:
		r.applyStart(seat)
	case protocol.TypeHands:
		r.applyHands(seat, msg.frame.Hands)
	case protocol.TypeBid:
		r.applyBid(seat, *msg.frame.Bid)
	case protocol.TypePlay:
		r.applyPlay(seat, msg.frame.Card)
	case protocol.TypeNext:
		r.applyNext(seat)
	case protocol.TypeRestart:
		r.applyRestart(seat)
	case protocol.TypeLeave:
		r.applyLeave(leaveMsg{client: msg.client, seat: seat})
	case protocol.TypeAwake:
		r.applyAwake(seat)
	}
}

func (r *Room) sendTo(seat int, frame []byte) {
	s := &r.seats[seat]
	if s.client != nil && s.confirmed {
		s.client.Send(frame)
	}
}

func (r *Room) sendErr(seat int, code, message string) {
	obs.ProtocolErrors.WithLabelValues(code).Inc()
	r.sendTo(seat, protocol.Encode(protocol.NewError(code, message, false)))
}

func (r *Room) broadcast(frame []byte) {
	for i := range r.seats {
		r.sendTo(i, frame)
	}
}
