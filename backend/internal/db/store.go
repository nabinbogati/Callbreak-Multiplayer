// Package db is the persistence boundary.
//
// Everything the server stores — accounts, finished games, per-scope statistics
// — goes through the Store interface defined here. The design is documented in
// docs/PERSISTENCE.md; this file is the contract that document describes, and it
// is deliberately the only thing the rest of the server imports. Nothing outside
// this package knows that the backing store is Postgres.
//
// Persistence is optional. Nop satisfies the whole interface by doing nothing
// and reporting ErrDisabled, so `go run ./cmd/server` with no DATABASE_URL keeps
// working exactly as it did before any of this existed. Callers treat
// ErrDisabled as "not an error, just nothing to record".
package db

import (
	"context"
	"errors"
	"time"
)

var (
	// ErrDisabled is returned by every Nop method. It means persistence is not
	// configured, which is a supported deployment rather than a failure.
	ErrDisabled = errors.New("db: persistence is not configured")
	// ErrNotFound is a lookup that matched nothing.
	ErrNotFound = errors.New("db: not found")
	// ErrConflict is a unique-constraint violation the caller can act on, such
	// as linking a provider identity that already belongs to someone else.
	ErrConflict = errors.New("db: conflict")
	// ErrNotGuest says an operation that only makes sense from a bare guest
	// account was attempted from one that has signed in some other way.
	ErrNotGuest = errors.New("db: account is not a guest")
)

// ---------------------------------------------------------------- identity

// Provider names an authentication method. Device is the guest path: no login,
// just an id the app generates on first launch and keeps. The rest arrive
// through Firebase and are not wired up yet — the schema carries them so that
// adding the verification step later is not a migration.
type Provider string

const (
	ProviderDevice   Provider = "device"
	ProviderGoogle   Provider = "google"
	ProviderFacebook Provider = "facebook"
	ProviderApple    Provider = "apple"
)

// Valid reports whether p is a provider the schema accepts.
func (p Provider) Valid() bool {
	switch p {
	case ProviderDevice, ProviderGoogle, ProviderFacebook, ProviderApple:
		return true
	}
	return false
}

// User is an account. Guests are ordinary users with is_guest set and a single
// device identity; linking a login clears the flag without touching anything
// else the user owns.
type User struct {
	ID          string
	DisplayName string
	IsGuest     bool
	AvatarID    string
	Country     string
	CreatedAt   time.Time
	LastSeenAt  time.Time
	// MergedInto is set on a guest account that has been absorbed into a
	// signed-in one. Such a row is kept rather than deleted so tokens still in
	// flight resolve to somewhere sensible.
	MergedInto string
}

// Identity is one way of proving you are a User. A user may have several.
type Identity struct {
	UserID   string
	Provider Provider
	// Subject is the provider's opaque id: the device id for ProviderDevice,
	// the Firebase uid otherwise.
	Subject   string
	Email     string
	CreatedAt time.Time
}

// AbandonedAccount is the fresh-install account a restore replaced, kept only
// because it still has games the player might want to bring over. The restore
// moved its device identity, so it has no sign-in method left — nobody can
// ever reach it again except through the merge/discard endpoints.
type AbandonedAccount struct {
	ID string
	// Games is how many games the abandoned account still owns, each one
	// waiting on the player's merge-or-discard decision.
	Games int
}

// RestoreResult is what RestoreAccount returns: the restored account, plus the
// install it replaced when that install had history worth an offer.
type RestoreResult struct {
	User User
	// Abandoned is nil when the replaced install had no history at all — it
	// was deleted as part of the restore — or when there was nothing to
	// replace (restoring the account the device already owns).
	Abandoned *AbandonedAccount
}

// ------------------------------------------------------------------- games

// Mode mirrors protocol.Mode plus the two modes that never reach the server as
// live play. Kept as its own type so the db package does not import protocol
// and create an import cycle with room.
type Mode string

const (
	ModeBots    Mode = "bots"
	ModePrivate Mode = "private"
	ModeOnline  Mode = "online"
	ModeLAN     Mode = "lan"
)

