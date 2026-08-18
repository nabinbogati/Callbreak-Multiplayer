package ws

import (
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"

	"github.com/nabin31bogati/callbreak/backend/internal/auth"
	"github.com/nabin31bogati/callbreak/backend/internal/obs"
	"github.com/nabin31bogati/callbreak/backend/internal/protocol"
	"github.com/nabin31bogati/callbreak/backend/internal/room"
)

// Connection tuning. These are the numbers that decide how the server behaves
// under a bad network, which is the normal case for a phone game.
const (
	// writeWait bounds a single write. A socket that cannot absorb a ~2 KB view
	// in this long is not going to recover.
	writeWait = 10 * time.Second
	// pongWait is how long we tolerate silence before assuming the peer is gone.
	pongWait = 60 * time.Second
	// pingPeriod must be comfortably under pongWait so a healthy peer always
	// answers in time.
	pingPeriod = 25 * time.Second
	// sendQueue is how many frames may be in flight to one client. A full queue
	// means the client is not reading, and the connection is closed rather than
	// allowed to hold up a table.
	sendQueue = 64
)

// Conn is one player's websocket. It implements room.Client.
//
// Two goroutines own it: a read pump that turns frames into room messages, and
// a write pump that is the only writer to the socket. Everything shared between
// them sits behind mu.
type Conn struct {
	srv  *Server
	ws   *websocket.Conn
	log  *slog.Logger
	send chan []byte

	player auth.GuestID
	// guestToken is reissued on join and handed back to the client.
	guestToken string
	// ip is the address this socket was accepted from, held so the per-address
	// slot can be released on teardown.
	ip string

	closeOnce sync.Once
	closed    chan struct{}
	// fatal marks the connection as being torn down: further client frames are
	// ignored rather than acted on while the close is in flight.
	fatal atomic.Bool

	mu     sync.Mutex
	room   *room.Room
	seat   int
	joined bool
}

func newConn(srv *Server, socket *websocket.Conn, log *slog.Logger) *Conn {
	return &Conn{
		srv:    srv,
		ws:     socket,
		log:    log,
		send:   make(chan []byte, sendQueue),
		closed: make(chan struct{}),
		seat:   -1,
	}
}

// PlayerID implements room.Client.
func (c *Conn) PlayerID() auth.GuestID {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.player
}

// Send implements room.Client. It never blocks: a client that has fallen a full
// queue behind is dropped, because the alternative is stalling the table for
// everyone else. The client reconnects and gets a fresh authoritative view, so
// nothing is lost but the connection.
func (c *Conn) Send(frame []byte) {
	select {
	case <-c.closed:
		return
	default:
	}
	select {
	case c.send <- frame:
	default:
		obs.SendDrops.Inc()
		c.log.Warn("client fell behind its send queue; closing")
		c.Close("policy", "send queue overflow")
	}
}

// Close implements room.Client. Safe to call repeatedly and from any goroutine.
func (c *Conn) Close(code, reason string) {
	c.closeOnce.Do(func() {
		close(c.closed)
		c.log.Debug("closing connection", "code", code, "reason", reason)
		deadline := time.Now().Add(time.Second)
		msg := websocket.FormatCloseMessage(closeCode(code), reason)
		_ = c.ws.WriteControl(websocket.CloseMessage, msg, deadline)
		_ = c.ws.Close()
	})
}

func closeCode(code string) int {
	switch code {
	case "going_away":
		return websocket.CloseGoingAway
	case "policy":
		return websocket.ClosePolicyViolation
	case "internal":
		return websocket.CloseInternalServerErr
	default:
		return websocket.CloseNormalClosure
	}
}

// seatBinding is the conn's current table, read atomically with its seat.
func (c *Conn) seatBinding() (*room.Room, int, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.room, c.seat, c.joined
}

func (c *Conn) bind(r *room.Room, seat int) {
	c.mu.Lock()
	c.room = r
	c.seat = seat
	c.joined = true
	c.mu.Unlock()
}

// ------------------------------------------------------------------- pumps

