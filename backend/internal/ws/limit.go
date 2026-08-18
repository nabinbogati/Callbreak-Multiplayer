package ws

import (
	"sync"
	"time"
)

// bucket is a token bucket sized in messages per second.
//
// It is deliberately tiny and allocation-free: there is one per connection, and
// it is consulted on every frame. Not safe for concurrent use — each bucket is
// touched only by its own read pump.
type bucket struct {
	rate   float64
	burst  float64
	tokens float64
	last   time.Time
}

func newBucket(rate float64, burst int) *bucket {
	return &bucket{
		rate:   rate,
		burst:  float64(burst),
		tokens: float64(burst),
		last:   time.Now(),
	}
}

func (b *bucket) allow() bool {
	now := time.Now()
	b.tokens += now.Sub(b.last).Seconds() * b.rate
	if b.tokens > b.burst {
		b.tokens = b.burst
	}
	b.last = now

	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}

// ipLimiter caps how many sockets one address may hold open.
//
// It is the cheapest defence against a single host opening thousands of
// connections: a real player needs one, maybe two while reconnecting, and a
// shared NAT still gets a generous allowance.
type ipLimiter struct {
	mu    sync.Mutex
	max   int
	conns map[string]int
}

func newIPLimiter(max int) *ipLimiter {
	return &ipLimiter{max: max, conns: make(map[string]int)}
}

// acquire reserves a slot for addr, reporting whether there was one free.
func (l *ipLimiter) acquire(addr string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.conns[addr] >= l.max {
		return false
	}
	l.conns[addr]++
	return true
}

func (l *ipLimiter) release(addr string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if n := l.conns[addr]; n <= 1 {
		delete(l.conns, addr)
	} else {
		l.conns[addr] = n - 1
	}
}

func (l *ipLimiter) count(addr string) int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.conns[addr]
}
