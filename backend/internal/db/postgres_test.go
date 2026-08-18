package db

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// These tests run against a real Postgres, because every interesting thing in
// this package is a property of the database rather than of the Go code: an
// upsert that has to be atomic, a partial unique index that has to make a retry
// a no-op, a keyset scan that has to not lose rows. A fake would only assert
// that the fake behaves the way the fake was written.
//
//	TEST_DATABASE_URL=postgres://... go test ./internal/db/...
//	make test-db                        # spins one up and tears it down
//
// With the variable unset they skip, so `make test` stays dependency-free —
// which is the same promise the server itself makes about persistence.

// testStore opens a store against a schema of its own.
//
// Every test gets a fresh schema rather than a fresh database: creating one is
// milliseconds, and it means the whole file can run in parallel against a
// single container without one test's users colliding with another's. The
// search_path is set on the pool so the migrations, and everything after them,
// land inside it.
func testStore(t *testing.T, opts Options) *Postgres {
	t.Helper()

	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL is not set; skipping the Postgres integration tests")
	}

	schema := fmt.Sprintf("test_%d_%d", os.Getpid(), atomic.AddInt64(&schemaSeq, 1))
	sep := "?"
	if strings.Contains(url, "?") {
		sep = "&"
	}

	ctx := context.Background()
	// A bare pool creates the schema — deliberately not OpenPostgres, which
	// would run the migrations into whatever schema the URL happens to point at
	// and leave a stray copy of the tables behind.
	boot, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatalf("connecting to TEST_DATABASE_URL: %v", err)
	}
	if _, err := boot.Exec(ctx, "CREATE SCHEMA "+schema); err != nil {
		boot.Close()
		t.Fatalf("creating schema %s: %v", schema, err)
	}
	boot.Close()

	// pgx passes unrecognised query parameters through as connection runtime
	// settings, so this puts every connection in the pool into the new schema.
	store, err := OpenPostgres(ctx, url+sep+"search_path="+schema, quietLogger(), opts)
	if err != nil {
		t.Fatalf("opening the store: %v", err)
	}
	p := store.(*Postgres)

	t.Cleanup(func() {
		if _, err := p.pool.Exec(context.Background(), "DROP SCHEMA "+schema+" CASCADE"); err != nil {
			t.Logf("dropping schema %s: %v", schema, err)
		}
		p.Close()
	})
	return p
}

// schemaSeq keeps parallel tests from picking the same schema name.
var schemaSeq int64

// quietLogger keeps expected failures (a deliberate conflict, a deliberate
// not-found) out of the test output, where they read as though something broke.
func quietLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

// ------------------------------------------------------------------ identity

func TestResolveIdentityIsStableForOneDevice(t *testing.T) {
	t.Parallel()
	p := testStore(t, Options{})
	ctx := context.Background()

	first, err := p.ResolveIdentity(ctx, ProviderDevice, "device-alpha", "Alpha")
	if err != nil {
		t.Fatalf("first resolve: %v", err)
	}
	if !first.IsGuest {
		t.Error("a device identity should create a guest")
	}
	if first.DisplayName != "Alpha" {
		t.Errorf("display name = %q, want Alpha", first.DisplayName)
	}

	// The second launch must find the same account, and must not rename it: the
	// name the player chose later belongs to them, not to the device.
	again, err := p.ResolveIdentity(ctx, ProviderDevice, "device-alpha", "Ignored")
	if err != nil {
		t.Fatalf("second resolve: %v", err)
	}
	if again.ID != first.ID {
		t.Fatalf("same device resolved to two users: %s then %s", first.ID, again.ID)
	}
	if again.DisplayName != "Alpha" {
		t.Errorf("a returning device renamed the account to %q", again.DisplayName)
	}

	other, err := p.ResolveIdentity(ctx, ProviderDevice, "device-beta", "Beta")
	if err != nil {
		t.Fatalf("resolving a second device: %v", err)
	}
	if other.ID == first.ID {
		t.Error("two different devices resolved to one user")
	}
}

// TestResolveIdentityConcurrent is the race the two-table design exists to
// survive: a phone that fires several requests at a cold account, or two
// devices restored from the same backup, must not end up as several users.
func TestResolveIdentityConcurrent(t *testing.T) {
	t.Parallel()
	p := testStore(t, Options{MaxConns: 8})
	ctx := context.Background()

	const racers = 12
	var (
		wg    sync.WaitGroup
		mu    sync.Mutex
		ids   = map[string]int{}
		fails []error
	)
	start := make(chan struct{})
	for range racers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			u, err := p.ResolveIdentity(ctx, ProviderDevice, "device-contended", "Racer")
			mu.Lock()
			defer mu.Unlock()
			if err != nil {
				fails = append(fails, err)
				return
			}
			ids[u.ID]++
		}()
	}
	close(start)
	wg.Wait()

	for _, err := range fails {
		t.Errorf("concurrent resolve failed: %v", err)
	}
	if len(ids) != 1 {
		t.Fatalf("%d concurrent resolutions produced %d distinct users: %v", racers, len(ids), ids)
	}

	// And exactly one users row exists, not one per loser of the race: the
	// losing statements must create no account at all, not an orphan.
	var users int
	if err := p.pool.QueryRow(ctx, `SELECT count(*) FROM users`).Scan(&users); err != nil {
		t.Fatalf("counting users: %v", err)
	}
	if users != 1 {
		t.Errorf("users table holds %d rows, want 1 — the race left orphans behind", users)
	}
}

