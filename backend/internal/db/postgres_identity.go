package db

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

// userColumns is every column User is built from, in scan order. Kept in one
// place so the three queries that return a user cannot drift apart.
const userColumns = `id, display_name, is_guest, avatar_id, country, created_at, last_seen_at, merged_into`

// scanUser reads one row of userColumns.
func scanUser(row pgx.Row) (User, error) {
	var (
		u      User
		merged *string
	)
	err := row.Scan(&u.ID, &u.DisplayName, &u.IsGuest, &u.AvatarID, &u.Country,
		&u.CreatedAt, &u.LastSeenAt, &merged)
	if err != nil {
		return User{}, err
	}
	if merged != nil {
		u.MergedInto = *merged
	}
	return u, nil
}

// resolveIdentitySQL is the whole of the guest login path, in one statement.
//
// The obvious implementation — SELECT, and INSERT if that found nothing — is
// wrong on the one occasion it matters: two devices (or the same device, twice,
// because the first response was lost) hitting a cold account at the same
// instant both see no row and both create a user. Two accounts, one device, and
// whichever token the client keeps decides which half of its history it can
// see.
//
// So the identity insert is the arbiter. ON CONFLICT ... DO UPDATE rather than
// DO NOTHING because only DO UPDATE makes RETURNING fire on the conflicting
// path; the loser of the race gets back the winner's user_id from the very
// statement that failed to insert.
//
// The users row is then inserted by a dependent CTE, and only when the identity
// insert actually took the id this statement proposed. Comparing the returned
// user_id against that proposal is how "did I win the race" is answered by a
// value rather than by peeking at xmax; a loser creates no user at all, which
// is what stops a retry storm from littering the table with orphan accounts.
//
// The proposal is MATERIALIZED so gen_random_uuid() is evaluated exactly once
// and both CTEs see the same id — without it Postgres is free to inline the
// subquery and generate a different uuid per reference, and the users insert
// would never fire.
//
// This ordering is also why user_identities' foreign key is DEFERRABLE: the
// identity is necessarily written before the user it points at.
const resolveIdentitySQL = `
WITH proposal AS MATERIALIZED (
	SELECT gen_random_uuid() AS id
), ident AS (
	INSERT INTO user_identities (user_id, provider, subject)
	SELECT proposal.id, $1, $2 FROM proposal
	ON CONFLICT (provider, subject) DO UPDATE
		SET user_id = user_identities.user_id
	RETURNING user_id
), created AS (
	INSERT INTO users (id, display_name, is_guest)
	SELECT proposal.id, $3, true
	FROM ident, proposal
	WHERE ident.user_id = proposal.id
	RETURNING id
)
SELECT user_id FROM ident`

// ResolveIdentity finds the user behind a provider identity, creating a guest
// on first sight.
func (p *Postgres) ResolveIdentity(ctx context.Context, provider Provider, subject, displayName string) (User, error) {
	if !provider.Valid() {
		return User{}, fmt.Errorf("db: unknown provider %q", provider)
	}
	if strings.TrimSpace(subject) == "" {
		return User{}, fmt.Errorf("db: %s identity needs a subject", provider)
	}

	var out User
	err := p.inTx(ctx, "resolve identity", func(tx pgx.Tx) error {
		// The overwhelmingly common case is a returning player, and a plain
		// read costs no row version and takes no lock. This is an optimisation
		// on top of the upsert, not the correctness argument: when it misses,
		// the statement below is still atomic, so nothing depends on the two
		// agreeing.
		var userID string
		err := tx.QueryRow(ctx,
			`SELECT user_id FROM user_identities WHERE provider = $1 AND subject = $2`,
			string(provider), subject,
		).Scan(&userID)
		if errors.Is(err, pgx.ErrNoRows) {
			err = tx.QueryRow(ctx, resolveIdentitySQL,
				string(provider), subject, displayName,
			).Scan(&userID)
		}
		if err != nil {
			return p.fail("resolve identity", err)
		}

		// A merged guest's device must land on the account that absorbed it, or
		// the player reinstalls and finds an empty history next to a token that
		// still works (§1.5).
		userID, err = followMerges(ctx, tx, userID)
		if err != nil {
			return p.fail("resolve identity", err)
		}

		// Resolving an identity *is* activity: this is the request the client
		// makes on every launch, so there is no cheaper place to record it.
		out, err = scanUser(tx.QueryRow(ctx,
			`UPDATE users SET last_seen_at = now() WHERE id = $1 RETURNING `+userColumns, userID))
		if err != nil {
			return p.fail("resolve identity", err)
		}
		return nil
	})
	if err != nil {
		return User{}, err
	}
	return out, nil
}