// Valid reports whether m is a mode the schema accepts.
func (m Mode) Valid() bool {
	switch m {
	case ModeBots, ModePrivate, ModeOnline, ModeLAN:
		return true
	}
	return false
}

// AllScopes is every statistics scope, in the order a profile screen should
// offer them. ScopeAll aggregates the rest.
var AllScopes = []string{ScopeAll, string(ModeOnline), string(ModePrivate), string(ModeBots), string(ModeLAN)}

// ScopeAll is the across-every-mode statistics row.
const ScopeAll = "all"

// Source records who computed a game's result. Games played on the server are
// authoritative; games uploaded by a device are not, because the device did the
// scoring. Both are fine for a personal history — only the former may ever feed
// anything public.
type Source string

const (
	SourceServer Source = "server"
	SourceClient Source = "client"
)

// GameRecord is one finished (or abandoned) game, with everything needed to
// render its scoreboard. It is the single unit written at the end of a game:
// the store inserts the game, its seats, its hands and its tricks, and updates
// every affected statistics row, in one transaction.
type GameRecord struct {
	Mode     Mode
	Source   Source
	RoomCode string
	// ClientGameID makes an upload idempotent. The client mints it when the
	// game starts, so a retry after a failed upload resolves to the same game
	// instead of a duplicate. Empty for server-played games.
	ClientGameID string
	HandsTotal   int
	// Completed is false for a game that ended without reaching a final
	// scoreboard. It still counts as played, but never as won.
	Completed  bool
	StartedAt  time.Time
	FinishedAt time.Time

	Seats  []SeatRecord
	Hands  []HandRecord
	Tricks []TrickRecord
}

// SeatRecord is one place at the table for one game. UserID is empty for a bot
// and for a human the server could not attribute to an account.
type SeatRecord struct {
	Seat          int
	UserID        string
	DisplayName   string
	IsBot         bool
	BotDifficulty string
	FinalScore    float64
	// Place is 1..4, or 0 for an abandoned game that never ranked anyone.
	Place       int
	TotalBid    int
	TotalTricks int
	// HandsMade counts hands where this seat took at least its bid.
	HandsMade int
}

// HandRecord is one seat's line on the scoreboard for one hand.
type HandRecord struct {
	HandIndex    int
	Seat         int
	Bid          int
	TricksWon    int
	ScoreDelta   float64
	RunningTotal float64
}

// TrickRecord is card-level detail, written only when trick recording is
// enabled. Plays is ordered from the lead.
type TrickRecord struct {
	HandIndex   int
	TrickNumber int
	LeadSeat    int
	WinnerSeat  int
	Plays       []TrickPlay
}

// TrickPlay is one card played into a trick.
type TrickPlay struct {
	Seat int    `json:"seat"`
	Card string `json:"card"`
}

// GameSummary is a history-list entry: one game as one player experienced it.
// Source rides along so the admin surface can tell server-scored games from
// device uploads; the per-player history queries never populate it.
type GameSummary struct {
	GameID     string
	Mode       Mode
	Source     Source
	RoomCode   string
	Completed  bool
	StartedAt  time.Time
	FinishedAt time.Time
	HandsTotal int
	// The requesting user's own outcome.
	Seat        int
	FinalScore  float64
	Place       int
	TotalBid    int
	TotalTricks int
	// Opponents, in seat order, including the requesting user.
	Players []GamePlayer
}

// GamePlayer is one participant as shown in a history row.
type GamePlayer struct {
	Seat        int
	UserID      string
	DisplayName string
	IsBot       bool
	FinalScore  float64
	Place       int
}

// GameDetail is a summary plus the full per-hand scoreboard.
type GameDetail struct {
	GameSummary
	Hands []HandRecord
}

// HistoryQuery filters a history request. Cursor is opaque to the caller and
// comes from the previous page's NextCursor.
type HistoryQuery struct {
	UserID string
	// Mode empty means every mode.
	Mode   Mode
	Limit  int
	Cursor string
}

// HistoryPage is one page of history. NextCursor is empty on the last page.
type HistoryPage struct {
	Games      []GameSummary
	NextCursor string
}

// -------------------------------------------------------------------- admin