func TestLinkIdentityUpgradesAGuest(t *testing.T) {
	t.Parallel()
	p := testStore(t, Options{})
	ctx := context.Background()

	guest, err := p.ResolveIdentity(ctx, ProviderDevice, "device-upgrade", "Guest")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if _, _, err := p.RecordGame(ctx, gameFor(guest.ID, ModeBots, 1, true, 40, 10)); err != nil {
		t.Fatalf("record: %v", err)
	}

	if err := p.LinkIdentity(ctx, guest.ID, ProviderGoogle, "google-uid-1", "a@example.com"); err != nil {
		t.Fatalf("link: %v", err)
	}

	upgraded, err := p.UserByID(ctx, guest.ID)
	if err != nil {
		t.Fatalf("reload: %v", err)
	}
	if upgraded.IsGuest {
		t.Error("linking a login left the account marked as a guest")
	}

	// Signing in with the same Google account on another phone is a lookup, and
	// the history has to be sitting there already.
	sameUser, err := p.ResolveIdentity(ctx, ProviderGoogle, "google-uid-1", "Whatever")
	if err != nil {
		t.Fatalf("resolve by google: %v", err)
	}
	if sameUser.ID != guest.ID {
		t.Fatalf("google identity resolved to %s, want %s", sameUser.ID, guest.ID)
	}
	page, err := p.History(ctx, HistoryQuery{UserID: guest.ID})
	if err != nil {
		t.Fatalf("history: %v", err)
	}
	if len(page.Games) != 1 {
		t.Errorf("history has %d games after the upgrade, want 1", len(page.Games))
	}

	ids, err := p.IdentitiesOf(ctx, guest.ID)
	if err != nil {
		t.Fatalf("identities: %v", err)
	}
	if len(ids) != 2 {
		t.Errorf("account has %d identities, want device + google", len(ids))
	}
}

func TestLinkIdentityRefusesToStealOne(t *testing.T) {
	t.Parallel()
	p := testStore(t, Options{})
	ctx := context.Background()

	owner, err := p.ResolveIdentity(ctx, ProviderDevice, "device-owner", "Owner")
	if err != nil {
		t.Fatalf("resolve owner: %v", err)
	}
	if err := p.LinkIdentity(ctx, owner.ID, ProviderGoogle, "google-shared", ""); err != nil {
		t.Fatalf("link to owner: %v", err)
	}

	thief, err := p.ResolveIdentity(ctx, ProviderDevice, "device-thief", "Thief")
	if err != nil {
		t.Fatalf("resolve thief: %v", err)
	}
	err = p.LinkIdentity(ctx, thief.ID, ProviderGoogle, "google-shared", "")
	if !errors.Is(err, ErrConflict) {
		t.Fatalf("linking someone else's identity returned %v, want ErrConflict", err)
	}

	// The refusal must leave both accounts exactly as they were.
	still, err := p.ResolveIdentity(ctx, ProviderGoogle, "google-shared", "")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if still.ID != owner.ID {
		t.Errorf("the identity moved to %s, want it to stay with %s", still.ID, owner.ID)
	}
	if reloaded, err := p.UserByID(ctx, thief.ID); err != nil {
		t.Fatalf("reload thief: %v", err)
	} else if !reloaded.IsGuest {
		t.Error("a failed link cleared the caller's guest flag anyway")
	}

	// Re-linking an identity the account already owns is a no-op, not a
	// conflict; a client retrying an interrupted upgrade must succeed.
	if err := p.LinkIdentity(ctx, owner.ID, ProviderGoogle, "google-shared", "b@example.com"); err != nil {
		t.Errorf("re-linking an owned identity: %v", err)
	}
}

func TestRestoreMovesTheDeviceIdentityToTheSavedAccount(t *testing.T) {
	t.Parallel()
	p := testStore(t, Options{})
	ctx := context.Background()

	// The account whose id the player saved lives on an old device; the fresh
	// install is a second guest account that will be abandoned.
	saved, err := p.ResolveIdentity(ctx, ProviderDevice, "device-old", "Veteran")
	if err != nil {
		t.Fatalf("resolve old device: %v", err)
	}
	if _, _, err := p.RecordGame(ctx, gameFor(saved.ID, ModeOnline, 1, true, 40, 10)); err != nil {
		t.Fatalf("record history: %v", err)
	}
	fresh, err := p.ResolveIdentity(ctx, ProviderDevice, "device-new", "Newbie")
	if err != nil {
		t.Fatalf("resolve new device: %v", err)
	}

	restored, err := p.RestoreAccount(ctx, fresh.ID, saved.ID)
	if err != nil {
		t.Fatalf("restore: %v", err)
	}
	if restored.User.ID != saved.ID {
		t.Fatalf("restored user = %s, want the saved account %s", restored.User.ID, saved.ID)
	}
	if restored.Abandoned != nil {
		t.Errorf("restore of an empty install reported an abandoned account: %+v", restored.Abandoned)
	}

	// The new install's device id now resolves to the saved account, and the
	// abandoned guest no longer has any identity pointing at it.
	nextLaunch, err := p.ResolveIdentity(ctx, ProviderDevice, "device-new", "Ignored")
	if err != nil {
		t.Fatalf("resolve after restore: %v", err)
	}
	if nextLaunch.ID != saved.ID {
		t.Fatalf("restored device resolved to %s, want %s", nextLaunch.ID, saved.ID)
	}
	if ids, err := p.IdentitiesOf(ctx, fresh.ID); err != nil {
		t.Fatalf("identities of abandoned guest: %v", err)
	} else if len(ids) != 0 {
		t.Errorf("abandoned guest still has %d identities, want 0", len(ids))
	}

	// The saved account's history is intact and reachable.
	page, err := p.History(ctx, HistoryQuery{UserID: saved.ID})
	if err != nil {
		t.Fatalf("history: %v", err)
	}
	if len(page.Games) != 1 {
		t.Errorf("history has %d games after the restore, want 1", len(page.Games))
	}

	// Re-requesting the account this device now owns is a no-op, not an error.
	same, err := p.RestoreAccount(ctx, saved.ID, saved.ID)
	if err != nil {
		t.Fatalf("restoring the current account: %v", err)
	}
	if same.User.ID != saved.ID {
		t.Errorf("no-op restore returned %s, want %s", same.User.ID, saved.ID)
	}
}