// mergeChainLimit bounds how far merged_into is followed. Merges are rare,
// operator-confirmed and never automatic, so a chain longer than this is a bug
// or a cycle rather than a busy player; either way, looping forever inside a
// request is the wrong answer.
const mergeChainLimit = 8

// followMerges walks merged_into to the surviving account.
func followMerges(ctx context.Context, tx pgx.Tx, userID string) (string, error) {
	for range mergeChainLimit {
		var merged *string
		if err := tx.QueryRow(ctx, `SELECT merged_into FROM users WHERE id = $1`, userID).Scan(&merged); err != nil {
			return "", err
		}
		if merged == nil {
			return userID, nil
		}
		userID = *merged
	}
	return "", fmt.Errorf("db: merge chain from %s is too long", userID)
}

// UserByID looks up one account.
func (p *Postgres) UserByID(ctx context.Context, userID string) (User, error) {
	if !validUUID(userID) {
		// An id that cannot be a uuid cannot name a row, and letting it reach
		// Postgres turns a 404 into a 500 with a type error in it.
		return User{}, ErrNotFound
	}
	u, err := scanUser(p.pool.QueryRow(ctx, `SELECT `+userColumns+` FROM users WHERE id = $1`, userID))
	if err != nil {
		return User{}, p.fail("look up user", err)
	}
	return u, nil
}

// UpdateDisplayName changes the name other players see.
func (p *Postgres) UpdateDisplayName(ctx context.Context, userID, name string) (User, error) {
	if !validUUID(userID) {
		return User{}, ErrNotFound
	}
	u, err := scanUser(p.pool.QueryRow(ctx,
		`UPDATE users SET display_name = $2 WHERE id = $1 RETURNING `+userColumns, userID, name))
	if err != nil {
		return User{}, p.fail("update display name", err)
	}
	return u, nil
}

// TouchLastSeen records activity. Callers treat the error as advisory, so this
// deliberately does not check whether the row existed.
func (p *Postgres) TouchLastSeen(ctx context.Context, userID string) error {
	if !validUUID(userID) {
		return ErrNotFound
	}
	_, err := p.pool.Exec(ctx, `UPDATE users SET last_seen_at = now() WHERE id = $1`, userID)
	return p.fail("touch last seen", err)
}

// linkIdentitySQL attaches a provider to an account, refusing to steal one.
//
// The WHERE on the DO UPDATE is what makes this safe. Linking an identity that
// is already ours is a no-op that returns a row (so a client retrying an
// interrupted upgrade succeeds); linking one that belongs to somebody else
// matches nothing, returns nothing, and the caller sees ErrConflict. The
// alternative — checking first — would let two link requests interleave and
// move an identity out from under an account.
const linkIdentitySQL = `
INSERT INTO user_identities (user_id, provider, subject, email)
VALUES ($1, $2, $3, $4)
ON CONFLICT (provider, subject) DO UPDATE
	SET email = EXCLUDED.email
	WHERE user_identities.user_id = $1
RETURNING user_id`

// LinkIdentity attaches another sign-in method to an existing account and
// clears its guest flag.
func (p *Postgres) LinkIdentity(ctx context.Context, userID string, provider Provider, subject, email string) error {
	if !provider.Valid() {
		return fmt.Errorf("db: unknown provider %q", provider)
	}
	if !validUUID(userID) {
		return ErrNotFound
	}
	if strings.TrimSpace(subject) == "" {
		return fmt.Errorf("db: %s identity needs a subject", provider)
	}
	// Linking a device id would not upgrade anything — it is the guest path —
	// and letting it clear is_guest would make a reinstall look like a login.
	if provider == ProviderDevice {
		return fmt.Errorf("db: device identities are created by ResolveIdentity, not linked")
	}

	return p.inTx(ctx, "link identity", func(tx pgx.Tx) error {
		var owner string
		err := tx.QueryRow(ctx, linkIdentitySQL, userID, string(provider), subject, email).Scan(&owner)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrConflict
		}
		if err != nil {
			return p.fail("link identity", err)
		}
		if _, err := tx.Exec(ctx, `UPDATE users SET is_guest = false WHERE id = $1`, userID); err != nil {
			return p.fail("link identity", err)
		}
		return nil
	})
}

