// Command loadtest drives N concurrent tables against a running server and
// reports how long the server takes to answer a move.
//
//	go run ./cmd/loadtest -url ws://localhost:8080/ws -tables 250
//
// Every synthetic player is a real websocket speaking the real protocol, and
// plays only cards the server told it were legal — so a rejected move is a
// server bug, not a lazy client. The number that matters is move latency: the
// wall time from sending a bid or a card to seeing the view that reflects it.
// That is what a player feels.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"math/rand/v2"
	"os"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"

	"github.com/nabin31bogati/callbreak/backend/internal/engine"
	"github.com/nabin31bogati/callbreak/backend/internal/protocol"
	"github.com/nabin31bogati/callbreak/backend/internal/room"
)

func main() {
	url := flag.String("url", "ws://localhost:8080/ws", "server websocket endpoint")
	tables := flag.Int("tables", 100, "concurrent tables")
	humans := flag.Int("humans", 4, "human clients per table (1-4); the rest are bots")
	ramp := flag.Duration("ramp", 5*time.Second, "spread table creation over this window")
	timeout := flag.Duration("timeout", 5*time.Minute, "give up after this long")
	flag.Parse()

	if *humans < 1 || *humans > 4 {
		fmt.Fprintln(os.Stderr, "humans must be between 1 and 4")
		os.Exit(2)
	}

	run := &run{url: *url, humans: *humans}
	start := time.Now()

	var wg sync.WaitGroup
	for i := 0; i < *tables; i++ {
		// Ramping avoids measuring a thundering herd on connect rather than the
		// steady-state cost of play.
		if *ramp > 0 {
			time.Sleep(*ramp / time.Duration(*tables))
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			run.playTable()
		}()
	}

	done := make(chan struct{})
	go func() { wg.Wait(); close(done) }()

	select {
	case <-done:
	case <-time.After(*timeout):
		fmt.Fprintf(os.Stderr, "timed out after %s\n", *timeout)
	}

	run.report(*tables, time.Since(start))
}

type run struct {
	url    string
	humans int

	mu        sync.Mutex
	latencies []time.Duration

	finished atomic.Int64
	failed   atomic.Int64
	moves    atomic.Int64
}

func (r *run) record(d time.Duration) {
	r.mu.Lock()
	r.latencies = append(r.latencies, d)
	r.mu.Unlock()
	r.moves.Add(1)
}

func (r *run) fail(format string, args ...any) {
	r.failed.Add(1)
	fmt.Fprintf(os.Stderr, format+"\n", args...)
}

// playTable seats `humans` clients in a fresh private room and plays it out.
func (r *run) playTable() {
	code := room.NewRoomCode()

	clients := make([]*client, 0, r.humans)
	for i := 0; i < r.humans; i++ {
		c, err := dial(r, r.url, code, fmt.Sprintf("load-%d", i))
		if err != nil {
			r.fail("dial: %v", err)
			for _, open := range clients {
				open.close()
			}
			return
		}
		clients = append(clients, c)
	}
	defer func() {
		for _, c := range clients {
			c.close()
		}
	}()

	// Wait for every client to learn its seat before the host deals, or the
	// table starts under a client that is not listening yet.
	for _, c := range clients {
		if !c.waitForSeat(30 * time.Second) {
			r.fail("table %s: a client never got a seat", code)
			return
		}
	}

	clients[0].send(map[string]any{"type": protocol.TypeStart})

	for _, c := range clients {
		<-c.done
	}
	r.finished.Add(1)
}

type client struct {
	run  *run
	ws   *websocket.Conn
	name string

	seat   int
	seated chan struct{}
	// done closes when this client's read loop ends, which is how the table
	// knows the game finished.
	done      chan struct{}
	seatOnce  sync.Once
	closeOnce sync.Once
	pending   atomic.Int64 // unix nanos of the move awaiting acknowledgement
}

func dial(r *run, url, code, name string) (*client, error) {
	socket, _, err := websocket.DefaultDialer.Dial(url+"?room="+code, nil)
	if err != nil {
		return nil, err
	}
	c := &client{
		run:    r,
		ws:     socket,
		name:   name,
		seat:   -1,
		seated: make(chan struct{}),
		done:   make(chan struct{}),
	}
	// Read from the moment the socket is open. The `joined` frame arrives
	// before anyone asks for it, so a client that only starts reading once it
	// wants something would sit waiting for a frame already on the wire.
	go c.play(4 * time.Minute)

	c.send(map[string]any{
		"type": protocol.TypeJoin,
		"v":    protocol.Version,
		"room": code,
		"mode": string(protocol.ModePrivate),
		"name": name,
	})
	return c, nil
}

