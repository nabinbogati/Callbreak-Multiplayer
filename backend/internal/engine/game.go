package engine

import (
	"math/rand/v2"
)

// Phase mirrors the client's GameView phases. The string forms are the wire values.
type Phase string

const (
	PhaseLobby    Phase = "lobby"
	PhaseBidding  Phase = "bidding"
	PhasePlaying  Phase = "playing"
	PhaseHandOver Phase = "handOver"
	PhaseGameOver Phase = "gameOver"
)

// PlayerKind distinguishes a seated human from a server-driven bot.
type PlayerKind string

const (
	KindHuman PlayerKind = "human"
	KindBot   PlayerKind = "bot"
)

// Difficulty tunes how much noise and how many blunders a bot brain injects.
type Difficulty string

const (
	Easy   Difficulty = "easy"
	Normal Difficulty = "normal"
	Hard   Difficulty = "hard"
)

// ParseDifficulty accepts a wire value, falling back to Normal for anything
// unrecognised — difficulty arrives from untrusted clients and is not worth
// rejecting a join over.
func ParseDifficulty(s string) Difficulty {
	switch Difficulty(s) {
	case Easy, Normal, Hard:
		return Difficulty(s)
	}
	return Normal
}

// PlayerInfo is the public description of a seat. Mirrors the client's player dictionaries,
// including the `connected` flag the client renders as a dimmed avatar.
type PlayerInfo struct {
	Seat       int        `json:"seat"`
	Name       string     `json:"name"`
	Kind       PlayerKind `json:"kind"`
	Difficulty Difficulty `json:"difficulty"`
	Connected  bool       `json:"connected"`

	// Autoplay is set while the server is playing this seat because its human
	// stopped responding. Like Connected it is a fact about the player rather
	// than the rules, but it belongs here for the same reason: everyone at the
	// table can see it, so it travels in the view.
	Autoplay bool `json:"autoplay"`
}

func (p PlayerInfo) IsBot() bool { return p.Kind == KindBot }

// CompletedTrick is the finished trick still on the table during the linger.
type CompletedTrick struct {
	Plays  []TrickPlay `json:"plays"`
	Winner int         `json:"winner"`
}

// SeatRanking is a final standing, sorted best first.
type SeatRanking struct {
	Seat  int     `json:"seat"`
	Place int     `json:"place"`
	Total float64 `json:"total"`
}

// Game is the authoritative state machine for one table.
//
// It is not safe for concurrent use: exactly one goroutine (the room actor)
// owns an instance. Mutating methods return false when the move was illegal or
// out of turn, and leave state untouched — the caller turns that into a
// protocol error without any rollback of its own.
type Game struct {
	TotalHands int

	Phase     Phase
	HandIndex int

	// Dealer starts at 3 so the first hand is dealt by seat 0 and led by seat 1.
	Dealer int
	Turn   *int

	Bids             [4]*int
	TricksWon        [4]int
	Trick            []TrickPlay
	TrickNumber      int
	AwaitingTrickClr bool
	LastTrick        *CompletedTrick
	RoundScores      [4][]float64
	Totals           [4]float64
	Rankings         []SeatRanking
	PlayedThisHand   []Card

	players [4]PlayerInfo
	hands   [4][]Card
	pending []Event
	rng     *rand.Rand
	// DealConfig is how each hand is shuffled and dealt. Defaults to the fair
	// shuffle-and-cut; SetDealConfig overrides it before Start.
	DealConfig DealConfig
}

// NewGame builds a table in the lobby phase. rng must be non-nil; the room
// seeds it from crypto/rand so deals are unpredictable.
func NewGame(players [4]PlayerInfo, totalHands int, rng *rand.Rand) *Game {
	if totalHands <= 0 {
		totalHands = HandsPerGame
	}
	g := &Game{
		TotalHands: totalHands,
		Phase:      PhaseLobby,
		Dealer:     3,
		players:    players,
		rng:        rng,
	}
	for i := range g.RoundScores {
		g.RoundScores[i] = []float64{}
	}
	return g
}

// Players returns a copy of the seat table.
func (g *Game) Players() [4]PlayerInfo { return g.players }

// Player returns one seat's info.
func (g *Game) Player(seat int) PlayerInfo { return g.players[seat] }

// SetPlayer replaces a seat's info — used when a human drops, reconnects, or is
// swapped for a bot. It never touches cards, so it is safe mid-hand.
func (g *Game) SetPlayer(seat int, info PlayerInfo) {
	info.Seat = seat
	g.players[seat] = info
}

// SetDealConfig chooses how future hands are shuffled and dealt. It must be
// called before Start — deals already made keep the config they were made with.
func (g *Game) SetDealConfig(cfg DealConfig) {
	g.DealConfig = cfg
}