// IdentitiesOf lists how an account can be signed into.
func (p *Postgres) IdentitiesOf(ctx context.Context, userID string) ([]Identity, error) {
	if !validUUID(userID) {
		return nil, ErrNotFound
	}
	rows, err := p.pool.Query(ctx,
		`SELECT user_id, provider, subject, email, created_at
		   FROM user_identities WHERE user_id = $1 ORDER BY created_at, provider`, userID)
	if err != nil {
		return nil, p.fail("list identities", err)
	}
	defer rows.Close()

	out := []Identity{}
	for rows.Next() {
		var id Identity
		var provider string
		if err := rows.Scan(&id.UserID, &provider, &id.Subject, &id.Email, &id.CreatedAt); err != nil {
			return nil, p.fail("list identities", err)
		}
		id.Provider = Provider(provider)
		out = append(out, id)
	}
	return out, p.fail("list identities", rows.Err())
}

// RestoreAccount moves this install's device identity onto another account —
// the "bring my saved account to a new phone" path (§1.6).
//
// The device id is the load-bearing value of the whole design, so this moves
// the same identity row rather than minting a new one: after the move,
// ResolveIdentity('device', <this device id>) lands on the restored account
// with no client-side change beyond the response it just got. The fresh guest
// account the new install started as is left behind — this is how a player
// abandons one install's empty account in favour of the one they saved.
//
// Both sides must be guests, and for the same reason — the only thing more
// valuable than a device id is the account it points at, and a device id alone
// must never hand a linked (signed-in) account to somebody who learned an id
// off a scoreboard. A linked account restores by signing in.
func (p *Postgres) RestoreAccount(ctx context.Context, currentID, targetID string) (RestoreResult, error) {
	// An id that cannot be a uuid cannot name a row → not found, never a 500.
	if !validUUID(currentID) || !validUUID(targetID) {
		return RestoreResult{}, ErrNotFound
	}
	if currentID == targetID {
		// Restoring the account this device already owns is a no-op worth
		// doing cheaply, not a mistake the client has to explain.
		user, err := p.UserByID(ctx, currentID)
		return RestoreResult{User: user}, err
	}

	var result RestoreResult
	err := p.inTx(ctx, "restore account", func(tx pgx.Tx) error {
		// The restoring install must still be a bare guest. Refusing is also
		// fair the other way round: an account with a real sign-in method has
		// no business absorbing a device identity, and telling it "no" beats
		// silently stranding its own device.
		current, err := scanUser(tx.QueryRow(ctx,
			`SELECT `+userColumns+` FROM users WHERE id = $1 FOR UPDATE`, currentID))
		if err != nil {
			return p.fail("restore current user", err)
		}
		if !current.IsGuest {
			return ErrNotGuest
		}

		// The target may have been absorbed by a merge; the surviving account
		// is the one the history lives on, so that is the one to restore to.
		target, err := followMerges(ctx, tx, targetID)
		if err != nil {
			return p.fail("restore follow merge", err)
		}
		claimed, err := scanUser(tx.QueryRow(ctx,
			`SELECT `+userColumns+` FROM users WHERE id = $1 FOR UPDATE`, target))
		if err != nil {
			return p.fail("restore target user", err)
		}
		if !claimed.IsGuest {
			// A linked account is not restorable by its id, and saying so is
			// telling a caller the account exists, which is the same shape of
			// answer as a plain miss.
			return ErrNotFound
		}

		// Move the identity by naming provider and owner, never by subject:
		// the server must not start trusting the client with its own device id.
		// Exactly one row matches — the subject (the device id) is globally
		// unique — so the UPDATE either moves the one identity or matches
		// nothing, which p.fail turns into ErrNotFound.
		err = tx.QueryRow(ctx,
			`UPDATE user_identities SET user_id = $1
			  WHERE provider = 'device' AND user_id = $2
			  RETURNING user_id`, target, currentID).Scan(&target)
		if err != nil {
			return p.fail("restore move identity", err)
		}

		// The replaced install is now a corpse only (no identity points at it),
		// which is fine when it died empty and wasteful when it has games the
		// player may want. Count first, so the response can say which
		// happened; the client offers merge-or-discard only when there is
		// something to decide about.
		var games int
		if err := tx.QueryRow(ctx,
			`SELECT count(*) FROM game_seats WHERE user_id = $1`, currentID).Scan(&games); err != nil {
			return p.fail("restore count games", err)
		}
		if games == 0 {
			// No history at all: delete it, or every restore would leave an
			// account that nobody can ever sign into again, forever.
			if _, err := tx.Exec(ctx, `DELETE FROM users WHERE id = $1`, currentID); err != nil {
				return p.fail("restore delete replaced guest", err)
			}
		} else {
			result.Abandoned = &AbandonedAccount{ID: currentID, Games: games}
		}

		result.User, err = scanUser(tx.QueryRow(ctx,
			`SELECT `+userColumns+` FROM users WHERE id = $1`, target))
		return p.fail("restore read target", err)
	})
	if err != nil {
		return RestoreResult{}, err
	}
	return result, nil
}

