package engine

import (
	"encoding/json"
	"fmt"
)

// The encodings here are a contract with godot/scripts/engine/game_view.gd. The key
// names, the nullability and the list shapes all have to match what
// GameView.from_dict expects, or the client throws while decoding a frame.
//
// Additive fields are safe: the client's decoder only reads the keys it knows.

// MarshalJSON encodes a card as its wire id, e.g. "AS".
func (c Card) MarshalJSON() ([]byte, error) { return json.Marshal(c.ID()) }

// UnmarshalJSON parses a wire id back into a card.
func (c *Card) UnmarshalJSON(data []byte) error {
	var id string
	if err := json.Unmarshal(data, &id); err != nil {
		return err
	}
	parsed, err := ParseCard(id)
	if err != nil {
		return err
	}
	*c = parsed
	return nil
}

// viewJSON is the exact shape the client's GameView.from_dict reads.
type viewJSON struct {
	Phase        Phase           `json:"phase"`
	HandIndex    int             `json:"handIndex"`
	HandsPerGame int             `json:"handsPerGame"`
	Dealer       int             `json:"dealer"`
	Turn         *int            `json:"turn"`
	Players      []PlayerInfo    `json:"players"`
	You          *int            `json:"you"`
	Hand         []Card          `json:"hand"`
	LegalMoveIDs []string        `json:"legalMoveIds"`
	HandCounts   []int           `json:"handCounts"`
	Bids         []*int          `json:"bids"`
	TricksWon    []int           `json:"tricksWon"`
	Trick        []TrickPlay     `json:"trick"`
	TrickNumber  int             `json:"trickNumber"`
	AwaitingClr  bool            `json:"awaitingTrickClear"`
	LastTrick    *CompletedTrick `json:"lastTrick"`
	RoundScores  [][]float64     `json:"roundScores"`
	Totals       []float64       `json:"totals"`
	Rankings     []SeatRanking   `json:"rankings"`

	TurnDeadlineMs int64 `json:"turnDeadlineMs,omitempty"`
	ServerTimeMs   int64 `json:"serverTimeMs,omitempty"`
	HandAdvanceMs  int64 `json:"handAdvanceMs,omitempty"`
	HostSeat       *int  `json:"hostSeat,omitempty"`
}

func (v *View) MarshalJSON() ([]byte, error) {
	out := viewJSON{
		Phase:          v.Phase,
		HandIndex:      v.HandIndex,
		HandsPerGame:   v.HandsPerGame,
		Dealer:         v.Dealer,
		Turn:           v.Turn,
		Players:        v.Players,
		You:            v.You,
		Hand:           v.Hand,
		LegalMoveIDs:   v.LegalMoveIDs,
		HandCounts:     v.HandCounts[:],
		Bids:           v.Bids[:],
		TricksWon:      v.TricksWon[:],
		Trick:          v.Trick,
		TrickNumber:    v.TrickNumber,
		AwaitingClr:    v.AwaitingClr,
		LastTrick:      v.LastTrick,
		RoundScores:    [][]float64{v.RoundScores[0], v.RoundScores[1], v.RoundScores[2], v.RoundScores[3]},
		Totals:         v.Totals[:],
		Rankings:       v.Rankings,
		TurnDeadlineMs: v.TurnDeadlineMs,
		ServerTimeMs:   v.ServerTimeMs,
		HandAdvanceMs:  v.HandAdvanceMs,
		HostSeat:       v.HostSeat,
	}
	if out.Hand == nil {
		out.Hand = []Card{}
	}
	if out.LegalMoveIDs == nil {
		out.LegalMoveIDs = []string{}
	}
	if out.Trick == nil {
		out.Trick = []TrickPlay{}
	}
	if out.Rankings == nil {
		out.Rankings = []SeatRanking{}
	}
	if out.Players == nil {
		out.Players = []PlayerInfo{}
	}
	for i := range out.RoundScores {
		if out.RoundScores[i] == nil {
			out.RoundScores[i] = []float64{}
		}
	}
	return json.Marshal(out)
}

// UnmarshalJSON exists so tests can round-trip a view and so snapshots taken
// from the Godot client can be replayed against the Go engine.
func (v *View) UnmarshalJSON(data []byte) error {
	var in viewJSON
	if err := json.Unmarshal(data, &in); err != nil {
		return err
	}
	if len(in.HandCounts) != 4 || len(in.Bids) != 4 || len(in.TricksWon) != 4 ||
		len(in.Totals) != 4 || len(in.RoundScores) != 4 {
		return fmt.Errorf("engine: view must carry four seats")
	}
	*v = View{
		Phase:          in.Phase,
		HandIndex:      in.HandIndex,
		HandsPerGame:   in.HandsPerGame,
		Dealer:         in.Dealer,
		Turn:           in.Turn,
		Players:        in.Players,
		You:            in.You,
		Hand:           in.Hand,
		LegalMoveIDs:   in.LegalMoveIDs,
		Trick:          in.Trick,
		TrickNumber:    in.TrickNumber,
		AwaitingClr:    in.AwaitingClr,
		LastTrick:      in.LastTrick,
		Rankings:       in.Rankings,
		TurnDeadlineMs: in.TurnDeadlineMs,
		ServerTimeMs:   in.ServerTimeMs,
		HandAdvanceMs:  in.HandAdvanceMs,
		HostSeat:       in.HostSeat,
	}
	for i := 0; i < 4; i++ {
		v.HandCounts[i] = in.HandCounts[i]
		v.Bids[i] = in.Bids[i]
		v.TricksWon[i] = in.TricksWon[i]
		v.Totals[i] = in.Totals[i]
		v.RoundScores[i] = in.RoundScores[i]
	}
	return nil
}
