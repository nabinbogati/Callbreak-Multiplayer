// Package ws is the network edge: it upgrades HTTP connections, authenticates
// guests, validates frames, and routes players either to a private table or
// into quickplay matchmaking.
//
// Nothing here knows the rules of Call Break. Its job is to make sure that by
// the time a message reaches a room actor it is well-formed, rate-limited, and
// attributable to a seat.
package ws

import (
	"log/slog"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/gorilla/websocket"

	"github.com/nabin31bogati/callbreak/backend/internal/auth"
	"github.com/nabin31bogati/callbreak/backend/internal/config"
	"github.com/nabin31bogati/callbreak/backend/internal/db"
	"github.com/nabin31bogati/callbreak/backend/internal/engine"
	"github.com/nabin31bogati/callbreak/backend/internal/match"
	"github.com/nabin31bogati/callbreak/backend/internal/obs"
	"github.com/nabin31bogati/callbreak/backend/internal/protocol"
	"github.com/nabin31bogati/callbreak/backend/internal/room"
)

// Server holds everything a connection needs.
type Server struct {
	cfg      config.Config
	hub      *room.Hub
	matcher  *match.Broker
	signer   *auth.Signer
	log      *slog.Logger
	health   *obs.Health
	upgrader websocket.Upgrader
	ips      *ipLimiter
	// Locator resolves which node owns a room, for multi-node deployments. Nil
	// means single-node: every table this server knows about is its own.
	Locator Locator

	// Users resolves a device id to a stored account. Nil or a disabled store
	// means play is unaffected and games are recorded without an account.
	Users db.Store
}

// Locator answers "who owns this table". It is satisfied by the Redis registry;
// leaving it nil keeps the server perfectly usable on one node. Claiming and
// releasing is the hub's job, so this is read-only.
type Locator interface {
	// Owner returns the public endpoint of the node holding the room, and
	// whether it is somewhere other than here.
	Owner(room string) (endpoint string, elsewhere bool)
}

func NewServer(cfg config.Config, hub *room.Hub, matcher *match.Broker, signer *auth.Signer, log *slog.Logger, health *obs.Health) *Server {
	s := &Server{
		cfg:     cfg,
		hub:     hub,
		matcher: matcher,
		signer:  signer,
		log:     log,
		health:  health,
		ips:     newIPLimiter(cfg.MaxConnsPerIP),
	}
	s.upgrader = websocket.Upgrader{
		HandshakeTimeout: 10 * time.Second,
		ReadBufferSize:   1024,
		WriteBufferSize:  4096,
		CheckOrigin:      s.checkOrigin,
	}
	return s
}

// checkOrigin gates browser clients. The Godot app sends no Origin header, so
// native clients always pass; a browser is only allowed when its origin has
// been configured explicitly.
func (s *Server) checkOrigin(r *http.Request) bool {
	origin := r.Header.Get("Origin")
	if origin == "" {
		return true
	}
	for _, allowed := range s.cfg.AllowedOrigins {
		if allowed == "*" || strings.EqualFold(allowed, origin) {
			return true
		}
	}
	return false
}

// Handler mounts the websocket endpoint.
func (s *Server) Handler(mux *http.ServeMux) {
	mux.HandleFunc("GET /ws", s.serveWS)
}

func (s *Server) serveWS(w http.ResponseWriter, r *http.Request) {
	if !s.health.Ready() {
		http.Error(w, "server is draining", http.StatusServiceUnavailable)
		return
	}

	ip := clientIP(r)
	if !s.ips.acquire(ip) {
		s.log.Warn("connection refused: too many sockets from one address",
			"ip", ip, "open", s.ips.count(ip))
		http.Error(w, "too many connections", http.StatusTooManyRequests)
		return
	}

	socket, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		// Upgrade already wrote a response.
		s.ips.release(ip)
		return
	}

	conn := newConn(s, socket, s.log.With("ip", ip, "remote", socket.RemoteAddr().String()))
	conn.ip = ip
	obs.PlayersConnected.Inc()

	go conn.writePump()
	go conn.readPump()
}

func (s *Server) releaseConn(c *Conn) {
	if c.ip != "" {
		s.ips.release(c.ip)
	}
}

