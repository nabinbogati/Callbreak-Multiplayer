package engine

// Event is a discrete thing that happened at the table, for the client to
// animate and announce. The set matches Dart's sealed GameEvent hierarchy;
// Wire() produces the `event` frame body the client already decodes.
type Event interface {
	// Wire returns the JSON body of the event, without the outer "type" key.
	Wire() map[string]any
}

type HandStarted struct{ HandIndex int }

func (e HandStarted) Wire() map[string]any {
	return map[string]any{"event": "handStart", "handIndex": e.HandIndex}
}

type BidPlaced struct {
	Seat int
	Bid  int
}

func (e BidPlaced) Wire() map[string]any {
	return map[string]any{"event": "bid", "seat": e.Seat, "bid": e.Bid}
}

type BiddingComplete struct{}

func (e BiddingComplete) Wire() map[string]any {
	return map[string]any{"event": "biddingComplete"}
}

type CardPlayed struct {
	Seat int
	Card Card
}

func (e CardPlayed) Wire() map[string]any {
	return map[string]any{"event": "play", "seat": e.Seat, "card": e.Card.ID()}
}

type TrickWon struct{ Seat int }

func (e TrickWon) Wire() map[string]any {
	return map[string]any{"event": "trickWon", "seat": e.Seat}
}

type HandOver struct {
	HandIndex int
	Deltas    []float64
}

func (e HandOver) Wire() map[string]any {
	return map[string]any{"event": "handOver", "handIndex": e.HandIndex, "deltas": e.Deltas}
}

type GameOver struct{ Rankings []SeatRanking }

func (e GameOver) Wire() map[string]any {
	return map[string]any{"event": "gameOver", "rankings": e.Rankings}
}