// MergeGuest folds an abandoned guest (a restore's residue — no identities, so
// nobody can sign into it) into an account. Games move so the survivor's
// history gains them; the survivor's statistics are recomputed rather than
// summed, because maxima and streaks do not add.
//
// The "no identities" rule is the whole safety argument. An account that can
// still be signed into is reached by signing in — never absorbed by somebody
// who typed its id — so this never acts as a way to steal a linked account, or
// to fold a live guest's history into an attacker's.
func (p *Postgres) MergeGuest(ctx context.Context, dst, src string) (User, error) {
	if !validUUID(dst) || !validUUID(src) || dst == src {
		return User{}, ErrNotFound
	}

	var out User
	err := p.inTx(ctx, "merge abandoned guest", func(tx pgx.Tx) error {
		// The survivor must exist and not itself have been merged away.
		var dstMerged *string
		if err := tx.QueryRow(ctx,
			`SELECT merged_into FROM users WHERE id = $1 FOR UPDATE`, dst).Scan(&dstMerged); err != nil {
			return p.fail("merge guest survivor", err)
		}
		if dstMerged != nil {
			return ErrNotFound
		}

		// The abandoned half must still be what the restore left behind.
		srcUser, err := scanUser(tx.QueryRow(ctx,
			`SELECT `+userColumns+` FROM users WHERE id = $1 FOR UPDATE`, src))
		if err != nil {
			return p.fail("merge guest abandoned", err)
		}
		if !srcUser.IsGuest || srcUser.MergedInto != "" {
			return ErrNotFound
		}
		var remaining int
		if err := tx.QueryRow(ctx,
			`SELECT count(*) FROM user_identities WHERE user_id = $1`, src).Scan(&remaining); err != nil {
			return p.fail("merge guest identities", err)
		}
		if remaining != 0 {
			return ErrNotFound
		}

		if _, err := tx.Exec(ctx, `UPDATE game_seats SET user_id = $1 WHERE user_id = $2`, dst, src); err != nil {
			return p.fail("merge guest seats", err)
		}
		if _, err := tx.Exec(ctx,
			`UPDATE users SET merged_into = $1, is_guest = false WHERE id = $2`, dst, src); err != nil {
			return p.fail("merge guest user", err)
		}
		if _, err := tx.Exec(ctx, `DELETE FROM user_stats WHERE user_id = $1`, src); err != nil {
			return p.fail("merge guest stats", err)
		}
		if err := p.recomputeStats(ctx, tx, dst); err != nil {
			return p.fail("merge guest recompute", err)
		}

		out, err = scanUser(tx.QueryRow(ctx,
			`SELECT `+userColumns+` FROM users WHERE id = $1`, dst))
		return p.fail("merge guest reload", err)
	})
	if err != nil {
		return User{}, err
	}
	return out, nil
}