func TestRestoreRefusesNonGuests(t *testing.T) {
	t.Parallel()
	p := testStore(t, Options{})
	ctx := context.Background()

	// A signed-in account reached by a Google identity must not be restorable
	// by an id someone learned off a scoreboard — ErrNotFound, not a hint that
	// it exists. And a signed-in device must not be able to absorb one.
	linked, err := p.ResolveIdentity(ctx, ProviderDevice, "device-linked", "Linked")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if err := p.LinkIdentity(ctx, linked.ID, ProviderGoogle, "google-restore-1", ""); err != nil {
		t.Fatalf("link: %v", err)
	}
	guest, err := p.ResolveIdentity(ctx, ProviderDevice, "device-guest-restore", "Guest")
	if err != nil {
		t.Fatalf("resolve guest: %v", err)
	}

	if _, err := p.RestoreAccount(ctx, guest.ID, linked.ID); !errors.Is(err, ErrNotFound) {
		t.Errorf("restore into a linked account returned %v, want ErrNotFound", err)
	}
	if _, err := p.RestoreAccount(ctx, linked.ID, guest.ID); !errors.Is(err, ErrNotGuest) {
		t.Errorf("restore from a linked account returned %v, want ErrNotGuest", err)
	}
	if _, err := p.RestoreAccount(ctx, guest.ID, "00000000-0000-0000-0000-000000000000"); !errors.Is(err, ErrNotFound) {
		t.Errorf("restore to an unknown account returned %v, want ErrNotFound", err)
	}
}

func TestRestoreWithHistoryLeavesAnAbandonedAccount(t *testing.T) {
	t.Parallel()
	p := testStore(t, Options{})
	ctx := context.Background()

	// The saved account has history; so does the fresh install that is about
	// to be abandoned by the restore.
	saved, err := p.ResolveIdentity(ctx, ProviderDevice, "device-old-merge", "Veteran")
	if err != nil {
		t.Fatalf("resolve old device: %v", err)
	}
	for _, top := range []int{40, 60} {
		if _, _, err := p.RecordGame(ctx, gameFor(saved.ID, ModeBots, 1, true, 100, top)); err != nil {
			t.Fatalf("record saved history: %v", err)
		}
	}
	fresh, err := p.ResolveIdentity(ctx, ProviderDevice, "device-new-merge", "Newbie")
	if err != nil {
		t.Fatalf("resolve new device: %v", err)
	}
	if _, _, err := p.RecordGame(ctx, gameFor(fresh.ID, ModeBots, 1, true, 50, 20)); err != nil {
		t.Fatalf("record fresh history: %v", err)
	}

	result, err := p.RestoreAccount(ctx, fresh.ID, saved.ID)
	if err != nil {
		t.Fatalf("restore: %v", err)
	}
	if result.User.ID != saved.ID {
		t.Fatalf("restored user = %s, want %s", result.User.ID, saved.ID)
	}
	if result.Abandoned == nil {
		t.Fatal("restore of an install with games reported no abandoned account")
	}
	if result.Abandoned.ID != fresh.ID || result.Abandoned.Games != 1 {
		t.Errorf("abandoned = %+v, want id %s with 1 game", result.Abandoned, fresh.ID)
	}

	// Until the decision, the survivor's history is unchanged.
	page, err := p.History(ctx, HistoryQuery{UserID: saved.ID})
	if err != nil {
		t.Fatalf("history before merge: %v", err)
	}
	if len(page.Games) != 2 {
		t.Fatalf("survivor history has %d games before the merge, want 2", len(page.Games))
	}

	// Merging folds the abandoned install's game onto the survivor.
	if _, err := p.MergeGuest(ctx, saved.ID, fresh.ID); err != nil {
		t.Fatalf("merge: %v", err)
	}
	page, err = p.History(ctx, HistoryQuery{UserID: saved.ID})
	if err != nil {
		t.Fatalf("history after merge: %v", err)
	}
	if len(page.Games) != 3 {
		t.Errorf("survivor history has %d games after the merge, want 3", len(page.Games))
	}

	// The abandoned guest is now a tombstone: not re-mergeable, not deletable,
	// not signable-into.
	if _, err := p.MergeGuest(ctx, saved.ID, fresh.ID); !errors.Is(err, ErrNotFound) {
		t.Errorf("re-merge returned %v, want ErrNotFound", err)
	}
	if err := p.DeleteAbandoned(ctx, fresh.ID); !errors.Is(err, ErrNotFound) {
		t.Errorf("delete after merge returned %v, want ErrNotFound", err)
	}
	ghost, err := p.UserByID(ctx, fresh.ID)
	if err != nil {
		t.Fatalf("read merged account: %v", err)
	}
	if ghost.MergedInto != saved.ID || ghost.IsGuest {
		t.Errorf("merged account = %+v, want a non-guest tombstone naming %s", ghost, saved.ID)
	}
}

func TestDeleteAbandonedDiscardsHistoryButNotGames(t *testing.T) {
	t.Parallel()
	p := testStore(t, Options{})
	ctx := context.Background()

	saved, err := p.ResolveIdentity(ctx, ProviderDevice, "device-old-discard", "Veteran")
	if err != nil {
		t.Fatalf("resolve old device: %v", err)
	}
	if _, _, err := p.RecordGame(ctx, gameFor(saved.ID, ModeOnline, 1, true, 40, 10)); err != nil {
		t.Fatalf("record saved history: %v", err)
	}
	fresh, err := p.ResolveIdentity(ctx, ProviderDevice, "device-new-discard", "Newbie")
	if err != nil {
		t.Fatalf("resolve new device: %v", err)
	}
	if _, _, err := p.RecordGame(ctx, gameFor(fresh.ID, ModeOnline, 1, true, 30, 8)); err != nil {
		t.Fatalf("record fresh history: %v", err)
	}

	if _, err := p.RestoreAccount(ctx, fresh.ID, saved.ID); err != nil {
		t.Fatalf("restore: %v", err)
	}

	if err := p.DeleteAbandoned(ctx, fresh.ID); err != nil {
		t.Fatalf("delete abandoned: %v", err)
	}
	if _, err := p.UserByID(ctx, fresh.ID); !errors.Is(err, ErrNotFound) {
		t.Errorf("discarded account still readable: %v", err)
	}

	// The game the other human played in survives, even though the account
	// that reported it is gone; the survivor's history is intact.
	page, err := p.History(ctx, HistoryQuery{UserID: saved.ID})
	if err != nil {
		t.Fatalf("history: %v", err)
	}
	if len(page.Games) != 1 {
		t.Errorf("survivor history has %d games, want 1", len(page.Games))
	}
}