// clientIP prefers the proxy headers a load balancer sets, falling back to the
// socket address. Only the first hop of X-Forwarded-For is meaningful.
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

// ------------------------------------------------------------------- joining

// handleJoin routes a join frame to a private table or into matchmaking.
func (s *Server) handleJoin(c *Conn, frame protocol.ClientFrame) {
	c.mu.Lock()
	already := c.joined
	c.mu.Unlock()
	if already {
		c.reject(protocol.ErrBadFrame, "You have already joined a table.")
		return
	}

	if frame.V > protocol.Version {
		c.Fail(protocol.ErrUnsupported,
			"This app is newer than the server. Please try again later.")
		return
	}

	// Identity first: everything below is attributed to this player.
	player, guestToken := s.signer.ResolveGuest(frame.GuestToken)
	c.mu.Lock()
	c.player = player
	c.guestToken = guestToken
	c.mu.Unlock()
	c.log = c.log.With("player", string(player))

	// Start resolving the account now, so the lookup runs alongside the join
	// rather than in front of it. Nothing below waits on it; see identity.go.
	lookup := s.resolveAccount(frame.DeviceID, protocol.SanitizeName(frame.Name), c.log)

	// Only matters when this join creates a fresh table; joining or resuming
	// an existing one always plays whatever hand count it was created with.
	totalHands := protocol.ResolveHandsPerGame(frame.HandsPerGame)
	// Same rule as hands: the deal preset only chooses the shuffle for a
	// brand-new table. An existing table keeps the deal it was created with.
	deal := engine.DealConfigFromPreset(protocol.ResolveDeal(frame.Deal))

	if frame.Mode == protocol.ModeOnline && frame.Room == protocol.QuickplayRoom {
		s.joinQuickplay(c, frame, lookup, totalHands, deal)
		return
	}
	s.joinPrivate(c, frame, lookup, totalHands, deal)
}

func (s *Server) joinPrivate(c *Conn, frame protocol.ClientFrame, lookup *accountLookup, totalHands int, deal engine.DealConfig) {
	code := frame.Room
	if !room.ValidRoomCode(code) {
		c.Fail(protocol.ErrBadFrame, "That room code is not valid.")
		return
	}

	// In a multi-node deployment the table may belong to another instance.
	// Sending the client there beats proxying every frame across the fleet.
	if s.Locator != nil {
		if endpoint, elsewhere := s.Locator.Owner(code); elsewhere {
			c.sendThenClose(protocol.Encode(protocol.NewRedirect(endpoint)))
			return
		}
	}

	// Only the room's creator opens a fresh table. A join to a room that is not
	// here is a mistyped or stale code, not a request to build a new empty room
	// — fail it, or guests would silently create tables they can never seem to
	// find again.
	var table *room.Room
	var created bool
	if frame.Create {
		var err error
		table, created, err = s.hub.GetOrCreate(code, protocol.ModePrivate, room.AutoStart{}, totalHands, deal)
		if err != nil {
			c.Fail(protocol.ErrCapacity, "This server is full. Try again shortly.")
			return
		}
	} else {
		var ok bool
		if table, ok = s.hub.Get(code); !ok {
			c.Fail(protocol.ErrRoomNotFound, "That room does not exist.")
			return
		}
	}

	req := room.JoinRequest{
		Client:     c,
		Player:     c.PlayerID(),
		Name:       protocol.SanitizeName(frame.Name),
		Difficulty: engine.ParseDifficulty(frame.Difficulty),
		Host:       created,
		UserID:     lookup.peek(),
	}
	if seat, ok := s.resumeClaim(frame, code, c.PlayerID()); ok {
		req.ResumeSeat = &seat
	}

	res := table.Join(req)
	if res.Err != "" {
		c.Fail(res.Err, res.ErrText)
		return
	}
	s.confirmSeat(c, table, res)
	lookup.attach(c, table, res.Seat)
}