// DeleteAbandoned removes an abandoned guest account — the "discard that
// history" half of the post-restore decision. Only a guest with no identities
// qualifies, for the same reason merge only accepts one. The account's game
// rows are NOT deleted: a game that other humans played in survives for them,
// with the deleted install's seat left unattributed by the schema's
// `ON DELETE SET NULL`. Discarding the account never discards anyone else's
// game.
func (p *Postgres) DeleteAbandoned(ctx context.Context, id string) error {
	if !validUUID(id) {
		return ErrNotFound
	}
	return p.inTx(ctx, "delete abandoned guest", func(tx pgx.Tx) error {
		u, err := scanUser(tx.QueryRow(ctx,
			`SELECT `+userColumns+` FROM users WHERE id = $1 FOR UPDATE`, id))
		if err != nil {
			return p.fail("delete abandoned user", err)
		}
		if !u.IsGuest {
			return ErrNotFound
		}
		var remaining int
		if err := tx.QueryRow(ctx,
			`SELECT count(*) FROM user_identities WHERE user_id = $1`, id).Scan(&remaining); err != nil {
			return p.fail("delete abandoned identities", err)
		}
		if remaining != 0 {
			return ErrNotFound
		}
		if _, err := tx.Exec(ctx, `DELETE FROM users WHERE id = $1`, id); err != nil {
			return p.fail("delete abandoned delete", err)
		}
		return nil
	})
}

// MergeUsers folds src into dst.
//
// Nothing is deleted except src's statistics. The seats move, so dst's history
// gains src's games; src's users row stays behind with merged_into set, so any
// token still in flight resolves through it (see followMerges) and the record
// of what was absorbed survives. Identities stay on src for the same reason —
// the merged_into hop already routes them, and moving them would erase the
// evidence of which account originally owned which login.
//
// dst's statistics are recomputed rather than added to, because maxima and
// streaks do not sum: two accounts with a best streak of three do not have a
// best streak of six.
func (p *Postgres) MergeUsers(ctx context.Context, dst, src string) error {
	if !validUUID(dst) || !validUUID(src) {
		return ErrNotFound
	}
	if dst == src {
		return fmt.Errorf("db: cannot merge an account into itself")
	}

	return p.inTx(ctx, "merge users", func(tx pgx.Tx) error {
		// Both sides must exist, and the survivor must not itself be merged
		// away, or the result is a chain that points at a dead account.
		var dstMerged *string
		if err := tx.QueryRow(ctx, `SELECT merged_into FROM users WHERE id = $1 FOR UPDATE`, dst).Scan(&dstMerged); err != nil {
			return p.fail("merge users", err)
		}
		if dstMerged != nil {
			return fmt.Errorf("db: %s has itself been merged away", dst)
		}
		var srcMerged *string
		if err := tx.QueryRow(ctx, `SELECT merged_into FROM users WHERE id = $1 FOR UPDATE`, src).Scan(&srcMerged); err != nil {
			return p.fail("merge users", err)
		}

		if _, err := tx.Exec(ctx, `UPDATE game_seats SET user_id = $1 WHERE user_id = $2`, dst, src); err != nil {
			return p.fail("merge users", err)
		}
		if _, err := tx.Exec(ctx,
			`UPDATE users SET merged_into = $1, is_guest = false WHERE id = $2`, dst, src); err != nil {
			return p.fail("merge users", err)
		}
		if _, err := tx.Exec(ctx, `DELETE FROM user_stats WHERE user_id = $1`, src); err != nil {
			return p.fail("merge users", err)
		}
		return p.recomputeStats(ctx, tx, dst)
	})
}

// validUUID reports whether s can name a row. Every id this package hands out
// is a uuid, so anything else is a client typing in the URL bar and deserves a
// not-found rather than a driver-level type error leaking out of a query.
//
// pgtype does the parsing so the package needs no uuid dependency of its own —
// ids are minted by gen_random_uuid() in the database, which is the only place
// they have to be unique.
func validUUID(s string) bool {
	var u pgtype.UUID
	return u.Scan(s) == nil
}