func TestMergeAndDeleteRefuseLiveAccounts(t *testing.T) {
	t.Parallel()
	p := testStore(t, Options{})
	ctx := context.Background()

	a, err := p.ResolveIdentity(ctx, ProviderDevice, "device-live-a", "A")
	if err != nil {
		t.Fatalf("resolve a: %v", err)
	}
	b, err := p.ResolveIdentity(ctx, ProviderDevice, "device-live-b", "B")
	if err != nil {
		t.Fatalf("resolve b: %v", err)
	}

	// Neither side of a merge may be an account that can still be signed into.
	if _, err := p.MergeGuest(ctx, a.ID, b.ID); !errors.Is(err, ErrNotFound) {
		t.Errorf("merging a live guest returned %v, want ErrNotFound", err)
	}
	if err := p.DeleteAbandoned(ctx, b.ID); !errors.Is(err, ErrNotFound) {
		t.Errorf("deleting a live guest returned %v, want ErrNotFound", err)
	}
	if _, err := p.MergeGuest(ctx, a.ID, "00000000-0000-0000-0000-000000000000"); !errors.Is(err, ErrNotFound) {
		t.Errorf("merging into an unknown survivor returned %v, want ErrNotFound", err)
	}
	if err := p.DeleteAbandoned(ctx, "00000000-0000-0000-0000-000000000000"); !errors.Is(err, ErrNotFound) {
		t.Errorf("deleting an unknown account returned %v, want ErrNotFound", err)
	}
	if _, err := p.MergeGuest(ctx, a.ID, a.ID); !errors.Is(err, ErrNotFound) {
		t.Errorf("merging an account into itself returned %v, want ErrNotFound", err)
	}
}

// ------------------------------------------------------------------ recording

// TestRecordGameIsIdempotent is the most important test in this file. An
// offline game is uploaded from a phone over a connection that may drop after
// the server has committed but before the client has heard so, and the client
// will try again. That retry has to be a complete no-op: same game id, and
// above all the statistics counted exactly once.
func TestRecordGameIsIdempotent(t *testing.T) {
	t.Parallel()
	p := testStore(t, Options{})
	ctx := context.Background()

	user, err := p.ResolveIdentity(ctx, ProviderDevice, "device-retry", "Retrier")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}

	rec := gameFor(user.ID, ModeBots, 1, true, 42.5, 12)
	rec.ClientGameID = "11111111-2222-3333-4444-555555555555"

	first, dup, err := p.RecordGame(ctx, rec)
	if err != nil {
		t.Fatalf("first upload: %v", err)
	}
	if dup {
		t.Error("the first upload reported itself a duplicate")
	}
	second, dup, err := p.RecordGame(ctx, rec)
	if err != nil {
		t.Fatalf("retried upload: %v", err)
	}
	if first != second {
		t.Fatalf("a retry created a second game: %s then %s", first, second)
	}
	if !dup {
		t.Error("a retry did not report itself a duplicate; a client " +
			"re-uploading forever would be invisible")
	}

	// Third time, with a payload that differs in everything except the
	// idempotency key — a client that recomputed its own scores must not be
	// able to rewrite a game the server already has.
	tampered := gameFor(user.ID, ModeOnline, 4, true, 999, 40)
	tampered.ClientGameID = rec.ClientGameID
	third, dup, err := p.RecordGame(ctx, tampered)
	if err != nil {
		t.Fatalf("third upload: %v", err)
	}
	if third != first {
		t.Fatalf("a differing payload under the same key created game %s", third)
	}
	if !dup {
		t.Error("a tampered replay under an existing key did not report a duplicate")
	}

	var games int
	if err := p.pool.QueryRow(ctx, `SELECT count(*) FROM games`).Scan(&games); err != nil {
		t.Fatalf("counting games: %v", err)
	}
	if games != 1 {
		t.Errorf("games table holds %d rows after three uploads, want 1", games)
	}

	stats := statsByScope(t, p, user.ID)
	for _, scope := range []string{ScopeAll, string(ModeBots)} {
		s := stats[scope]
		if s.GamesPlayed != 1 {
			t.Errorf("%s: games_played = %d after three uploads, want 1", scope, s.GamesPlayed)
		}
		if s.GamesWon != 1 {
			t.Errorf("%s: games_won = %d, want 1", scope, s.GamesWon)
		}
		if s.TotalScore != 42.5 {
			t.Errorf("%s: total_score = %v, want 42.5 counted once", scope, s.TotalScore)
		}
		if s.CurrentWinStreak != 1 {
			t.Errorf("%s: current_win_streak = %d, want 1", scope, s.CurrentWinStreak)
		}
	}
	// Nothing downstream was written twice either.
	var seats, hands int
	if err := p.pool.QueryRow(ctx, `SELECT count(*) FROM game_seats`).Scan(&seats); err != nil {
		t.Fatalf("counting seats: %v", err)
	}
	if err := p.pool.QueryRow(ctx, `SELECT count(*) FROM game_hands`).Scan(&hands); err != nil {
		t.Fatalf("counting hands: %v", err)
	}
	if seats != 4 {
		t.Errorf("game_seats holds %d rows, want 4", seats)
	}
	if hands != len(rec.Hands) {
		t.Errorf("game_hands holds %d rows, want %d", hands, len(rec.Hands))
	}
}

