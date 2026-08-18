-- 0001_init: accounts, match history and per-scope statistics.
--
-- The model is docs/PERSISTENCE.md §1.2 (identity), §2.1 (game grain) and §3
-- (statistics). Read that first; the comments here only justify the choices
-- that are invisible from the Go side.
--
-- Two rules run through the whole file:
--
--   * every score is numeric(6,2), never float. Call Break scores carry one
--     decimal (bid + 0.1 per overtrick), and 8.3 as a float8 is not equal to
--     itself across a round trip. Money-style arithmetic wants exact decimals.
--   * everything below a game cascades from it, so deleting a game cannot
--     leave orphaned seats, hands or tricks behind.

-- Requires Postgres 13 or newer, where gen_random_uuid() lives in pg_catalog.
--
-- There is deliberately no CREATE EXTENSION anywhere in this file. pgcrypto
-- would supply the same function on 12, but installing an extension needs
-- rights managed Postgres often withholds from the application role, and a
-- schema the application cannot apply for itself is not much of a schema.

-- ------------------------------------------------------------------ identity

-- users is the only thing games, seats and statistics ever reference. Its id is
-- a surrogate key and nothing else is: the device id lives one table over, so
-- the day a guest signs in with Google no foreign key has to move.
CREATE TABLE users (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    display_name  text        NOT NULL DEFAULT '',
    is_guest      boolean     NOT NULL DEFAULT true,
    avatar_id     text        NOT NULL DEFAULT '',
    country       text        NOT NULL DEFAULT '',
    created_at    timestamptz NOT NULL DEFAULT now(),
    last_seen_at  timestamptz NOT NULL DEFAULT now(),

    -- Set when this account has been absorbed into another (§1.5). The row is
    -- kept rather than deleted so that tokens still in flight, and the audit
    -- trail of what was merged where, both survive. Identity resolution follows
    -- this pointer, which is why a merged guest's device still signs in.
    merged_into   uuid REFERENCES users (id),

    CONSTRAINT users_not_merged_into_self CHECK (merged_into IS NULL OR merged_into <> id)
);

-- Merged accounts are a tiny minority, so the index that finds "everything
-- absorbed into X" is partial and costs almost nothing to maintain.
CREATE INDEX users_merged_into_idx ON users (merged_into) WHERE merged_into IS NOT NULL;