func (c *Conn) writePump() {
	ticker := time.NewTicker(pingPeriod)
	defer ticker.Stop()

	for {
		select {
		case <-c.closed:
			return
		case frame := <-c.send:
			if frame == nil {
				// Close sentinel: everything queued ahead of it has been
				// written, so the peer has the explanation.
				c.Close("normal", "closing after final frame")
				return
			}
			_ = c.ws.SetWriteDeadline(time.Now().Add(writeWait))
			if err := c.ws.WriteMessage(websocket.TextMessage, frame); err != nil {
				c.Close("normal", "write failed")
				return
			}
		case <-ticker.C:
			_ = c.ws.SetWriteDeadline(time.Now().Add(writeWait))
			if err := c.ws.WriteMessage(websocket.PingMessage, nil); err != nil {
				c.Close("normal", "ping failed")
				return
			}
		}
	}
}

func (c *Conn) readPump() {
	defer c.teardown()

	c.ws.SetReadLimit(protocol.MaxFrameBytes)
	_ = c.ws.SetReadDeadline(time.Now().Add(pongWait))
	c.ws.SetPongHandler(func(string) error {
		return c.ws.SetReadDeadline(time.Now().Add(pongWait))
	})

	limiter := newBucket(c.srv.cfg.MsgRatePerSecond, c.srv.cfg.MsgBurst)

	for {
		_, data, err := c.ws.ReadMessage()
		if err != nil {
			return
		}
		// Any traffic proves the peer is alive, not just pongs — a client that
		// is playing should never be timed out.
		_ = c.ws.SetReadDeadline(time.Now().Add(pongWait))

		// Once a fatal error is on its way out, nothing else this client says
		// should reach a table.
		if c.fatal.Load() {
			continue
		}

		if !limiter.allow() {
			c.Fail(protocol.ErrRateLimited, "You are sending messages too quickly.")
			continue
		}

		frame, err := protocol.DecodeClient(data)
		if err != nil {
			obs.ProtocolErrors.WithLabelValues(protocol.ErrBadFrame).Inc()
			c.reject(protocol.ErrBadFrame, "That message was not understood.")
			continue
		}
		obs.MessagesIn.WithLabelValues(frame.Type).Inc()

		c.dispatch(frame)
	}
}

// dispatch routes one decoded frame.
func (c *Conn) dispatch(frame protocol.ClientFrame) {
	switch frame.Type {
	case protocol.TypePing:
		c.Send(protocol.Encode(protocol.Pong{
			Type: protocol.TypePong, T: frame.T, ServerTimeMs: time.Now().UnixMilli(),
		}))

	case protocol.TypeJoin:
		c.srv.handleJoin(c, frame)

	default:
		r, seat, joined := c.seatBinding()
		if !joined || r == nil {
			c.reject(protocol.ErrUnauthorized, "Join a table first.")
			return
		}
		r.Action(c, seat, frame)
	}
}

// teardown runs once the read pump ends, for any reason.
func (c *Conn) teardown() {
	r, seat, joined := c.seatBinding()
	if joined && r != nil {
		r.Disconnected(c, seat)
	}
	c.srv.releaseConn(c)
	c.Close("normal", "connection closed")
	obs.PlayersConnected.Dec()
}

// reject sends a non-fatal error; the client stays connected.
func (c *Conn) reject(code, message string) {
	obs.ProtocolErrors.WithLabelValues(code).Inc()
	c.Send(protocol.Encode(protocol.NewError(code, message, false)))
}

// Fail implements room.Client: it sends a fatal error and then closes the
// socket once the player has actually received the explanation. Closing from
// here would race the frame out of the queue and leave them with a bare
// "disconnected".
func (c *Conn) Fail(code, message string) {
	obs.ProtocolErrors.WithLabelValues(code).Inc()
	c.fatal.Store(true)
	c.Send(protocol.Encode(protocol.NewError(code, message, true)))
	c.finish()
}

// sendThenClose queues a final frame and closes once it is on the wire.
func (c *Conn) sendThenClose(frame []byte) {
	c.fatal.Store(true)
	c.Send(frame)
	c.finish()
}

// finish queues the close sentinel the write pump watches for.
func (c *Conn) finish() {
	select {
	case <-c.closed:
	case c.send <- nil:
	default:
		// Queue is full, so the client is not reading anyway.
		c.Close("policy", "closing")
	}
}