func TestRecordGameWithoutClientIDAlwaysInserts(t *testing.T) {
	t.Parallel()
	p := testStore(t, Options{})
	ctx := context.Background()

	user, err := p.ResolveIdentity(ctx, ProviderDevice, "device-server", "Server")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	// Server-played games carry no idempotency key, because the room actor
	// writes each one exactly once and two real games can be identical.
	a, _, err := p.RecordGame(ctx, gameFor(user.ID, ModeOnline, 1, true, 30, 10))
	if err != nil {
		t.Fatalf("first: %v", err)
	}
	b, _, err := p.RecordGame(ctx, gameFor(user.ID, ModeOnline, 1, true, 30, 10))
	if err != nil {
		t.Fatalf("second: %v", err)
	}
	if a == b {
		t.Fatal("two distinct server games collapsed into one row")
	}
	if s := statsByScope(t, p, user.ID)[ScopeAll]; s.GamesPlayed != 2 {
		t.Errorf("games_played = %d, want 2", s.GamesPlayed)
	}
}

func TestRecordGameStoresTricksOnlyWhenAsked(t *testing.T) {
	t.Parallel()
	ctx := context.Background()

	for _, on := range []bool{false, true} {
		t.Run(fmt.Sprintf("record_tricks=%v", on), func(t *testing.T) {
			p := testStore(t, Options{RecordTricks: on})
			user, err := p.ResolveIdentity(ctx, ProviderDevice, "device-tricks", "T")
			if err != nil {
				t.Fatalf("resolve: %v", err)
			}
			rec := gameFor(user.ID, ModeBots, 1, true, 20, 8)
			rec.Tricks = []TrickRecord{{
				HandIndex: 0, TrickNumber: 0, LeadSeat: 0, WinnerSeat: 1,
				Plays: []TrickPlay{{Seat: 0, Card: "AS"}, {Seat: 1, Card: "2S"}},
			}}
			if _, _, err := p.RecordGame(ctx, rec); err != nil {
				t.Fatalf("record: %v", err)
			}

			var tricks int
			if err := p.pool.QueryRow(ctx, `SELECT count(*) FROM game_tricks`).Scan(&tricks); err != nil {
				t.Fatalf("counting tricks: %v", err)
			}
			want := 0
			if on {
				want = 1
			}
			if tricks != want {
				t.Errorf("game_tricks holds %d rows, want %d", tricks, want)
			}
		})
	}
}

// TestAbandonedGameCountsAsPlayedNotWon pins §2.3: a rage-quit is still a game
// you started, and it must not touch a record or a streak.
func TestAbandonedGameCountsAsPlayedNotWon(t *testing.T) {
	t.Parallel()
	p := testStore(t, Options{})
	ctx := context.Background()

	user, err := p.ResolveIdentity(ctx, ProviderDevice, "device-quit", "Quitter")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if _, _, err := p.RecordGame(ctx, gameFor(user.ID, ModeOnline, 1, true, 50, 12)); err != nil {
		t.Fatalf("won game: %v", err)
	}

	abandoned := gameFor(user.ID, ModeOnline, 0, false, 7, 3)
	abandoned.Completed = false
	if _, _, err := p.RecordGame(ctx, abandoned); err != nil {
		t.Fatalf("abandoned game: %v", err)
	}

	s := statsByScope(t, p, user.ID)[ScopeAll]
	if s.GamesPlayed != 2 {
		t.Errorf("games_played = %d, want 2 — an abandoned game still counts as played", s.GamesPlayed)
	}
	if s.GamesCompleted != 1 {
		t.Errorf("games_completed = %d, want 1", s.GamesCompleted)
	}
	if s.GamesWon != 1 {
		t.Errorf("games_won = %d, want 1 — an abandoned game is not a win", s.GamesWon)
	}
	if s.GamesLost != 0 {
		t.Errorf("games_lost = %d, want 0 — an abandoned game is not a loss either", s.GamesLost)
	}
	if s.CurrentWinStreak != 1 {
		t.Errorf("current_win_streak = %d, want 1 — losing the wifi must not end a streak", s.CurrentWinStreak)
	}
	if s.HighestGameScore != 50 {
		t.Errorf("highest_game_score = %v, want 50 — an unfinished table set no record", s.HighestGameScore)
	}
	// It does still appear in history: "games I started" has to be answerable.
	page, err := p.History(ctx, HistoryQuery{UserID: user.ID})
	if err != nil {
		t.Fatalf("history: %v", err)
	}
	if len(page.Games) != 2 {
		t.Errorf("history has %d games, want 2", len(page.Games))
	}
}

// ---------------------------------------------------------------- statistics