// AdminGameQuery filters an admin history listing. Mode and Source empty mean
// "every game"; Cursor is the same keyset token History uses.
type AdminGameQuery struct {
	Mode   Mode
	Source Source
	Limit  int
	Cursor string
}

// AdminGamePage is one page of admin history.
type AdminGamePage struct {
	Games      []GameSummary
	NextCursor string
}

// -------------------------------------------------------------- statistics

// Stats is one (user, scope) counter row. Derived figures — win rate, average
// score, bid accuracy — are computed on read rather than stored, so the two
// numbers can never drift apart.
type Stats struct {
	Scope            string
	GamesPlayed      int
	GamesCompleted   int
	GamesWon         int
	GamesLost        int
	BestPlace        int
	HandsPlayed      int
	TotalBid         int
	BidsMade         int
	BidsFailed       int
	HighestBid       int
	TotalTricks      int
	TotalScore       float64
	HighestGameScore float64
	LowestGameScore  float64
	HighestHandScore float64
	CurrentWinStreak int
	BestWinStreak    int
	LastPlayedAt     time.Time
}

// ------------------------------------------------------------------ Store

// Store is everything the server persists. Implementations must be safe for
// concurrent use.
//
// The methods fall into three groups matching the three requirements: resolving
// and upgrading accounts, recording games, and reading a player's history and
// statistics back out.
type Store interface {
	// Enabled reports whether this store actually persists anything. A false
	// answer lets callers skip work entirely rather than round-trip to a Nop.
	Enabled() bool

	// ---- accounts ----

	// ResolveIdentity finds the user behind a provider identity, creating a
	// brand-new guest user when the identity has never been seen. displayName
	// is only used for a newly created user; an existing one keeps the name it
	// has. This is the whole of the guest login path.
	ResolveIdentity(ctx context.Context, provider Provider, subject, displayName string) (User, error)

	// UserByID looks up one account.
	UserByID(ctx context.Context, userID string) (User, error)

	// UpdateDisplayName changes the name shown to other players.
	UpdateDisplayName(ctx context.Context, userID, name string) (User, error)

	// TouchLastSeen records activity. Cheap and best-effort; callers may ignore
	// the error.
	TouchLastSeen(ctx context.Context, userID string) error

	// LinkIdentity attaches another sign-in method to an existing account and
	// clears its guest flag — the upgrade path. It returns ErrConflict when the
	// identity already belongs to a different user, which the caller resolves
	// by signing in as that user (and optionally merging, see MergeUsers)
	// rather than by stealing the identity.
	LinkIdentity(ctx context.Context, userID string, provider Provider, subject, email string) error

	// IdentitiesOf lists how an account can be signed into. Drives the profile
	// screen's account tab.
	IdentitiesOf(ctx context.Context, userID string) ([]Identity, error)

	// RestoreAccount moves the caller's device identity onto targetID — the
	// "bring my saved account to a new phone" path. Both sides must be guests:
	// currentID must still be a bare install (ErrNotGuest otherwise), and
	// targetID must be a restorable guest account (ErrNotFound otherwise, which
	// is also the answer when the account is unknown or has been merged away).
	// The replaced install is deleted outright when it has no games; when it
	// has games they are kept and named in the result so the caller can offer a
	// merge-or-discard decision.
	RestoreAccount(ctx context.Context, currentID, targetID string) (RestoreResult, error)

	// MergeGuest folds an abandoned guest account (one with no identities —
	// the residue of a restore) into userID: its games move, its statistics
	// are recomputed on the survivor, and it is marked merged. ErrNotFound when
	// there is nothing abandoned to merge, or when either side is an account
	// that can still be signed into.
	MergeGuest(ctx context.Context, userID, abandonedID string) (User, error)

	// DeleteAbandoned removes an abandoned guest account and its statistics —
	// the "discard that history" decision. Only a guest with no identities
	// qualifies; its game rows are not deleted, so a game that other humans
	// played in survives, with the absent device's seat simply unattributed.
	DeleteAbandoned(ctx context.Context, abandonedID string) error

	// MergeUsers moves every game, seat and statistic from src onto dst, marks
	// src as merged, and recomputes dst's statistics from its seats. Maxima and
	// streaks cannot be summed, which is why this recomputes rather than adds.
	// Never called without explicit user confirmation.
	MergeUsers(ctx context.Context, dst, src string) error

	// ---- recording ----

	// RecordGame writes a finished game and updates every affected statistics
	// row in one transaction. When rec.ClientGameID is set the write is
	// idempotent: a repeat returns the original game's id and changes nothing,
	// so a client retrying an upload cannot double-count itself.
	//
	// duplicate reports that the idempotency key matched and nothing was
	// written. Callers do not need it to be correct — a retry is safe either
	// way — but a client that keeps re-uploading the same game is a bug, and
	// this is what makes it visible instead of silent.
	RecordGame(ctx context.Context, rec GameRecord) (gameID string, duplicate bool, err error)

	// ---- reading ----

	// History returns one page of a player's games, newest first.
	History(ctx context.Context, q HistoryQuery) (HistoryPage, error)

	// Game returns one game with its per-hand scoreboard, from the point of
	// view of userID. It returns ErrNotFound when that user did not play in it,
	// so a game id is not a way to read someone else's results.
	Game(ctx context.Context, userID, gameID string) (GameDetail, error)

	// Stats returns every scope for a player, in AllScopes order, including
	// zeroed rows for scopes they have never played. A profile screen can
	// render the whole tab from one call.
	Stats(ctx context.Context, userID string) ([]Stats, error)

	// ---- admin ----

	// AdminGames lists every recorded game across all accounts, newest first,
	// for the operations dashboard. Unlike History it has no user filter; that
	// is what makes it admin-only.
	AdminGames(ctx context.Context, q AdminGameQuery) (AdminGamePage, error)

	// AdminGame returns one game with its scoreboard, without scoping to a
	// player — the admin detail view.
	AdminGame(ctx context.Context, gameID string) (GameDetail, error)

	// Close releases the connection pool.
	Close() error
}

