package room

import "time"

// autoKind is what the table should do when its action deadline fires.
type autoKind int

const (
	autoNone autoKind = iota
	// autoClearTrick sweeps a finished trick once it has been on screen long
	// enough for everyone to see who took it.
	autoClearTrick
	// autoServerMove plays for a seat the server drives — a bot, or a human who
	// dropped.
	autoServerMove
	// autoTurnTimeout plays for a connected human who ran out of time.
	autoTurnTimeout
)

// deadlines are the table's pending clocks. A zero time means "not scheduled".
// They live in one struct so nextDeadline can pick the earliest without the
// actor loop needing a timer per concern.
type deadlines struct {
	autoAt   time.Time
	autoKind autoKind
	// autoSeat is the seat autoServerMove / autoTurnTimeout applies to; it is
	// captured when the deadline is set so a late fire cannot act on whoever
	// happens to be on the clock by then.
	autoSeat int

	// handAdvanceAt caps how long the table waits for stragglers to tap
	// "next hand".
	handAdvanceAt time.Time
	// countdownAt is when a quickplay table deals after its countdown.
	countdownAt time.Time
	// idleAt is when an empty room is collected.
	idleAt time.Time
}

func (d *deadlines) clearAuto() {
	d.autoAt = time.Time{}
	d.autoKind = autoNone
	d.autoSeat = -1
}

func (d *deadlines) setAuto(kind autoKind, seat int, at time.Time) {
	d.autoAt = at
	d.autoKind = kind
	d.autoSeat = seat
}

// nextDeadline is the earliest pending clock, or ok=false when the table has
// nothing scheduled.
func (r *Room) nextDeadline() (time.Time, bool) {
	var best time.Time
	consider := func(t time.Time) {
		if t.IsZero() {
			return
		}
		if best.IsZero() || t.Before(best) {
			best = t
		}
	}

	consider(r.autoAt)
	consider(r.handAdvanceAt)
	consider(r.countdownAt)
	consider(r.idleAt)
	for i := range r.seats {
		consider(r.seats[i].graceUntil)
	}
	return best, !best.IsZero()
}

// tick applies every deadline that has come due. It returns true when the room
// should shut down, which happens when it has sat empty past its idle TTL.
func (r *Room) tick() bool {
	now := time.Now()

	if !r.idleAt.IsZero() && !now.Before(r.idleAt) {
		if r.occupiedHumanSeats() == 0 {
			r.log.Info("collecting idle room")
			r.shutdown("idle")
			return true
		}
		// Somebody is still here; push the idle clock out.
		r.idleAt = now.Add(r.pacing.IdleTTL)
	}

	// Grace windows: a player who never came back loses the seat to a bot for
	// good, so the table stops holding a name nobody is behind.
	for i := range r.seats {
		s := &r.seats[i]
		if s.graceUntil.IsZero() || now.Before(s.graceUntil) {
			continue
		}
		s.graceUntil = time.Time{}
		r.expireSeat(i)
	}

	if !r.countdownAt.IsZero() && !now.Before(r.countdownAt) {
		r.countdownAt = time.Time{}
		r.beginGame()
		return false
	}

	if !r.handAdvanceAt.IsZero() && !now.Before(r.handAdvanceAt) {
		r.handAdvanceAt = time.Time{}
		r.advanceHand()
		return false
	}

	if !r.autoAt.IsZero() && !now.Before(r.autoAt) {
		kind, seat := r.autoKind, r.autoSeat
		r.clearAuto()
		r.runAuto(kind, seat)
	}
	return false
}