func TestStatsMaximaAndStreaks(t *testing.T) {
	t.Parallel()
	p := testStore(t, Options{})
	ctx := context.Background()

	user, err := p.ResolveIdentity(ctx, ProviderDevice, "device-stats", "Statto")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}

	// online: win, win, loss, win  -> best streak 2, current streak 1
	// bots:   win                  -> best streak 1, current streak 1
	// The `all` scope sees all five in finish order, so its best streak is 3:
	// two online wins followed by the bots win, before the online loss.
	type play struct {
		mode   Mode
		place  int
		score  float64
		topBid int
	}
	plays := []play{
		{ModeOnline, 1, 31.4, 5},
		{ModeOnline, 1, 28.2, 7},
		{ModeBots, 1, 55.0, 9},
		{ModeOnline, 3, -4.5, 4},
		{ModeOnline, 1, 40.1, 6},
	}
	base := time.Now().Add(-time.Hour).Truncate(time.Millisecond)
	for i, pl := range plays {
		rec := gameFor(user.ID, pl.mode, pl.place, true, pl.score, pl.topBid)
		rec.StartedAt = base.Add(time.Duration(i) * time.Minute)
		rec.FinishedAt = rec.StartedAt.Add(30 * time.Second)
		if _, _, err := p.RecordGame(ctx, rec); err != nil {
			t.Fatalf("game %d: %v", i, err)
		}
	}

	all := statsByScope(t, p, user.ID)
	checks := []struct {
		scope string
		want  Stats
	}{
		{ScopeAll, Stats{
			GamesPlayed: 5, GamesCompleted: 5, GamesWon: 4, GamesLost: 1, BestPlace: 1,
			HighestBid: 9, HighestGameScore: 55.0, LowestGameScore: -4.5,
			CurrentWinStreak: 1, BestWinStreak: 3,
		}},
		{string(ModeOnline), Stats{
			GamesPlayed: 4, GamesCompleted: 4, GamesWon: 3, GamesLost: 1, BestPlace: 1,
			HighestBid: 7, HighestGameScore: 40.1, LowestGameScore: -4.5,
			CurrentWinStreak: 1, BestWinStreak: 2,
		}},
		{string(ModeBots), Stats{
			GamesPlayed: 1, GamesCompleted: 1, GamesWon: 1, GamesLost: 0, BestPlace: 1,
			HighestBid: 9, HighestGameScore: 55.0, LowestGameScore: 55.0,
			CurrentWinStreak: 1, BestWinStreak: 1,
		}},
	}
	for _, c := range checks {
		got, want := all[c.scope], c.want
		if got.GamesPlayed != want.GamesPlayed || got.GamesCompleted != want.GamesCompleted ||
			got.GamesWon != want.GamesWon || got.GamesLost != want.GamesLost ||
			got.BestPlace != want.BestPlace || got.HighestBid != want.HighestBid ||
			got.HighestGameScore != want.HighestGameScore || got.LowestGameScore != want.LowestGameScore ||
			got.CurrentWinStreak != want.CurrentWinStreak || got.BestWinStreak != want.BestWinStreak {
			t.Errorf("scope %s:\n got %+v\nwant %+v", c.scope, got, want)
		}
	}

	// Scopes never played come back zeroed rather than missing, so a profile
	// screen can render all five without a nil check.
	list, err := p.Stats(ctx, user.ID)
	if err != nil {
		t.Fatalf("stats: %v", err)
	}
	if len(list) != len(AllScopes) {
		t.Fatalf("Stats returned %d scopes, want %d", len(list), len(AllScopes))
	}
	for i, s := range list {
		if s.Scope != AllScopes[i] {
			t.Errorf("scope %d is %q, want %q — AllScopes order is part of the contract", i, s.Scope, AllScopes[i])
		}
	}
	if lan := all[string(ModeLAN)]; lan.GamesPlayed != 0 || lan.Scope != string(ModeLAN) {
		t.Errorf("unplayed scope came back as %+v, want a zeroed lan row", lan)
	}

	// highest_hand_score comes off the scoreboard, not the game total.
	if all[ScopeAll].HighestHandScore <= 0 {
		t.Errorf("highest_hand_score = %v, want the best single hand", all[ScopeAll].HighestHandScore)
	}
}

// TestRecomputeStatsMatchesTheIncrementalPath guards the invariant MergeUsers
// depends on: the counters maintained game by game and the counters rebuilt
// from scratch must agree. If they ever diverge, a merge would silently rewrite
// a player's history.
func TestRecomputeStatsMatchesTheIncrementalPath(t *testing.T) {
	t.Parallel()
	p := testStore(t, Options{})
	ctx := context.Background()

	user, err := p.ResolveIdentity(ctx, ProviderDevice, "device-recompute", "R")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	base := time.Now().Add(-time.Hour).Truncate(time.Millisecond)
	for i, place := range []int{1, 2, 1, 1, 4, 1} {
		rec := gameFor(user.ID, ModeOnline, place, true, float64(20+i), 3+i)
		if i == 4 {
			rec.Mode = ModeBots
		}
		rec.StartedAt = base.Add(time.Duration(i) * time.Minute)
		rec.FinishedAt = rec.StartedAt.Add(time.Minute)
		if _, _, err := p.RecordGame(ctx, rec); err != nil {
			t.Fatalf("game %d: %v", i, err)
		}
	}

	incremental := statsByScope(t, p, user.ID)
	if err := p.inTx(ctx, "test recompute", func(tx pgx.Tx) error {
		return p.recomputeStats(ctx, tx, user.ID)
	}); err != nil {
		t.Fatalf("recompute: %v", err)
	}
	rebuilt := statsByScope(t, p, user.ID)

	for _, scope := range AllScopes {
		a, b := incremental[scope], rebuilt[scope]
		a.LastPlayedAt, b.LastPlayedAt = time.Time{}, time.Time{}
		if a != b {
			t.Errorf("scope %s diverged:\nincremental %+v\n  recompute %+v", scope, a, b)
		}
	}
}