// HandOf returns a copy of a seat's remaining cards.
func (g *Game) HandOf(seat int) []Card {
	out := make([]Card, len(g.hands[seat]))
	copy(out, g.hands[seat])
	return out
}

// TakeEvents drains everything that has happened since the last call.
func (g *Game) TakeEvents() []Event {
	if len(g.pending) == 0 {
		return nil
	}
	out := g.pending
	g.pending = nil
	return out
}

// ------------------------------------------------------------------ lifecycle

// Start deals the first hand. No-op unless the game is still in the lobby.
func (g *Game) Start() {
	if g.Phase != PhaseLobby {
		return
	}
	g.startHand(0)
}

func (g *Game) startHand(index int) {
	g.HandIndex = index
	g.Dealer = (g.Dealer + 1) % 4
	g.hands = DealHandsWith(g.DealConfig, g.rng)
	g.Bids = [4]*int{}
	g.TricksWon = [4]int{}
	g.Trick = nil
	g.TrickNumber = 0
	g.AwaitingTrickClr = false
	g.LastTrick = nil
	g.PlayedThisHand = g.PlayedThisHand[:0]
	g.Phase = PhaseBidding
	g.setTurn((g.Dealer + 1) % 4)
	g.pending = append(g.pending, HandStarted{HandIndex: index})
}

// NextHand leaves the between-hands summary for the next deal, or ends the game.
func (g *Game) NextHand() {
	if g.Phase != PhaseHandOver {
		return
	}
	if g.HandIndex+1 >= g.TotalHands {
		g.finish()
	} else {
		g.startHand(g.HandIndex + 1)
	}
}

func (g *Game) finish() {
	g.Phase = PhaseGameOver
	g.Turn = nil

	seats := []int{0, 1, 2, 3}
	// Stable descending sort by total, so equal totals keep seat order.
	for i := 1; i < len(seats); i++ {
		for j := i; j > 0 && g.Totals[seats[j]] > g.Totals[seats[j-1]]; j-- {
			seats[j], seats[j-1] = seats[j-1], seats[j]
		}
	}
	g.Rankings = make([]SeatRanking, 0, 4)
	for i, seat := range seats {
		g.Rankings = append(g.Rankings, SeatRanking{Seat: seat, Place: i + 1, Total: g.Totals[seat]})
	}
	g.pending = append(g.pending, GameOver{Rankings: append([]SeatRanking(nil), g.Rankings...)})
}

// ------------------------------------------------------------------- bidding

// PlaceBid records a bid, clamped into range. Returns false when it was not
// this seat's turn, the phase is wrong, or the seat already bid.
func (g *Game) PlaceBid(seat, bid int) bool {
	if g.Phase != PhaseBidding || g.Turn == nil || *g.Turn != seat || g.Bids[seat] != nil {
		return false
	}
	value := ClampBid(bid)
	g.Bids[seat] = &value
	g.pending = append(g.pending, BidPlaced{Seat: seat, Bid: value})

	complete := true
	for _, b := range g.Bids {
		if b == nil {
			complete = false
			break
		}
	}
	if complete {
		g.Phase = PhasePlaying
		g.setTurn((g.Dealer + 1) % 4)
		g.pending = append(g.pending, BiddingComplete{})
	} else {
		g.setTurn((seat + 1) % 4)
	}
	return true
}

// ---------------------------------------------------------------------- play

// LegalMovesFor is the set of cards a seat may play right now — empty unless it
// is that seat's turn in the playing phase with no trick awaiting clearance.
func (g *Game) LegalMovesFor(seat int) []Card {
	if g.Phase != PhasePlaying || g.Turn == nil || *g.Turn != seat || g.AwaitingTrickClr {
		return nil
	}
	return LegalMoves(g.hands[seat], g.Trick)
}

// PlayCard plays one card for a seat. Returns false — changing nothing — when
// the move is out of turn, out of phase, not in hand, or illegal.
func (g *Game) PlayCard(seat int, card Card) bool {
	if g.Phase != PhasePlaying || g.Turn == nil || *g.Turn != seat || g.AwaitingTrickClr {
		return false
	}
	if !Contains(g.hands[seat], card) {
		return false
	}
	if !IsLegalPlay(g.hands[seat], g.Trick, card) {
		return false
	}

	g.hands[seat], _ = remove(g.hands[seat], card)
	g.PlayedThisHand = append(g.PlayedThisHand, card)
	g.Trick = append(g.Trick, TrickPlay{Seat: seat, Card: card})
	g.pending = append(g.pending, CardPlayed{Seat: seat, Card: card})

	if len(g.Trick) == 4 {
		winner := TrickWinner(g.Trick)
		g.AwaitingTrickClr = true
		g.Turn = nil
		plays := make([]TrickPlay, len(g.Trick))
		copy(plays, g.Trick)
		g.LastTrick = &CompletedTrick{Plays: plays, Winner: winner}
		g.pending = append(g.pending, TrickWon{Seat: winner})
	} else {
		g.setTurn((seat + 1) % 4)
	}
	return true
}