-- user_identities is many-to-one: one account may be reachable by device id and
-- by Google and by Apple at once, which is what makes upgrading a guest an
-- insert rather than a migration.
CREATE TABLE user_identities (
    user_id    uuid NOT NULL,
    provider   text NOT NULL,
    -- The provider's opaque id: the client-generated device id for 'device',
    -- the Firebase uid otherwise.
    subject    text        NOT NULL,
    email      text        NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL DEFAULT now(),

    -- This *is* the UNIQUE (provider, subject) the design calls for: the pair
    -- identifies the row, so it may as well be the key. Making it the primary
    -- key gives ON CONFLICT (provider, subject) something to arbitrate on and
    -- guarantees two devices booting at once cannot mint two accounts.
    PRIMARY KEY (provider, subject),

    CONSTRAINT user_identities_provider_check
        CHECK (provider IN ('device', 'google', 'facebook', 'apple')),

    -- DEFERRABLE INITIALLY DEFERRED is load-bearing, not decoration. Resolving
    -- an identity is a single statement that inserts the identity and then, in
    -- a dependent CTE, inserts the users row it points at -- the identity has
    -- to be written first because its ON CONFLICT is what decides whether a new
    -- user is needed at all. Deferring the check to commit makes that ordering
    -- legal without weakening the constraint.
    CONSTRAINT user_identities_user_id_fkey FOREIGN KEY (user_id)
        REFERENCES users (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

-- "how can this account sign in" for the profile screen's account tab.
CREATE INDEX user_identities_user_id_idx ON user_identities (user_id);

-- --------------------------------------------------------------------- games

CREATE TABLE games (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    mode           text        NOT NULL,
    -- 'server' games were scored by us and are authoritative; 'client' games
    -- were scored by a phone and are not. A column rather than an inference
    -- from mode, so nothing public can ever accidentally trust an upload.
    source         text        NOT NULL,
    room_code      text        NOT NULL DEFAULT '',
    -- The uuid the client mints when an offline game starts. NULL for games
    -- played on the server, which need no idempotency key.
    client_game_id text,
    hands_total    smallint    NOT NULL DEFAULT 0,
    -- false for a table that closed without a final scoreboard. Such a game
    -- still counts as played -- a rage-quit should not vanish -- but never as
    -- won, and never sets a score record (§2.3).
    completed      boolean     NOT NULL DEFAULT false,
    started_at     timestamptz NOT NULL DEFAULT now(),
    finished_at    timestamptz NOT NULL DEFAULT now(),
    created_at     timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT games_mode_check CHECK (mode IN ('bots', 'private', 'online', 'lan')),
    CONSTRAINT games_source_check CHECK (source IN ('server', 'client'))
);

-- Partial, because the vast majority of rows are server games with no client
-- id and NULLs are not equal to each other anyway -- a plain unique index would
-- work but would index every server game for nothing. This index is the whole
-- of the idempotency guarantee: a phone that retries an upload collides here
-- and gets the original game back instead of a duplicate.
CREATE UNIQUE INDEX games_client_game_id_key
    ON games (client_game_id) WHERE client_game_id IS NOT NULL;

-- game_seats is the row that makes history queryable. Putting the user on the
-- seat rather than on the game is what lets four players each see the same game
-- in their own history with their own result.
CREATE TABLE game_seats (
    game_id        uuid     NOT NULL REFERENCES games (id) ON DELETE CASCADE,
    seat           smallint NOT NULL,
    -- NULL for a bot, and for a human the server could not attribute to an
    -- account (an old client that sent no device id). Identity is an enrichment
    -- of a seat, never a precondition for one.
    user_id        uuid REFERENCES users (id) ON DELETE SET NULL,
    display_name   text          NOT NULL DEFAULT '',
    is_bot         boolean       NOT NULL DEFAULT false,
    bot_difficulty text          NOT NULL DEFAULT '',
    final_score    numeric(6, 2) NOT NULL DEFAULT 0,
    -- 1..4, or 0 for an abandoned game that never ranked anyone.
    place          smallint      NOT NULL DEFAULT 0,
    total_bid      smallint      NOT NULL DEFAULT 0,
    total_tricks   smallint      NOT NULL DEFAULT 0,
    -- hands where this seat took at least its bid.
    hands_made     smallint      NOT NULL DEFAULT 0,

    -- Denormalised from games, purely so the history index below can be walked
    -- without touching games at all. Safe to copy because both are written once
    -- inside the same transaction and never updated afterwards: a game's mode
    -- and finish time are facts about a game that has already ended.
    mode           text          NOT NULL,
    finished_at    timestamptz   NOT NULL,

    PRIMARY KEY (game_id, seat),
    CONSTRAINT game_seats_seat_check CHECK (seat BETWEEN 0 AND 3),
    CONSTRAINT game_seats_place_check CHECK (place BETWEEN 0 AND 4),
    CONSTRAINT game_seats_mode_check CHECK (mode IN ('bots', 'private', 'online', 'lan'))
);

-- "my last 20 games, newest first" must be an index scan with no sort node, and
-- that is only possible if the whole ORDER BY key lives in this index. Hence
-- the denormalised finished_at above: an index on (user_id) alone would find
-- the rows but Postgres would still have to fetch every one of a heavy user's
-- games from `games`, sort them, and throw all but 20 away.
--
-- The trailing game_id is not a tiebreak nicety either -- it is what makes the
-- keyset cursor work. Pagination compares the row (finished_at, game_id) as a
-- tuple, and a tuple comparison only turns into a single index range scan when
-- the index carries both columns in that order and that direction.
--
-- Partial on user_id IS NOT NULL because roughly three seats in four are bots,
-- and bot seats are never queried by user.
CREATE INDEX game_seats_history_idx
    ON game_seats (user_id, finished_at DESC, game_id DESC)
    WHERE user_id IS NOT NULL;

-- Same shape with mode wedged in as an equality prefix, for `?mode=bots`.
-- Without it a mode filter degrades to scanning the whole history and
-- discarding, which for a filter that keeps a quarter of the rows means reading
-- four pages to fill one.
CREATE INDEX game_seats_history_mode_idx
    ON game_seats (user_id, mode, finished_at DESC, game_id DESC)
    WHERE user_id IS NOT NULL;

-- The per-hand scoreboard: one row per seat per hand. This is what a history
-- screen actually renders, and it is cheap -- five hands times four seats.
CREATE TABLE game_hands (
    game_id       uuid     NOT NULL REFERENCES games (id) ON DELETE CASCADE,
    hand_index    smallint NOT NULL,
    seat          smallint NOT NULL,
    bid           smallint      NOT NULL DEFAULT 0,
    tricks_won    smallint      NOT NULL DEFAULT 0,
    score_delta   numeric(6, 2) NOT NULL DEFAULT 0,
    running_total numeric(6, 2) NOT NULL DEFAULT 0,

    PRIMARY KEY (game_id, hand_index, seat),
    CONSTRAINT game_hands_seat_check CHECK (seat BETWEEN 0 AND 3)
);

-- Card-level replay, written only when trick recording is switched on. Roughly
-- 260 rows a game and most products never read it, but the table exists from
-- day one so enabling it is a config change rather than a migration.
CREATE TABLE game_tricks (
    game_id      uuid     NOT NULL REFERENCES games (id) ON DELETE CASCADE,
    hand_index   smallint NOT NULL,
    trick_number smallint NOT NULL,
    lead_seat    smallint NOT NULL,
    winner_seat  smallint NOT NULL,
    -- [{"seat":0,"card":"AS"}, ...] ordered from the lead. jsonb rather than a
    -- fifth table: a trick's plays are only ever read as a whole, alongside the
    -- trick, and four more rows per trick would quadruple the row count of the
    -- largest table in the schema for nothing.
    plays        jsonb    NOT NULL DEFAULT '[]'::jsonb,

    PRIMARY KEY (game_id, hand_index, trick_number)
);

-- ---------------------------------------------------------------- statistics

-- One row per (user, scope). Denormalised on purpose: the profile screen must
-- not run a five-table aggregate every time it opens, and these counters are
-- only ever touched by one transaction per game.
--
-- Derived figures -- win rate, average score, bid accuracy -- are deliberately
-- absent. They are computed on read so the two numbers can never disagree.
CREATE TABLE user_stats (
    user_id            uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    scope              text NOT NULL,

    games_played       integer NOT NULL DEFAULT 0,
    games_completed    integer NOT NULL DEFAULT 0,
    games_won          integer NOT NULL DEFAULT 0,
    games_lost         integer NOT NULL DEFAULT 0,
    -- 0 means "never ranked". Minima over a sentinel need NULLIF/LEAST rather
    -- than a plain LEAST, which is why the update statements look the way they
    -- do; storing 0 keeps the Go struct free of pointers.
    best_place         smallint NOT NULL DEFAULT 0,

    hands_played       integer NOT NULL DEFAULT 0,
    total_bid          integer NOT NULL DEFAULT 0,
    bids_made          integer NOT NULL DEFAULT 0,
    bids_failed        integer NOT NULL DEFAULT 0,
    highest_bid        smallint NOT NULL DEFAULT 0,
    total_tricks       integer NOT NULL DEFAULT 0,

    -- Wide enough to accumulate a lifetime of games; the per-game columns stay
    -- numeric(6,2) because a single game's score cannot reach four figures.
    total_score        numeric(12, 2) NOT NULL DEFAULT 0,
    -- These three are nullable, and that is the point: a Call Break score can
    -- be negative, so 0 is a real value and cannot double as "no data yet".
    -- NULL means it, and GREATEST/LEAST ignore NULL arguments in Postgres,
    -- which makes the first completed game set the record with no special case.
    highest_game_score numeric(6, 2),
    lowest_game_score  numeric(6, 2),
    highest_hand_score numeric(6, 2),

    current_win_streak integer NOT NULL DEFAULT 0,
    best_win_streak    integer NOT NULL DEFAULT 0,
    last_played_at     timestamptz,

    PRIMARY KEY (user_id, scope),
    CONSTRAINT user_stats_scope_check
        CHECK (scope IN ('all', 'bots', 'private', 'online', 'lan'))
);