func (c *client) send(v any) {
	data, err := json.Marshal(v)
	if err != nil {
		return
	}
	_ = c.ws.SetWriteDeadline(time.Now().Add(10 * time.Second))
	_ = c.ws.WriteMessage(websocket.TextMessage, data)
}

func (c *client) close() { c.closeOnce.Do(func() { _ = c.ws.Close() }) }

func (c *client) waitForSeat(d time.Duration) bool {
	select {
	case <-c.seated:
		return true
	case <-time.After(d):
		return false
	}
}

// play reads frames until the game ends, answering whenever it is this
// client's turn.
func (c *client) play(limit time.Duration) {
	defer close(c.done)
	deadline := time.Now().Add(limit)

	for {
		if time.Now().After(deadline) {
			c.run.fail("%s: gave up waiting for the game to finish", c.name)
			return
		}
		_ = c.ws.SetReadDeadline(deadline)
		_, data, err := c.ws.ReadMessage()
		if err != nil {
			return
		}

		var head struct {
			Type  string `json:"type"`
			Seat  int    `json:"seat"`
			Code  string `json:"code"`
			Fatal bool   `json:"fatal"`
		}
		if err := json.Unmarshal(data, &head); err != nil {
			continue
		}

		switch head.Type {
		case protocol.TypeJoined:
			c.seat = head.Seat
			c.markSeated()
		case protocol.TypeError:
			// The point of the harness is to prove the server stays correct
			// under load, so every rejection is worth surfacing.
			c.run.fail("%s: server error %s (fatal=%v)", c.name, head.Code, head.Fatal)
			if head.Fatal {
				return
			}
		case protocol.TypeView:
			var view engine.View
			if err := json.Unmarshal(data, &view); err != nil {
				continue
			}
			// Any view is the acknowledgement of whatever we last sent.
			if sent := c.pending.Swap(0); sent != 0 {
				c.run.record(time.Duration(time.Now().UnixNano() - sent))
			}
			if view.Phase == engine.PhaseGameOver {
				return
			}
			c.respond(&view)
		}
	}
}

func (c *client) markSeated() { c.seatOnce.Do(func() { close(c.seated) }) }

func (c *client) respond(view *engine.View) {
	switch view.Phase {
	case engine.PhaseBidding:
		if view.Turn != nil && *view.Turn == c.seat && view.Bids[c.seat] == nil {
			c.pending.Store(time.Now().UnixNano())
			c.send(map[string]any{"type": protocol.TypeBid, "bid": engine.SuggestBid(view.Hand)})
		}
	case engine.PhasePlaying:
		if view.Turn != nil && *view.Turn == c.seat && len(view.LegalMoveIDs) > 0 {
			card := view.LegalMoveIDs[rand.IntN(len(view.LegalMoveIDs))]
			c.pending.Store(time.Now().UnixNano())
			c.send(map[string]any{"type": protocol.TypePlay, "card": card})
		}
	case engine.PhaseHandOver:
		c.send(map[string]any{"type": protocol.TypeNext})
	}
}

func (r *run) report(tables int, elapsed time.Duration) {
	r.mu.Lock()
	samples := append([]time.Duration(nil), r.latencies...)
	r.mu.Unlock()

	sort.Slice(samples, func(i, j int) bool { return samples[i] < samples[j] })

	pct := func(p float64) time.Duration {
		if len(samples) == 0 {
			return 0
		}
		i := int(float64(len(samples)-1) * p)
		return samples[i]
	}

	fmt.Printf("\ntables requested   %d\n", tables)
	fmt.Printf("tables completed   %d\n", r.finished.Load())
	fmt.Printf("moves acknowledged %d\n", r.moves.Load())
	fmt.Printf("errors             %d\n", r.failed.Load())
	fmt.Printf("wall time          %s\n", elapsed.Round(time.Millisecond))
	fmt.Printf("\nmove latency (send → authoritative view)\n")
	fmt.Printf("  p50  %s\n", pct(0.50).Round(time.Microsecond))
	fmt.Printf("  p90  %s\n", pct(0.90).Round(time.Microsecond))
	fmt.Printf("  p99  %s\n", pct(0.99).Round(time.Microsecond))
	if len(samples) > 0 {
		fmt.Printf("  max  %s\n", samples[len(samples)-1].Round(time.Microsecond))
	}
}
