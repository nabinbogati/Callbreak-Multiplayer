package ws

import (
	"testing"
	"time"

	"github.com/nabin31bogati/callbreak/backend/internal/protocol"
)

func TestScratchPrivateHandsAffectsDeal(t *testing.T) {
	s := newStack(t)

	host := s.dial("Nabin")
	host.join("7QF2", map[string]any{"create": true, "handsPerGame": 3})
	host.awaitType(2*time.Second, protocol.TypeJoined)
	host.awaitType(2*time.Second, protocol.TypeLobby)

	guest := s.dial("Riya")
	guest.join("7QF2", nil)
	guest.awaitType(2*time.Second, protocol.TypeJoined)

	// Host switches to Normal Play before starting.
	host.send(map[string]any{"type": protocol.TypeHands, "hands": 5})
	host.await(2*time.Second, "lobby with 5", func(f frame) bool {
		return f.Type == protocol.TypeLobby && f.num("handsPerGame") == 5
	})
	g := guest.await(2*time.Second, "guest lobby with 5", func(f frame) bool {
		return f.Type == protocol.TypeLobby && f.num("handsPerGame") == 5
	})
	t.Logf("guest saw handsPerGame=%d", g.num("handsPerGame"))

	// Back to Quickplay, then deal.
	host.send(map[string]any{"type": protocol.TypeHands, "hands": 3})
	host.await(2*time.Second, "lobby with 3", func(f frame) bool {
		return f.Type == protocol.TypeLobby && f.num("handsPerGame") == 3
	})

	host.send(map[string]any{"type": protocol.TypeStart})
	v := host.await(2*time.Second, "first view", func(f frame) bool {
		return f.Type == protocol.TypeView
	})
	t.Logf("dealt view handsPerGame=%d", v.num("handsPerGame"))
	if v.num("handsPerGame") != 3 {
		t.Fatalf("dealt game plays %d hands, want 3", v.num("handsPerGame"))
	}
}
