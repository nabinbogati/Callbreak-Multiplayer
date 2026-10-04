package engine

import (
	"bytes"
	"encoding/json"
	"math/rand/v2"
	"os"
	"path/filepath"
	"testing"
)

// The Godot client decodes these frames with GameView.from_dict. It tolerates
// missing keys by falling back to zero values, so a renamed or reshaped field
// does not crash it — it silently renders the wrong table instead, at runtime,
// on a phone, not here.
//
// So this test writes real server output to testdata/, and a matching client
// test (test_decodes_server_golden_view in godot/tests/test_engine.gd) decodes
// those exact bytes. Run `UPDATE_GOLDEN=1 go test ./internal/engine` after any
// deliberate encoding change, and the client test will tell you whether the
// client can still read it.

var update = os.Getenv("UPDATE_GOLDEN") != ""

// goldenViews captures one view per interesting phase, since the nullable
// fields (turn, bids, lastTrick, rankings) are populated differently in each
// and they are exactly the ones a decoder trips over.
func goldenViews(t *testing.T) map[string]*View {
	t.Helper()
	rng := rand.New(rand.NewPCG(20260809, 0x5eed))
	g := NewGame(testTable(), HandsPerGame, rng)

	out := map[string]*View{}

	g.Start()
	out["bidding"] = g.ViewFor(0)

	for i := 0; i < 4; i++ {
		g.PlaceBid(*g.Turn, 3)
	}
	out["playing"] = g.ViewFor(0)

	// Play one full trick so lastTrick and awaitingTrickClear are populated.
	for i := 0; i < 4; i++ {
		seat := *g.Turn
		g.PlayCard(seat, g.LegalMovesFor(seat)[0])
	}
	out["trickComplete"] = g.ViewFor(0)
	g.ClearTrick()

	// Run out the hand for a handOver view with round scores on it.
	for g.Phase == PhasePlaying {
		seat := *g.Turn
		g.PlayCard(seat, g.LegalMovesFor(seat)[0])
		if g.AwaitingTrickClr {
			g.ClearTrick()
		}
	}
	out["handOver"] = g.ViewFor(0)

	for g.Phase != PhaseGameOver {
		g.NextHand()
		for g.Phase == PhasePlaying || g.Phase == PhaseBidding {
			seat := *g.Turn
			if g.Phase == PhaseBidding {
				g.PlaceBid(seat, 3)
				continue
			}
			g.PlayCard(seat, g.LegalMovesFor(seat)[0])
			if g.AwaitingTrickClr {
				g.ClearTrick()
			}
		}
	}
	out["gameOver"] = g.ViewFor(0)

	// A spectator view: no seat, no cards. The client renders these too.
	out["spectator"] = g.ViewFor(-1)

	// A view with a live turn clock on it, which only the server ever produces.
	timed := g.ViewFor(0)
	timed.TurnDeadlineMs = 1786000015000
	timed.ServerTimeMs = 1786000000000
	out["withTurnClock"] = timed

	return out
}

func TestGoldenViewFrames(t *testing.T) {
	views := goldenViews(t)

	// Wrap each view exactly as the server sends it, type key and all, so the
	// client side is decoding a genuine frame rather than a bare view.
	frames := make(map[string]json.RawMessage, len(views))
	for name, view := range views {
		data, err := json.Marshal(view)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		wrapped := append([]byte(`{"type":"view",`), data[1:]...)
		frames[name] = wrapped
	}

	encoded, err := json.MarshalIndent(frames, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	encoded = append(encoded, '\n')

	path := filepath.Join("..", "..", "testdata", "view_frames.json")
	if update {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, encoded, 0o644); err != nil {
			t.Fatal(err)
		}
		t.Logf("wrote %s", path)
		return
	}

	existing, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("golden frames missing (%v); regenerate with UPDATE_GOLDEN=1 go test ./internal/engine", err)
	}
	if !bytes.Equal(existing, encoded) {
		t.Fatalf("the view encoding changed.\n\n"+
			"If that was deliberate, regenerate with:\n"+
			"    UPDATE_GOLDEN=1 go test ./internal/engine\n"+
			"then run the Godot suite — godot/tests/test_engine.gd "+
			"(test_decodes_server_golden_view) decodes these exact bytes and will "+
			"tell you whether the client can still read them.\n\ngolden file: %s", path)
	}
}