// ClearTrick is called by the room once the finished trick has been on screen
// long enough. It banks the trick and either leads the next one or ends the hand.
func (g *Game) ClearTrick() {
	if !g.AwaitingTrickClr {
		return
	}
	winner := g.LastTrick.Winner
	g.TricksWon[winner]++
	g.Trick = nil
	g.TrickNumber++
	g.AwaitingTrickClr = false

	if g.TrickNumber >= TricksPerHand {
		g.endHand()
	} else {
		g.setTurn(winner)
	}
}

func (g *Game) endHand() {
	deltas := make([]float64, 4)
	for seat := 0; seat < 4; seat++ {
		bid := 0
		if g.Bids[seat] != nil {
			bid = *g.Bids[seat]
		}
		deltas[seat] = ScoreHand(bid, g.TricksWon[seat])
	}
	for seat := 0; seat < 4; seat++ {
		g.RoundScores[seat] = append(g.RoundScores[seat], deltas[seat])
		g.Totals[seat] = Round1(g.Totals[seat] + deltas[seat])
	}
	g.pending = append(g.pending, HandOver{HandIndex: g.HandIndex, Deltas: deltas})
	if g.HandIndex+1 >= g.TotalHands {
		g.finish()
	} else {
		g.Phase = PhaseHandOver
		g.Turn = nil
	}
}

func (g *Game) setTurn(seat int) {
	s := seat
	g.Turn = &s
}

// --------------------------------------------------------------------- views

// ViewFor is the state a seat may see: its own cards in full, everyone else's
// reduced to a count. Pass -1 for a spectator view.
//
// This is the only way state leaves the engine, which is what keeps a client
// from ever receiving another player's cards.
func (g *Game) ViewFor(seat int) *View {
	v := &View{
		Phase:        g.Phase,
		HandIndex:    g.HandIndex,
		HandsPerGame: g.TotalHands,
		Dealer:       g.Dealer,
		TrickNumber:  g.TrickNumber,
		AwaitingClr:  g.AwaitingTrickClr,
		LastTrick:    g.LastTrick,
	}
	if g.Turn != nil {
		t := *g.Turn
		v.Turn = &t
	}
	v.Players = append(v.Players, g.players[:]...)
	if seat >= 0 && seat < 4 {
		s := seat
		v.You = &s
		v.Hand = SortForDisplay(g.hands[seat])
		for _, c := range g.LegalMovesFor(seat) {
			v.LegalMoveIDs = append(v.LegalMoveIDs, c.ID())
		}
	}
	if v.Hand == nil {
		v.Hand = []Card{}
	}
	if v.LegalMoveIDs == nil {
		v.LegalMoveIDs = []string{}
	}
	for i := 0; i < 4; i++ {
		v.HandCounts[i] = len(g.hands[i])
		v.Bids[i] = g.Bids[i]
		v.TricksWon[i] = g.TricksWon[i]
		v.Totals[i] = g.Totals[i]
		v.RoundScores[i] = append([]float64{}, g.RoundScores[i]...)
	}
	v.Trick = append([]TrickPlay{}, g.Trick...)
	v.Rankings = append([]SeatRanking{}, g.Rankings...)
	return v
}

// View is what one seat is allowed to see. The JSON encoding is byte-compatible
// with the client's GameView.from_dict — see json.go.
type View struct {
	Phase        Phase
	HandIndex    int
	HandsPerGame int
	Dealer       int
	Turn         *int
	Players      []PlayerInfo
	You          *int
	Hand         []Card
	LegalMoveIDs []string
	HandCounts   [4]int
	Bids         [4]*int
	TricksWon    [4]int
	Trick        []TrickPlay
	TrickNumber  int
	AwaitingClr  bool
	LastTrick    *CompletedTrick
	RoundScores  [4][]float64
	Totals       [4]float64
	Rankings     []SeatRanking

	// Server-only additions, ignored by older clients. TurnDeadlineMs is the
	// unix-millis instant the current turn is auto-played; it drives the
	// countdown ring in the UI. Zero means "no clock running".
	TurnDeadlineMs int64
	ServerTimeMs   int64

	// HandAdvanceMs is the unix-millis instant the between-hands scoreboard
	// stops waiting and the next hand is dealt regardless of who has tapped
	// "next hand". It drives the countdown on the scoreboard, so a player
	// reading it knows the table is not stuck. Zero outside PhaseHandOver.
	HandAdvanceMs int64

	// HostSeat is the seat that may start/restart this table, so every client —
	// including a late joiner who never saw a lobby — can tell who is running
	// it. Nil on a hostless (quickplay) table.
	HostSeat *int
}
