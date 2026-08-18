// Package store holds the optional shared state that lets more than one server
// node cooperate.
//
// Everything here is optional by design. With no Redis configured the server
// runs as a single node and every table it knows about is its own, which is a
// perfectly good deployment for a small player base. Redis buys exactly one
// thing: the ability to tell a client "that table lives on another node, go
// there" instead of silently creating a second, empty table with the same code.
package store

import (
	"context"
	"log/slog"
	"sync"
	"time"

	"github.com/redis/go-redis/v9"
)

// Registry maps a room code to the node holding it.
type Registry interface {
	// Owner returns the endpoint of the node that owns the room, and whether
	// that node is somewhere other than this one.
	Owner(room string) (endpoint string, elsewhere bool)
	// Claim records this node as the owner.
	Claim(room string)
	// Release gives up ownership.
	Release(room string)
	// Close stops any background work.
	Close() error
}

// Memory is the single-node registry: every room is local, so Owner never
// redirects. It exists so the rest of the server can depend on the interface
// unconditionally.
type Memory struct{}

func (Memory) Owner(string) (string, bool) { return "", false }
func (Memory) Claim(string)                {}
func (Memory) Release(string)              {}
func (Memory) Close() error                { return nil }

// ownerTTL is how long a claim survives without a heartbeat. It has to outlast
// a stop-the-world pause comfortably, or a healthy node would lose its rooms.
const ownerTTL = 60 * time.Second

// heartbeatPeriod refreshes claims well inside ownerTTL.
const heartbeatPeriod = 20 * time.Second

const keyPrefix = "callbreak:room:"

// Redis is the shared registry.
//
// It is deliberately advisory rather than authoritative: a lookup failure or a
// Redis outage degrades the server to single-node behaviour instead of taking
// it down. Players might end up on the wrong node during an outage, which costs
// them a rejoin — far better than a server that refuses to seat anybody.
type Redis struct {
	client   *redis.Client
	endpoint string
	log      *slog.Logger

	mu    sync.Mutex
	owned map[string]struct{}

	stop chan struct{}
	once sync.Once
}

// NewRedis connects to Redis and starts the heartbeat. endpoint is how clients
// reach *this* node, and is what other nodes hand out in a redirect.
func NewRedis(ctx context.Context, url, endpoint string, log *slog.Logger) (*Redis, error) {
	opts, err := redis.ParseURL(url)
	if err != nil {
		return nil, err
	}
	client := redis.NewClient(opts)
	if err := client.Ping(ctx).Err(); err != nil {
		client.Close()
		return nil, err
	}

	r := &Redis{
		client:   client,
		endpoint: endpoint,
		log:      log,
		owned:    make(map[string]struct{}),
		stop:     make(chan struct{}),
	}
	go r.heartbeat()
	return r, nil
}

// Owner looks up which node holds a room.
func (r *Redis) Owner(room string) (string, bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()

	endpoint, err := r.client.Get(ctx, keyPrefix+room).Result()
	if err != nil {
		if err != redis.Nil {
			// Unreachable Redis must not block play. Treating the room as local
			// is the safe failure: at worst two nodes host tables with the same
			// code until the registry recovers.
			r.log.Warn("room registry lookup failed; treating the table as local",
				"room", room, "err", err)
		}
		return "", false
	}
	if endpoint == "" || endpoint == r.endpoint {
		return "", false
	}
	return endpoint, true
}

// Claim records this node as the room's owner. SetNX means the first node to
// create a room keeps it; a loser simply hosts nothing under that code.
func (r *Redis) Claim(room string) {
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()

	if err := r.client.SetNX(ctx, keyPrefix+room, r.endpoint, ownerTTL).Err(); err != nil {
		r.log.Warn("could not register a table", "room", room, "err", err)
		return
	}
	r.mu.Lock()
	r.owned[room] = struct{}{}
	r.mu.Unlock()
}

// releaseScript deletes the key only if this node still owns it, so a node that
// paused long enough to lose its claim cannot delete its successor's.
var releaseScript = redis.NewScript(`
if redis.call("GET", KEYS[1]) == ARGV[1] then
	return redis.call("DEL", KEYS[1])
end
return 0
`)

func (r *Redis) Release(room string) {
	r.mu.Lock()
	delete(r.owned, room)
	r.mu.Unlock()

	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	if err := releaseScript.Run(ctx, r.client, []string{keyPrefix + room}, r.endpoint).Err(); err != nil {
		// A stale claim expires on its own within ownerTTL, so a failure here
		// is not worth escalating.
		r.log.Debug("could not release a table claim", "room", room, "err", err)
	}
}

// heartbeat keeps this node's claims alive.
func (r *Redis) heartbeat() {
	ticker := time.NewTicker(heartbeatPeriod)
	defer ticker.Stop()

	for {
		select {
		case <-r.stop:
			return
		case <-ticker.C:
			r.mu.Lock()
			rooms := make([]string, 0, len(r.owned))
			for room := range r.owned {
				rooms = append(rooms, room)
			}
			r.mu.Unlock()
			if len(rooms) == 0 {
				continue
			}

			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			pipe := r.client.Pipeline()
			for _, room := range rooms {
				pipe.Expire(ctx, keyPrefix+room, ownerTTL)
			}
			if _, err := pipe.Exec(ctx); err != nil {
				r.log.Warn("room registry heartbeat failed", "rooms", len(rooms), "err", err)
			}
			cancel()
		}
	}
}

func (r *Redis) Close() error {
	r.once.Do(func() { close(r.stop) })
	return r.client.Close()
}