func TestMergeUsers(t *testing.T) {
	t.Parallel()
	p := testStore(t, Options{})
	ctx := context.Background()

	guest, err := p.ResolveIdentity(ctx, ProviderDevice, "device-merge-src", "Guest")
	if err != nil {
		t.Fatalf("resolve guest: %v", err)
	}
	account, err := p.ResolveIdentity(ctx, ProviderDevice, "device-merge-dst", "Account")
	if err != nil {
		t.Fatalf("resolve account: %v", err)
	}

	base := time.Now().Add(-time.Hour).Truncate(time.Millisecond)
	for i, owner := range []string{guest.ID, account.ID, guest.ID} {
		rec := gameFor(owner, ModeBots, 1, true, float64(10*(i+1)), 4+i)
		rec.StartedAt = base.Add(time.Duration(i) * time.Minute)
		rec.FinishedAt = rec.StartedAt.Add(time.Minute)
		if _, _, err := p.RecordGame(ctx, rec); err != nil {
			t.Fatalf("game %d: %v", i, err)
		}
	}

	if err := p.MergeUsers(ctx, account.ID, guest.ID); err != nil {
		t.Fatalf("merge: %v", err)
	}

	// The survivor now owns everything, with the streak recomputed across the
	// combined history rather than added together.
	s := statsByScope(t, p, account.ID)[ScopeAll]
	if s.GamesPlayed != 3 {
		t.Errorf("games_played = %d after the merge, want 3", s.GamesPlayed)
	}
	if s.BestWinStreak != 3 {
		t.Errorf("best_win_streak = %d, want 3 — three consecutive wins, not two streaks added", s.BestWinStreak)
	}
	if s.HighestGameScore != 30 {
		t.Errorf("highest_game_score = %v, want 30", s.HighestGameScore)
	}

	// The absorbed row survives with merged_into set, and its device still
	// signs in — at the survivor.
	resolved, err := p.ResolveIdentity(ctx, ProviderDevice, "device-merge-src", "Guest")
	if err != nil {
		t.Fatalf("resolve merged device: %v", err)
	}
	if resolved.ID != account.ID {
		t.Errorf("the merged guest's device resolved to %s, want %s", resolved.ID, account.ID)
	}
	if src, err := p.UserByID(ctx, guest.ID); err != nil {
		t.Fatalf("reload guest: %v", err)
	} else if src.MergedInto != account.ID {
		t.Errorf("merged_into = %q, want %s", src.MergedInto, account.ID)
	}

	var srcStats int
	if err := p.pool.QueryRow(ctx, `SELECT count(*) FROM user_stats WHERE user_id = $1`, guest.ID).Scan(&srcStats); err != nil {
		t.Fatalf("counting stats: %v", err)
	}
	if srcStats != 0 {
		t.Errorf("the absorbed account kept %d stat rows", srcStats)
	}
}

// ------------------------------------------------------------------- reading

// TestHistoryPagination walks every page and asserts the set of games seen is
// exactly the set recorded — no duplicates, no gaps. That is the whole reason
// the cursor is a keyset rather than an offset.
func TestHistoryPagination(t *testing.T) {
	t.Parallel()
	p := testStore(t, Options{})
	ctx := context.Background()

	user, err := p.ResolveIdentity(ctx, ProviderDevice, "device-pages", "Pager")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}

	const total = 17
	want := map[string]bool{}
	base := time.Now().Add(-24 * time.Hour).Truncate(time.Millisecond)
	for i := range total {
		rec := gameFor(user.ID, ModeOnline, 1+i%4, true, float64(i), 5)
		if i%3 == 0 {
			rec.Mode = ModeBots
		}
		// Deliberately give several games the identical finish time. A cursor
		// on the timestamp alone would either skip or repeat them; the game id
		// in the tuple is what stops that.
		rec.FinishedAt = base.Add(time.Duration(i/4) * time.Minute)
		rec.StartedAt = rec.FinishedAt.Add(-10 * time.Minute)
		id, _, err := p.RecordGame(ctx, rec)
		if err != nil {
			t.Fatalf("game %d: %v", i, err)
		}
		want[id] = true
	}

	seen := map[string]int{}
	var pages int
	var last time.Time
	cursor := ""
	for {
		page, err := p.History(ctx, HistoryQuery{UserID: user.ID, Limit: 5, Cursor: cursor})
		if err != nil {
			t.Fatalf("page %d: %v", pages, err)
		}
		pages++
		for _, g := range page.Games {
			seen[g.GameID]++
			if !last.IsZero() && g.FinishedAt.After(last) {
				t.Errorf("game %s came back out of order", g.GameID)
			}
			last = g.FinishedAt
			if len(g.Players) != 4 {
				t.Errorf("game %s came back with %d players, want 4", g.GameID, len(g.Players))
			}
		}
		if page.NextCursor == "" {
			break
		}
		cursor = page.NextCursor
		if pages > total {
			t.Fatal("pagination did not terminate")
		}
	}

	if len(seen) != total {
		t.Errorf("saw %d distinct games across %d pages, want %d", len(seen), pages, total)
	}
	for id, n := range seen {
		if n != 1 {
			t.Errorf("game %s appeared %d times", id, n)
		}
		if !want[id] {
			t.Errorf("game %s was never recorded", id)
		}
	}

	// The mode filter has to page the same way, over its own subset.
	botsOnly := 0
	cursor = ""
	for {
		page, err := p.History(ctx, HistoryQuery{UserID: user.ID, Mode: ModeBots, Limit: 2, Cursor: cursor})
		if err != nil {
			t.Fatalf("filtered page: %v", err)
		}
		for _, g := range page.Games {
			if g.Mode != ModeBots {
				t.Errorf("mode filter returned a %s game", g.Mode)
			}
			botsOnly++
		}
		if page.NextCursor == "" {
			break
		}
		cursor = page.NextCursor
	}
	if botsOnly != (total+2)/3 {
		t.Errorf("mode=bots returned %d games, want %d", botsOnly, (total+2)/3)
	}
}

func TestHistoryRejectsAGarbageCursor(t *testing.T) {
	t.Parallel()
	p := testStore(t, Options{})
	ctx := context.Background()

	user, err := p.ResolveIdentity(ctx, ProviderDevice, "device-cursor", "C")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	_, err = p.History(ctx, HistoryQuery{UserID: user.ID, Cursor: "not-base64-!!"})
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("garbage cursor returned %v, want ErrNotFound", err)
	}
}

