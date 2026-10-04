package ws

import (
	"testing"
	"time"

	"github.com/nabin31bogati/callbreak/backend/internal/config"
	"github.com/nabin31bogati/callbreak/backend/internal/engine"
	"github.com/nabin31bogati/callbreak/backend/internal/protocol"
	"github.com/nabin31bogati/callbreak/backend/internal/room"
)

// TestBotsDoNotBidWhileTheCardsAreBeingDealt checks that bidding opens only
// once the dealing animation is over, whoever is next to bid. Here the first
// bidder answers instantly, mid-deal, which hands the turn to a bot; that bot
// must still hold its bid until DealGrace after the deal rather than bidding
// after its usual think time, which would show its bid while the cards are
// still flying on everybody's screen.
func TestBotsDoNotBidWhileTheCardsAreBeingDealt(t *testing.T) {
	const grace = 600 * time.Millisecond
	s := newStack(t, func(_ *config.Config, p *room.Pacing) {
		p.BidTimeout = 5 * time.Second
		p.DealGrace = grace
		p.BotThinkMin = time.Millisecond
		p.BotThinkExtra = time.Millisecond
	})

	host := s.dial("Host")
	host.join("DEAL", map[string]any{"create": true})
	host.awaitType(2*time.Second, protocol.TypeJoined)
	partner := s.dial("partner")
	partner.join("DEAL", nil)
	partner.awaitType(2*time.Second, protocol.TypeJoined)

	host.send(map[string]any{"type": protocol.TypeStart})

	// The deal hands the first bid to seat 1 (the partner, dealer is seat 0);
	// seats 2 and 3 are bots.
	var dealtAt int64
	partner.await(2*time.Second, "the deal", func(f frame) bool {
		if f.Type != protocol.TypeView {
			return false
		}
		var v engine.View
		if err := decodeInto(f.Data, &v); err != nil {
			return false
		}
		if v.Phase != engine.PhaseBidding || v.Turn == nil || *v.Turn != 1 {
			return false
		}
		dealtAt = v.ServerTimeMs
		return true
	})
	partner.send(map[string]any{"type": protocol.TypeBid, "bid": engine.SuggestBid(partner.currentView().Hand)})

	f := host.await(3*time.Second, "the bot in seat 2 to bid", func(f frame) bool {
		if f.Type != protocol.TypeView {
			return false
		}
		var v engine.View
		if err := decodeInto(f.Data, &v); err != nil {
			return false
		}
		return v.Bids[2] != nil
	})
	var v engine.View
	if err := decodeInto(f.Data, &v); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if elapsed := time.Duration(v.ServerTimeMs-dealtAt) * time.Millisecond; elapsed < grace-50*time.Millisecond {
		t.Fatalf("bot bid %v after the deal, before bidding opened at %v", elapsed, grace)
	}
}