// joinQuickplay seats a player at a table that is still filling, opening one if
// none has room. They are a real player at a real table immediately — there is
// no queue to be stuck in, which is what lets them see who else is waiting.
func (s *Server) joinQuickplay(c *Conn, frame protocol.ClientFrame, lookup *accountLookup, totalHands int, deal engine.DealConfig) {
	// A quickplay table is addressed by a generated code the client never
	// learns — the join frame only asks for QUICKPLAY — so a resume token is
	// the one thing that can still name the table a player dropped from.
	// Honouring it here is what lets a reconnecting "vs Humans" player reclaim
	// the exact seat they had instead of being dealt into a brand-new match.
	// A claim that no longer matches a live seat falls through to matchmaking.
	if claim, ok := s.quickplayResumeClaim(frame, c.PlayerID()); ok {
		// In a multi-node deployment the table may live on another instance.
		if s.Locator != nil {
			if endpoint, elsewhere := s.Locator.Owner(claim.Room); elsewhere {
				c.sendThenClose(protocol.Encode(protocol.NewRedirect(endpoint)))
				return
			}
		}
		if table, ok := s.hub.Get(claim.Room); ok && table.Mode() == protocol.ModeOnline {
			req := room.JoinRequest{
				Client:     c,
				Player:     c.PlayerID(),
				Name:       protocol.SanitizeName(frame.Name),
				Difficulty: engine.ParseDifficulty(frame.Difficulty),
				UserID:     lookup.peek(),
			}
			req.ResumeSeat = &claim.Seat
			if res := table.Join(req); res.Err == "" {
				s.confirmSeat(c, table, res)
				lookup.attach(c, table, res.Seat)
				return
			}
		}
	}

	table, res := s.matcher.Seat(room.JoinRequest{
		Client:     c,
		Player:     c.PlayerID(),
		Name:       protocol.SanitizeName(frame.Name),
		Difficulty: engine.ParseDifficulty(frame.Difficulty),
		UserID:     lookup.peek(),
	}, totalHands, deal)
	if res.Err != "" {
		c.Fail(res.Err, res.ErrText)
		return
	}
	s.confirmSeat(c, table, res)
	lookup.attach(c, table, res.Seat)
}

// confirmSeat binds the connection to its seat and hands the client its
// credentials.
func (s *Server) confirmSeat(c *Conn, table *room.Room, res room.JoinResult) {
	c.bind(table, res.Seat)

	c.mu.Lock()
	guestToken := c.guestToken
	player := c.player
	c.mu.Unlock()

	resume := s.signer.IssueResume(player, table.ID(), res.Seat)
	joined := protocol.NewJoined(
		res.Seat, table.ID(), res.IsHost, string(player), guestToken, resume, res.Reconnected,
	)
	joined.ReconnectGraceMs = s.cfg.ReconnectGrace.Milliseconds()
	c.Send(protocol.Encode(joined))
	obs.MessagesOut.WithLabelValues(protocol.TypeJoined).Inc()

	// Only now, with the seat number delivered, is a lobby or a view meaningful
	// to this client — both are written from that seat's point of view.
	table.Resync(c, res.Seat)

	c.log.Info("seated", "room", table.ID(), "seat", res.Seat, "host", res.IsHost)
}

// resumeClaim validates a resume token against the room being joined. A token
// for a different table is not an error worth failing the join over — the
// player simply gets a normal seat.
func (s *Server) resumeClaim(frame protocol.ClientFrame, code string, player auth.GuestID) (int, bool) {
	if frame.ResumeToken == "" {
		return 0, false
	}
	claim, err := s.signer.VerifyResume(frame.ResumeToken)
	if err != nil {
		return 0, false
	}
	if claim.Room != code || claim.Player != player {
		return 0, false
	}
	return claim.Seat, true
}

// quickplayResumeClaim validates a resume token for a quickplay join. Where
// [resumeClaim] cross-checks the claimed room against the one in the join frame,
// a quickplay join names only QUICKPLAY, so the token is the sole source of the
// table's identity. It verifies the token and that it names this player; the
// room still enforces, from its own state, that the seat is actually theirs.
func (s *Server) quickplayResumeClaim(frame protocol.ClientFrame, player auth.GuestID) (auth.Seat, bool) {
	if frame.ResumeToken == "" {
		return auth.Seat{}, false
	}
	claim, err := s.signer.VerifyResume(frame.ResumeToken)
	if err != nil {
		return auth.Seat{}, false
	}
	if claim.Player != player {
		return auth.Seat{}, false
	}
	return claim, true
}