// TestGameIsScopedToItsPlayers: a game id is not a capability. Someone who did
// not sit at the table gets a not-found, and is told nothing about whether the
// game exists.
func TestGameIsScopedToItsPlayers(t *testing.T) {
	t.Parallel()
	p := testStore(t, Options{})
	ctx := context.Background()

	player, err := p.ResolveIdentity(ctx, ProviderDevice, "device-player", "Player")
	if err != nil {
		t.Fatalf("resolve player: %v", err)
	}
	stranger, err := p.ResolveIdentity(ctx, ProviderDevice, "device-stranger", "Stranger")
	if err != nil {
		t.Fatalf("resolve stranger: %v", err)
	}

	gameID, _, err := p.RecordGame(ctx, gameFor(player.ID, ModePrivate, 2, true, 25.5, 6))
	if err != nil {
		t.Fatalf("record: %v", err)
	}

	detail, err := p.Game(ctx, player.ID, gameID)
	if err != nil {
		t.Fatalf("owner reading their own game: %v", err)
	}
	if detail.Place != 2 || detail.FinalScore != 25.5 {
		t.Errorf("detail = place %d score %v, want place 2 score 25.5", detail.Place, detail.FinalScore)
	}
	if len(detail.Players) != 4 {
		t.Errorf("detail has %d players, want 4", len(detail.Players))
	}
	if len(detail.Hands) == 0 {
		t.Error("detail came back with no scoreboard")
	}

	if _, err := p.Game(ctx, stranger.ID, gameID); !errors.Is(err, ErrNotFound) {
		t.Errorf("a stranger read the game and got %v, want ErrNotFound", err)
	}
	if _, err := p.Game(ctx, player.ID, "00000000-0000-0000-0000-000000000000"); !errors.Is(err, ErrNotFound) {
		t.Errorf("a missing game returned %v, want ErrNotFound", err)
	}
	if _, err := p.Game(ctx, player.ID, "not-a-uuid"); !errors.Is(err, ErrNotFound) {
		t.Errorf("a malformed id returned %v, want ErrNotFound", err)
	}
}

func TestUnknownUserLooksLikeNotFound(t *testing.T) {
	t.Parallel()
	p := testStore(t, Options{})
	ctx := context.Background()

	if _, err := p.UserByID(ctx, "00000000-0000-0000-0000-000000000000"); !errors.Is(err, ErrNotFound) {
		t.Errorf("UserByID returned %v, want ErrNotFound", err)
	}
	if _, err := p.UserByID(ctx, "nonsense"); !errors.Is(err, ErrNotFound) {
		t.Errorf("UserByID with a malformed id returned %v, want ErrNotFound", err)
	}
}

func TestMigrationsAreIdempotent(t *testing.T) {
	t.Parallel()
	p := testStore(t, Options{})
	ctx := context.Background()

	// testStore already ran them once. Running them again must apply nothing,
	// which is what makes a rolling restart safe.
	before := migrationCount(t, p)
	if err := migrate(ctx, p.pool, quietLogger()); err != nil {
		t.Fatalf("second migrate: %v", err)
	}
	if after := migrationCount(t, p); after != before {
		t.Errorf("a second run applied %d extra migrations", after-before)
	}
	if before == 0 {
		t.Error("no migrations were recorded at all")
	}
}

func migrationCount(t *testing.T, p *Postgres) int {
	t.Helper()
	var n int
	if err := p.pool.QueryRow(context.Background(), `SELECT count(*) FROM schema_migrations`).Scan(&n); err != nil {
		t.Fatalf("counting migrations: %v", err)
	}
	return n
}

// --------------------------------------------------------------------- fixtures

// gameFor builds a plausible five-hand game in which userID sits at seat 0 and
// finishes in the given place, with three bots for company. topBid is the
// highest bid that seat made, so a test can steer highest_bid without caring
// about the rest of the scoreboard.
func gameFor(userID string, mode Mode, place int, completed bool, finalScore float64, topBid int) GameRecord {
	now := time.Now().Truncate(time.Millisecond)
	source := SourceServer
	if mode == ModeBots || mode == ModeLAN {
		source = SourceClient
	}

	rec := GameRecord{
		Mode:       mode,
		Source:     source,
		RoomCode:   "TESTRM",
		HandsTotal: 5,
		Completed:  completed,
		StartedAt:  now.Add(-20 * time.Minute),
		FinishedAt: now,
	}

	for seat := range 4 {
		s := SeatRecord{
			Seat:        seat,
			DisplayName: fmt.Sprintf("Bot %d", seat),
			IsBot:       true,
			TotalBid:    10,
			TotalTricks: 13,
			HandsMade:   3,
			Place:       place,
		}
		if seat == 0 {
			s.UserID = userID
			s.DisplayName = "Me"
			s.IsBot = false
			s.BotDifficulty = ""
			s.FinalScore = finalScore
			s.TotalBid = topBid * 5
			s.HandsMade = 4
		} else {
			s.BotDifficulty = "normal"
			s.FinalScore = finalScore / float64(seat+2)
			// Bots take whatever places the human did not; the exact ranking
			// does not matter to anything under test, only that it is legal.
			s.Place = 1 + (place+seat-1)%4
		}
		if !completed {
			s.Place = 0
		}
		rec.Seats = append(rec.Seats, s)
	}

	for hand := range 5 {
		for seat := range 4 {
			bid := 2
			if seat == 0 && hand == 0 {
				bid = topBid
			}
			rec.Hands = append(rec.Hands, HandRecord{
				HandIndex:    hand,
				Seat:         seat,
				Bid:          bid,
				TricksWon:    3,
				ScoreDelta:   float64(bid) + 0.1,
				RunningTotal: float64(hand+1) * (float64(bid) + 0.1),
			})
		}
	}
	return rec
}

// statsByScope reads every scope into a map, so a test can name the one it
// cares about instead of indexing into AllScopes.
func statsByScope(t *testing.T, p *Postgres, userID string) map[string]Stats {
	t.Helper()
	list, err := p.Stats(context.Background(), userID)
	if err != nil {
		t.Fatalf("stats: %v", err)
	}
	out := make(map[string]Stats, len(list))
	for _, s := range list {
		out[s.Scope] = s
	}
	return out
}