// ---------------------------------------------------------------------- Nop

// Nop is the store used when no DATABASE_URL is set. Every method reports
// ErrDisabled, which callers translate into "skip it" rather than into a
// failure: the game must be playable with no database at all.
type Nop struct{}

var _ Store = Nop{}

func (Nop) Enabled() bool { return false }

func (Nop) ResolveIdentity(context.Context, Provider, string, string) (User, error) {
	return User{}, ErrDisabled
}
func (Nop) UserByID(context.Context, string) (User, error) { return User{}, ErrDisabled }
func (Nop) UpdateDisplayName(context.Context, string, string) (User, error) {
	return User{}, ErrDisabled
}
func (Nop) TouchLastSeen(context.Context, string) error { return ErrDisabled }
func (Nop) LinkIdentity(context.Context, string, Provider, string, string) error {
	return ErrDisabled
}
func (Nop) IdentitiesOf(context.Context, string) ([]Identity, error) { return nil, ErrDisabled }
func (Nop) RestoreAccount(context.Context, string, string) (RestoreResult, error) {
	return RestoreResult{}, ErrDisabled
}
func (Nop) MergeGuest(context.Context, string, string) (User, error) {
	return User{}, ErrDisabled
}
func (Nop) DeleteAbandoned(context.Context, string) error    { return ErrDisabled }
func (Nop) MergeUsers(context.Context, string, string) error { return ErrDisabled }
func (Nop) RecordGame(context.Context, GameRecord) (string, bool, error) {
	return "", false, ErrDisabled
}
func (Nop) History(context.Context, HistoryQuery) (HistoryPage, error) {
	return HistoryPage{}, ErrDisabled
}
func (Nop) Game(context.Context, string, string) (GameDetail, error) {
	return GameDetail{}, ErrDisabled
}
func (Nop) Stats(context.Context, string) ([]Stats, error) { return nil, ErrDisabled }
func (Nop) AdminGames(context.Context, AdminGameQuery) (AdminGamePage, error) {
	return AdminGamePage{}, ErrDisabled
}
func (Nop) AdminGame(context.Context, string) (GameDetail, error) {
	return GameDetail{}, ErrDisabled
}
func (Nop) Close() error { return nil }
