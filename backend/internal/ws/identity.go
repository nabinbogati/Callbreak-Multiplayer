package ws

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/nabin31bogati/callbreak/backend/internal/db"
	"github.com/nabin31bogati/callbreak/backend/internal/room"
)

// identityTimeout bounds the account lookup. Nothing waits on it — see
// accountLookup — but a lookup that has not answered within this long is not
// going to be useful to a player who is already at a table, so the goroutine
// gives up rather than lingering.
const identityTimeout = 2 * time.Second

// accountLookup is a device id being resolved to an account, off the join path.
//
// docs/PERSISTENCE.md §4.1: identity is an enrichment of the session, never a
// precondition for it. So the join never waits on the database. The lookup is
// started as soon as the frame is decoded and runs alongside the real work of
// joining — validating the room code, finding or opening the table, and the
// actor round-trip that allocates the seat. Whatever has landed by the time the
// JoinRequest is built rides along on it; anything slower is attached to the
// seat afterwards with room.AttachUser. Either way the player sits down at the
// same moment they would have with no database at all, and a dead Postgres
// costs an attribution rather than a game.
type accountLookup struct {
	// id is written before done is closed and read only after done is observed
	// closed, which is the happens-before edge that makes it safe without a lock.
	id   string
	done chan struct{}
	// delivered records that peek already handed the id to the JoinRequest.
	// Only ever touched by the read pump — the one goroutine that calls peek
	// and attach, in that order — so it needs no synchronisation of its own.
	delivered bool
}

// resolveAccount starts a lookup, or returns nil when there is nothing to look
// up: no store, a disabled store, or a client that sent no device id.
func (s *Server) resolveAccount(deviceID, name string, log *slog.Logger) *accountLookup {
	store := s.Users
	if store == nil || !store.Enabled() || deviceID == "" {
		return nil
	}

	l := &accountLookup{done: make(chan struct{})}
	go func() {
		defer close(l.done)
		ctx, cancel := context.WithTimeout(context.Background(), identityTimeout)
		defer cancel()

		user, err := store.ResolveIdentity(ctx, db.ProviderDevice, deviceID, name)
		if err != nil {
			// Every failure means the same thing to the table: no account. A
			// disabled store is not worth a log line; anything else is, because
			// it is silently costing history.
			if !errors.Is(err, db.ErrDisabled) {
				log.Warn("could not resolve a device id to an account; "+
					"seating anyway with no account", "err", err)
			}
			return
		}
		l.id = user.ID
	}()
	return l
}

// peek returns the account if the lookup has already finished, and never waits.
func (l *accountLookup) peek() string {
	if l == nil {
		return ""
	}
	select {
	case <-l.done:
		l.delivered = true
		return l.id
	default:
		return ""
	}
}

// attach delivers a late answer to the seat. It is a no-op when peek already
// carried the id onto the JoinRequest, so the common case where the database
// answered before the actor did costs no extra goroutine and no extra room
// message. The test is peek's own record rather than the channel: the lookup
// may well have finished in between, and that answer still has to reach a seat
// that was allocated without it.
func (l *accountLookup) attach(c *Conn, table *room.Room, seat int) {
	if l == nil || table == nil || l.delivered {
		return
	}
	go func() {
		<-l.done
		table.AttachUser(c, seat, l.id)
	}()
}
