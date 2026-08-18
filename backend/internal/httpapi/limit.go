package httpapi

import (
	"sync"
	"time"
)

// keyLimiter is a token bucket per caller, sized in requests per minute.
//
// Same shape as the socket's per-connection bucket (internal/ws/limit.go) —
// tokens accrue with elapsed time and are capped at the burst — but keyed by a
// string, because REST has no connection to hang state off. The key is the
// account id once a request is authenticated, and the client address on the one
// endpoint that runs before there is an account.
//
// A full minute of requests as the burst is deliberate: the client's real
// traffic is bursty (opening the profile fires three GETs at once) and then
// idle, which is exactly the shape a token bucket forgives.
type keyLimiter struct {
	mu      sync.Mutex
	rate    float64 // tokens per second
	burst   float64
	buckets map[string]*keyBucket
	// Sweeping happens inline rather than on a background goroutine: a limiter
	// with no goroutine cannot outlive the server that made it, which matters
	// most in tests, where one is built per case.
	lastSweep time.Time
	now       func() time.Time
}

type keyBucket struct {
	tokens float64
	last   time.Time
}

// sweepEvery is how often stale buckets are collected, and idleEviction is how
// long a caller must be quiet to be forgotten. Anything evicted comes back full,
// which is correct: a caller idle for that long has earned a full bucket anyway.
const (
	sweepEvery   = time.Minute
	idleEviction = 5 * time.Minute
)

// defaultPerMinute backs a zero-valued config. config.Load validates the real
// setting as positive, but a Config built by hand — in a test, or by a future
// caller — would otherwise get a limiter that refuses every request, which is a
// much more confusing failure than a sane default.
const defaultPerMinute = 120

func newKeyLimiter(perMinute int) *keyLimiter {
	if perMinute <= 0 {
		perMinute = defaultPerMinute
	}
	return &keyLimiter{
		rate:    float64(perMinute) / 60,
		burst:   float64(perMinute),
		buckets: make(map[string]*keyBucket),
		now:     time.Now,
	}
}

// allow spends one token for key, reporting whether there was one.
func (l *keyLimiter) allow(key string) bool {
	now := l.now()

	l.mu.Lock()
	defer l.mu.Unlock()

	l.sweep(now)

	b := l.buckets[key]
	if b == nil {
		b = &keyBucket{tokens: l.burst, last: now}
		l.buckets[key] = b
	}

	b.tokens += now.Sub(b.last).Seconds() * l.rate
	if b.tokens > l.burst {
		b.tokens = l.burst
	}
	b.last = now

	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}

// sweep drops buckets nobody has touched recently, so a server that has seen a
// million device ids does not hold a million buckets. Caller holds the lock.
func (l *keyLimiter) sweep(now time.Time) {
	if now.Sub(l.lastSweep) < sweepEvery {
		return
	}
	l.lastSweep = now
	for key, b := range l.buckets {
		if now.Sub(b.last) > idleEviction {
			delete(l.buckets, key)
		}
	}
}
