package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/nabin31bogati/callbreak/backend/internal/auth"
	"github.com/nabin31bogati/callbreak/backend/internal/config"
	"github.com/nabin31bogati/callbreak/backend/internal/db"
)

// ---------------------------------------------------------------- fake store
//
// The whole db.Store interface, in memory. Implementing it here rather than
// reaching for Postgres keeps this suite runnable with `go test ./...` on a
// laptop with nothing installed, which is the same property the rest of the
// server's tests have.

type fakeStore struct {
	mu sync.Mutex

	on bool
	// calls records every method that ran, so a test can assert that validation
	// rejected a request *before* it reached the database.
	calls []string

	users      map[string]db.User
	identities map[string][]db.Identity
	subjects   map[string]string // "provider|subject" -> user id
	// gamesByUser is how many recorded games claim a user's seat — the fake's
	// stand-in for "this account has history".
	gamesByUser map[string]int
	stats       []db.Stats
	page        db.HistoryPage
	detail      db.GameDetail
	// lastQuery is the last history filter the handler built, so a test can
	// check clamping and validation without a real database.
	lastQuery db.HistoryQuery
	// lastAdminQuery is the last admin history filter, checked the same way.
	lastAdminQuery db.AdminGameQuery

	recorded []db.GameRecord
	nextGame string
	// nextDuplicate is what RecordGame reports for the idempotency key, so a
	// test can drive the duplicate branch without a real database.
	nextDuplicate bool
	failWith      error
	failCalls     map[string]bool
	// panicOn makes one method blow up, to prove the recovery middleware turns
	// that into one 500 rather than a dead process.
	panicOn string
}

var _ db.Store = (*fakeStore)(nil)

func newFakeStore() *fakeStore {
	return &fakeStore{
		on:          true,
		users:       make(map[string]db.User),
		identities:  make(map[string][]db.Identity),
		subjects:    make(map[string]string),
		gamesByUser: make(map[string]int),
		nextGame:    "018f3a2b-0000-0000-0000-00000000game",
		failCalls:   make(map[string]bool),
	}
}

func (f *fakeStore) note(name string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, name)
	if f.panicOn == name {
		panic("fakeStore: deliberate panic in " + name)
	}
	if f.failCalls[name] {
		return f.failWith
	}
	return nil
}

func (f *fakeStore) called(name string) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, c := range f.calls {
		if c == name {
			return true
		}
	}
	return false
}

func (f *fakeStore) Enabled() bool { return f.on }

func (f *fakeStore) ResolveIdentity(_ context.Context, p db.Provider, subject, name string) (db.User, error) {
	if err := f.note("ResolveIdentity"); err != nil {
		return db.User{}, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()

	key := string(p) + "|" + subject
	if id, ok := f.subjects[key]; ok {
		return f.users[id], nil
	}
	user := db.User{
		// A real uuid shape, so handlers that validate ids accept it. The
		// counter guarantees uniqueness; the fixed pieces give it a uuid v4
		// silhouette for a test that parses one.
		ID:          fmt.Sprintf("018f3a2b-7c41-4%03d-9a10-%012d", len(f.users)%1000, len(f.users)),
		DisplayName: name,
		IsGuest:     true,
		CreatedAt:   time.Date(2026, 8, 1, 12, 0, 0, 0, time.UTC),
		LastSeenAt:  time.Date(2026, 8, 10, 9, 41, 22, 0, time.UTC),
	}
	f.users[user.ID] = user
	f.subjects[key] = user.ID
	f.identities[user.ID] = []db.Identity{{
		UserID: user.ID, Provider: p, Subject: subject,
		CreatedAt: user.CreatedAt,
	}}
	return user, nil
}

func (f *fakeStore) UserByID(_ context.Context, id string) (db.User, error) {
	if err := f.note("UserByID"); err != nil {
		return db.User{}, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	user, ok := f.users[id]
	if !ok {
		return db.User{}, db.ErrNotFound
	}
	return user, nil
}

func (f *fakeStore) UpdateDisplayName(_ context.Context, id, name string) (db.User, error) {
	if err := f.note("UpdateDisplayName"); err != nil {
		return db.User{}, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	user, ok := f.users[id]
	if !ok {
		return db.User{}, db.ErrNotFound
	}
	user.DisplayName = name
	f.users[id] = user
	return user, nil
}

func (f *fakeStore) TouchLastSeen(context.Context, string) error { return f.note("TouchLastSeen") }

func (f *fakeStore) LinkIdentity(context.Context, string, db.Provider, string, string) error {
	return f.note("LinkIdentity")
}

func (f *fakeStore) IdentitiesOf(_ context.Context, id string) ([]db.Identity, error) {
	if err := f.note("IdentitiesOf"); err != nil {
		return nil, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.identities[id], nil
}

// RestoreAccount mirrors the Postgres behaviour closely enough for the handler
// tests: both sides must be guests, the current device identity moves, an
// install with no games is deleted outright, and one with games is kept and
// reported so the caller can offer merge-or-discard.
func (f *fakeStore) RestoreAccount(_ context.Context, currentID, targetID string) (db.RestoreResult, error) {
	if err := f.note("RestoreAccount"); err != nil {
		return db.RestoreResult{}, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()

	current, ok := f.users[currentID]
	if !ok {
		return db.RestoreResult{}, db.ErrNotFound
	}
	if !current.IsGuest {
		return db.RestoreResult{}, db.ErrNotGuest
	}
	claimed, ok := f.users[targetID]
	if !ok {
		return db.RestoreResult{}, db.ErrNotFound
	}
	if !claimed.IsGuest {
		return db.RestoreResult{}, db.ErrNotFound
	}

	moved := false
	ids := f.identities[currentID]
	for i, id := range ids {
		if id.Provider != db.ProviderDevice {
			continue
		}
		f.subjects[string(id.Provider)+"|"+id.Subject] = targetID
		movedID := ids[i]
		movedID.UserID = targetID
		f.identities[currentID] = append(ids[:i], ids[i+1:]...)
		f.identities[targetID] = append(f.identities[targetID], movedID)
		moved = true
		break
	}
	if !moved {
		return db.RestoreResult{}, db.ErrNotFound
	}

	result := db.RestoreResult{User: claimed}
	if games := f.gamesByUser[currentID]; games == 0 {
		delete(f.users, currentID)
		delete(f.identities, currentID)
		delete(f.gamesByUser, currentID)
	} else {
		result.Abandoned = &db.AbandonedAccount{ID: currentID, Games: games}
	}
	return result, nil
}

func (f *fakeStore) MergeGuest(_ context.Context, dst, src string) (db.User, error) {
	if err := f.note("MergeGuest"); err != nil {
		return db.User{}, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()

	if dst == src {
		return db.User{}, db.ErrNotFound
	}
	dstUser, ok := f.users[dst]
	if !ok || dstUser.MergedInto != "" {
		return db.User{}, db.ErrNotFound
	}
	srcUser, ok := f.users[src]
	if !ok || !srcUser.IsGuest || len(f.identities[src]) != 0 {
		return db.User{}, db.ErrNotFound
	}

	f.gamesByUser[dst] += f.gamesByUser[src]
	delete(f.gamesByUser, src)
	srcUser.IsGuest = false
	srcUser.MergedInto = dst
	f.users[src] = srcUser
	delete(f.identities, src)
	return dstUser, nil
}

func (f *fakeStore) DeleteAbandoned(_ context.Context, id string) error {
	if err := f.note("DeleteAbandoned"); err != nil {
		return err
	}
	f.mu.Lock()
	defer f.mu.Unlock()

	u, ok := f.users[id]
	if !ok || !u.IsGuest || len(f.identities[id]) != 0 {
		return db.ErrNotFound
	}
	delete(f.users, id)
	delete(f.identities, id)
	delete(f.gamesByUser, id)
	return nil
}

func (f *fakeStore) MergeUsers(context.Context, string, string) error { return f.note("MergeUsers") }

func (f *fakeStore) RecordGame(_ context.Context, rec db.GameRecord) (string, bool, error) {
	if err := f.note("RecordGame"); err != nil {
		return "", false, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.recorded = append(f.recorded, rec)
	for _, seat := range rec.Seats {
		if seat.UserID != "" {
			f.gamesByUser[seat.UserID]++
		}
	}
	return f.nextGame, f.nextDuplicate, nil
}

func (f *fakeStore) History(_ context.Context, q db.HistoryQuery) (db.HistoryPage, error) {
	if err := f.note("History"); err != nil {
		return db.HistoryPage{}, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.lastQuery = q
	return f.page, nil
}

func (f *fakeStore) Game(_ context.Context, _, _ string) (db.GameDetail, error) {
	if err := f.note("Game"); err != nil {
		return db.GameDetail{}, err
	}
	return f.detail, nil
}

func (f *fakeStore) Stats(_ context.Context, _ string) ([]db.Stats, error) {
	if err := f.note("Stats"); err != nil {
		return nil, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.stats, nil
}

// AdminGames reuses the seeded page — GameSummary rows, the same shape the
// real store returns — so the admin handler is exercised against the same
// structure without a database.
func (f *fakeStore) AdminGames(_ context.Context, q db.AdminGameQuery) (db.AdminGamePage, error) {
	if err := f.note("AdminGames"); err != nil {
		return db.AdminGamePage{}, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.lastAdminQuery = q
	return db.AdminGamePage{Games: f.page.Games, NextCursor: f.page.NextCursor}, nil
}

func (f *fakeStore) AdminGame(_ context.Context, _ string) (db.GameDetail, error) {
	if err := f.note("AdminGame"); err != nil {
		return db.GameDetail{}, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.detail, nil
}

func (f *fakeStore) Close() error { return nil }

// ------------------------------------------------------------------ harness

type harness struct {
	t      *testing.T
	server *httptest.Server
	store  *fakeStore
	signer *auth.Signer
	token  string
	userID string
}

func newHarness(t *testing.T, store db.Store) *harness {
	t.Helper()

	cfg := config.Config{APIRatePerMinute: 120}
	signer := auth.NewSigner([]byte("test-secret"))
	// Discard: a failing test should show assertions, not the request log.
	log := slog.New(slog.NewTextHandler(io.Discard, nil))

	mux := http.NewServeMux()
	NewServer(cfg, store, signer, log).Handler(mux)

	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	h := &harness{t: t, server: srv, signer: signer}
	if fake, ok := store.(*fakeStore); ok {
		h.store = fake
		user, _ := fake.ResolveIdentity(context.Background(), db.ProviderDevice, "seed-device-id", "Nabin")
		h.userID = user.ID
		h.token, _ = signer.IssueSession(user.ID)
		fake.mu.Lock()
		fake.calls = nil // the seed is setup, not something under test.
		fake.mu.Unlock()
	}
	return h
}

// do issues a request. An empty token means no Authorization header at all.
func (h *harness) do(method, path, token string, body any) (*http.Response, map[string]any) {
	h.t.Helper()

	var reader io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			h.t.Fatal(err)
		}
		reader = bytes.NewReader(raw)
	}

	req, err := http.NewRequest(method, h.server.URL+path, reader)
	if err != nil {
		h.t.Fatal(err)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}

	res, err := http.DefaultClient.Do(req)
	if err != nil {
		h.t.Fatal(err)
	}
	defer res.Body.Close()

	var decoded map[string]any
	raw, _ := io.ReadAll(res.Body)
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &decoded); err != nil {
			h.t.Fatalf("%s %s returned a body that is not a JSON object: %s", method, path, raw)
		}
	}
	return res, decoded
}

// expectError asserts the documented error envelope: a status, and a code the
// client switches on, with a human message beside it.
func expectError(t *testing.T, res *http.Response, body map[string]any, status int, code string) {
	t.Helper()
	if res.StatusCode != status {
		t.Fatalf("status = %d, want %d (body %v)", res.StatusCode, status, body)
	}
	envelope, ok := body["error"].(map[string]any)
	if !ok {
		t.Fatalf("body is not {\"error\":{...}}: %v", body)
	}
	if envelope["code"] != code {
		t.Errorf("code = %v, want %q", envelope["code"], code)
	}
	if msg, _ := envelope["message"].(string); strings.TrimSpace(msg) == "" {
		t.Error("every error needs a human-readable message")
	}
	if keys := keysOf(envelope); !containsAll(keys, []string{"code", "message"}) {
		t.Errorf("error object keys = %v, want at least code and message", keys)
	}
}

func keysOf(m map[string]any) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func containsAll(have, want []string) bool {
	set := make(map[string]bool, len(have))
	for _, h := range have {
		set[h] = true
	}
	for _, w := range want {
		if !set[w] {
			return false
		}
	}
	return true
}

// sameKeys asserts an object carries exactly the fields docs/API.md documents —
// no more, no fewer. Missing one breaks the Flutter decoder; an extra one is a
// field somebody added without writing it down.
func sameKeys(t *testing.T, what string, got map[string]any, want []string) {
	t.Helper()
	have := keysOf(got)
	expect := append([]string(nil), want...)
	sort.Strings(expect)
	if strings.Join(have, ",") != strings.Join(expect, ",") {
		t.Errorf("%s fields:\n got  %v\n want %v", what, have, expect)
	}
}

func object(t *testing.T, m map[string]any, key string) map[string]any {
	t.Helper()
	v, ok := m[key].(map[string]any)
	if !ok {
		t.Fatalf("%q is not an object in %v", key, m)
	}
	return v
}

func array(t *testing.T, m map[string]any, key string) []any {
	t.Helper()
	v, ok := m[key].([]any)
	if !ok {
		t.Fatalf("%q is not an array in %v", key, m)
	}
	return v
}

// --------------------------------------------------------------------- auth

func TestUnauthenticatedRequestsAreRejected(t *testing.T) {
	h := newHarness(t, newFakeStore())

	// Everything except POST /v1/auth/device needs a session.
	for _, route := range []struct {
		method, path string
	}{
		{"POST", "/v1/auth/refresh"},
		{"POST", "/v1/auth/link"},
		{"GET", "/v1/me"},
		{"PATCH", "/v1/me"},
		{"GET", "/v1/me/stats"},
		{"GET", "/v1/me/games"},
		{"GET", "/v1/games/018f3a2b"},
		{"POST", "/v1/games"},
	} {
		res, body := h.do(route.method, route.path, "", map[string]any{})
		expectError(t, res, body, http.StatusUnauthorized, codeUnauthorized)
	}

	// No handler behind the wall may have run.
	for _, call := range []string{"UserByID", "Stats", "History", "Game", "RecordGame"} {
		if h.store.called(call) {
			t.Errorf("%s ran for an unauthenticated request", call)
		}
	}
}

func TestTokensOfTheWrongKindAreRejected(t *testing.T) {
	h := newHarness(t, newFakeStore())

	guest := h.signer.IssueGuest(auth.NewGuestID())
	resume := h.signer.IssueResume(auth.NewGuestID(), "7QF2", 1)
	foreign, _ := auth.NewSigner([]byte("another-secret")).IssueSession(h.userID)

	for name, token := range map[string]string{
		"guest token":     guest,
		"resume token":    resume,
		"foreign session": foreign,
		"garbage":         "not-a-token",
	} {
		res, body := h.do("GET", "/v1/me", token, nil)
		if res.StatusCode != http.StatusUnauthorized {
			t.Errorf("%s was accepted: status %d", name, res.StatusCode)
		}
		expectError(t, res, body, http.StatusUnauthorized, codeUnauthorized)
	}
}

func TestValidTokenReachesTheHandler(t *testing.T) {
	h := newHarness(t, newFakeStore())

	res, body := h.do("GET", "/v1/me", h.token, nil)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body %v)", res.StatusCode, body)
	}
	if !h.store.called("UserByID") {
		t.Error("the handler did not reach the store")
	}
	user := object(t, body, "user")
	if user["id"] != h.userID {
		t.Errorf("id = %v, want %q", user["id"], h.userID)
	}
}

// -------------------------------------------------------- persistence is off

func TestPersistenceDisabledOnEveryRoute(t *testing.T) {
	// db.Nop is what the server runs with when there is no DATABASE_URL. Every
	// /v1 route must answer 503 persistence_disabled — including the
	// unauthenticated one, and without the process refusing to serve.
	h := newHarness(t, db.Nop{})
	token, _ := h.signer.IssueSession("018f3a2b-user-0001")

	for _, route := range []struct {
		method, path string
	}{
		{"POST", "/v1/auth/device"},
		{"POST", "/v1/auth/refresh"},
		{"POST", "/v1/auth/link"},
		{"GET", "/v1/me"},
		{"PATCH", "/v1/me"},
		{"GET", "/v1/me/stats"},
		{"GET", "/v1/me/games"},
		{"GET", "/v1/games/018f3a2b"},
		{"POST", "/v1/games"},
	} {
		res, body := h.do(route.method, route.path, token, map[string]any{})
		expectError(t, res, body, http.StatusServiceUnavailable, codePersistenceDisabled)
	}
}

func TestErrDisabledFromTheStoreIsAlsoA503(t *testing.T) {
	// Belt and braces: a store that reports itself enabled but answers
	// ErrDisabled per call must produce the same response, because the store can
	// be swapped for one that only discovers the problem when it is used.
	store := newFakeStore()
	store.failWith = db.ErrDisabled
	store.failCalls["Stats"] = true

	h := newHarness(t, store)
	res, body := h.do("GET", "/v1/me/stats", h.token, nil)
	expectError(t, res, body, http.StatusServiceUnavailable, codePersistenceDisabled)
}

// ------------------------------------------------------------ device sign-in

func TestDeviceIDValidation(t *testing.T) {
	store := newFakeStore()
	h := newHarness(t, store)

	bad := map[string]string{
		"empty":          "",
		"too short":      "abc",
		"too long":       strings.Repeat("a", 129),
		"a space":        "device id here",
		"a slash":        "device/id/here",
		"a dot":          "device.id.here",
		"sql injection":  "abcdefgh'; drop table users; --",
		"a null byte":    "abcdefgh\x00",
		"unicode":        "abcdefghé",
		"percent escape": "abcdefgh%2F",
	}
	for name, id := range bad {
		res, body := h.do("POST", "/v1/auth/device", "", map[string]any{
			"deviceId": id, "displayName": "Nabin",
		})
		if res.StatusCode != http.StatusBadRequest {
			t.Errorf("%s (%q) was accepted: status %d", name, id, res.StatusCode)
			continue
		}
		expectError(t, res, body, http.StatusBadRequest, codeBadRequest)
	}

	// The point of validating here is that nothing hostile reaches the database.
	if store.called("ResolveIdentity") {
		t.Error("an invalid device id reached the store")
	}

	for name, id := range map[string]string{
		"uuid v4":      "b1e9c0d2-4f7a-4c3e-9a10-4f2c8d5e6b71",
		"minimum size": "abcdefgh",
		"underscores":  "device_id_with_underscores",
		"maximum size": strings.Repeat("a", 128),
	} {
		res, body := h.do("POST", "/v1/auth/device", "", map[string]any{
			"deviceId": id, "displayName": "Nabin", "platform": "android",
		})
		if res.StatusCode != http.StatusOK {
			t.Errorf("%s (%q) was rejected: status %d, body %v", name, id, res.StatusCode, body)
		}
	}
}

func TestDeviceSignInIsIdempotent(t *testing.T) {
	h := newHarness(t, newFakeStore())
	const device = "b1e9c0d2-4f7a-4c3e-9a10-4f2c8d5e6b71"

	_, first := h.do("POST", "/v1/auth/device", "", map[string]any{
		"deviceId": device, "displayName": "Nabin",
	})
	_, second := h.do("POST", "/v1/auth/device", "", map[string]any{
		"deviceId": device, "displayName": "Somebody Else",
	})

	firstUser := object(t, first, "user")
	secondUser := object(t, second, "user")
	if firstUser["id"] != secondUser["id"] {
		t.Fatalf("the same device produced two accounts: %v and %v", firstUser["id"], secondUser["id"])
	}
	// displayName applies at creation only; renaming is PATCH /v1/me.
	if secondUser["displayName"] != "Nabin" {
		t.Errorf("displayName = %v, want the name the account was created with", secondUser["displayName"])
	}

	// The token that comes back must be a session, and must name that account.
	token, _ := second["token"].(string)
	got, err := h.signer.VerifySession(token)
	if err != nil {
		t.Fatalf("the issued token is not a valid session: %v", err)
	}
	if got != secondUser["id"] {
		t.Errorf("token subject = %q, want %v", got, secondUser["id"])
	}
}

func TestLinkIsReservedButShaped(t *testing.T) {
	h := newHarness(t, newFakeStore())

	res, body := h.do("POST", "/v1/auth/link", h.token, map[string]any{
		"idToken": "a-firebase-id-token",
	})
	expectError(t, res, body, http.StatusNotImplemented, codeNotImplemented)

	// Nothing may have been linked while the endpoint is reserved.
	if h.store.called("LinkIdentity") {
		t.Error("the reserved link endpoint touched the store")
	}
}

func TestRestoreMovesThisInstallToTheSavedAccount(t *testing.T) {
	store := newFakeStore()
	h := newHarness(t, store)
	// The harness seeds the *current* install as a guest ("seed-device-id");
	// a second, older install owns the account whose id the player saved.
	var saved db.User
	{
		var err error
		saved, err = store.ResolveIdentity(context.Background(),
			db.ProviderDevice, "saved-device-id", "Nabin")
		if err != nil {
			t.Fatal(err)
		}
	}

	res, body := h.do("POST", "/v1/auth/restore", h.token, map[string]any{
		"accountId": saved.ID,
	})
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body %v)", res.StatusCode, body)
	}

	// The response is a session for the restored account.
	restored := object(t, body, "user")
	if restored["id"] != saved.ID {
		t.Errorf("restored user id = %v, want the saved account %s", restored["id"], saved.ID)
	}
	if restored["displayName"] != saved.DisplayName {
		t.Errorf("displayName = %v, want the saved account's name", restored["displayName"])
	}
	token, _ := body["token"].(string)
	if subject, err := h.signer.VerifySession(token); err != nil || subject != saved.ID {
		t.Errorf("issued token must name the restored account; subject = %q, err = %v", subject, err)
	}

	// The identity truly moved: the next device auth with *this* install's
	// device id (the one the harness seeded) resolves to the saved account.
	seeded, err := store.ResolveIdentity(context.Background(),
		db.ProviderDevice, "seed-device-id", "somebody-else")
	if err != nil {
		t.Fatal(err)
	}
	if seeded.ID != saved.ID {
		t.Errorf("this install's device id resolves to %s, want the restored account %s", seeded.ID, saved.ID)
	}
}

func TestRestoreValidationAndGuardrails(t *testing.T) {
	store := newFakeStore()
	h := newHarness(t, store)
	saved, err := store.ResolveIdentity(context.Background(), db.ProviderDevice, "saved-device-id", "Nabin")
	if err != nil {
		t.Fatal(err)
	}

	// Malformed ids are a 400 that never reaches the store.
	for name, id := range map[string]string{
		"empty":      "",
		"not a uuid": "not-an-account-id-at-all",
		"spaces":     "018f3a2b 7c41 7b3e 9a10 4f2c8d5e6b71",
	} {
		res, _ := h.do("POST", "/v1/auth/restore", h.token, map[string]any{"accountId": id})
		if res.StatusCode != http.StatusBadRequest {
			t.Errorf("%s: status = %d, want 400", name, res.StatusCode)
		}
	}
	if store.called("RestoreAccount") {
		t.Error("a malformed account id reached the store")
	}

	// An unknown (but well-formed) id is a 404.
	res, body := h.do("POST", "/v1/auth/restore", h.token, map[string]any{
		"accountId": "00000000-0000-0000-0000-000000000000",
	})
	expectError(t, res, body, http.StatusNotFound, codeNotFound)

	// The endpoint is private: no token, no restore.
	res, body = h.do("POST", "/v1/auth/restore", "", map[string]any{"accountId": saved.ID})
	expectError(t, res, body, http.StatusUnauthorized, codeUnauthorized)
}

func TestRestoreRefusesToRunFromOrIntoSignedInAccount(t *testing.T) {
	store := newFakeStore()
	// Build the accounts by hand so "signed in" means something the fake can
	// actually see: a linked (non-guest) account, and a bare guest to restore.
	signedIn := db.User{ID: "018f3a2b-1111-1111-1111-111111111111", DisplayName: "Signed In", IsGuest: false}
	guest := db.User{ID: "018f3a2b-2222-2222-2222-222222222222", DisplayName: "Guest", IsGuest: true}
	store.mu.Lock()
	store.users[signedIn.ID] = signedIn
	store.users[guest.ID] = guest
	store.identities[signedIn.ID] = []db.Identity{{
		UserID: signedIn.ID, Provider: db.ProviderGoogle, Subject: "g:1",
	}}
	store.identities[guest.ID] = []db.Identity{{
		UserID: guest.ID, Provider: db.ProviderDevice, Subject: "second-device",
	}}
	store.subjects["google|g:1"] = signedIn.ID
	store.subjects["device|second-device"] = guest.ID
	store.mu.Unlock()

	h := newHarness(t, store)
	signedInToken, _ := h.signer.IssueSession(signedIn.ID)
	guestToken, _ := h.signer.IssueSession(guest.ID)

	// Restoring *from* a signed-in account is refused, even into a guest.
	res, body := h.do("POST", "/v1/auth/restore", signedInToken, map[string]any{"accountId": guest.ID})
	expectError(t, res, body, http.StatusBadRequest, codeBadRequest)

	// And restoring *into* a signed-in account is refused — case as a 404 so
	// the server never confirms a linked account exists by its id.
	res, body = h.do("POST", "/v1/auth/restore", guestToken, map[string]any{"accountId": signedIn.ID})
	expectError(t, res, body, http.StatusNotFound, codeNotFound)
}

func TestRestoreWithHistoryOffersMergeOrDiscard(t *testing.T) {
	store := newFakeStore()
	h := newHarness(t, store)
	saved, err := store.ResolveIdentity(context.Background(), db.ProviderDevice, "saved-device-id", "Nabin")
	if err != nil {
		t.Fatal(err)
	}
	// Record one saved-account game and two for the current install, so the
	// restore leaves real history behind to be decided about.
	recordFor := func(user string) {
		t.Helper()
		rec := validUpload()
		rec["seats"] = []any{map[string]any{
			"seat": 0, "displayName": "someone", "isBot": false, "finalScore": 42, "userId": user,
		}}
		raw, err := json.Marshal(rec)
		if err != nil {
			t.Fatal(err)
		}
		var gameRec db.GameRecord
		if err := json.Unmarshal(raw, &gameRec); err != nil {
			t.Fatal(err)
		}
		if _, _, err := store.RecordGame(context.Background(), gameRec); err != nil {
			t.Fatal(err)
		}
	}
	recordFor(saved.ID)
	recordFor(h.userID)
	recordFor(h.userID)

	res, body := h.do("POST", "/v1/auth/restore", h.token, map[string]any{"accountId": saved.ID})
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body %v)", res.StatusCode, body)
	}

	// The abandoned install is reported, and the client now holds the saved
	// account's token — the same session body as any login.
	abandoned := object(t, body, "abandoned")
	if abandoned["accountId"] != h.userID {
		t.Errorf("abandoned.accountId = %v, want the replaced install %s", abandoned["accountId"], h.userID)
	}
	if games, _ := abandoned["games"].(float64); games != 2 {
		t.Errorf("abandoned.games = %v, want 2", abandoned["games"])
	}
	restoredUser := object(t, body, "user")
	if restoredUser["id"] != saved.ID {
		t.Errorf("restored user = %v, want %s", restoredUser["id"], saved.ID)
	}
	token, _ := body["token"].(string)

	// Neither offer is valid for something that is not an abandoned guest.
	res, body = h.do("POST", "/v1/me/merge/00000000-0000-0000-0000-000000000000", token, nil)
	expectError(t, res, body, http.StatusNotFound, codeNotFound)

	// Merge folds the abandoned install's history into the restored account.
	res, body = h.do("POST", "/v1/me/merge/"+h.userID, token, nil)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("merge status = %d, want 200 (body %v)", res.StatusCode, body)
	}
	if merged := object(t, body, "user"); merged["id"] != saved.ID {
		t.Errorf("merge returned user %v, want %s", merged["id"], saved.ID)
	}

	// The history really moved: the abandoned account is consumed, its games
	// now sit on the survivor's seat count.
	store.mu.Lock()
	games := store.gamesByUser[saved.ID]
	store.mu.Unlock()
	if games != 3 {
		t.Errorf("survivor owns %d games after merge, want 3", games)
	}

	// What was offered is now consumed.
	res, body = h.do("POST", "/v1/me/merge/"+h.userID, token, nil)
	expectError(t, res, body, http.StatusNotFound, codeNotFound)
}

func TestDiscardAbandonedDeletesHistoryDecision(t *testing.T) {
	store := newFakeStore()
	h := newHarness(t, store)
	saved, err := store.ResolveIdentity(context.Background(), db.ProviderDevice, "saved-device-id", "Nabin")
	if err != nil {
		t.Fatal(err)
	}
	recordFor := func(user string) {
		t.Helper()
		rec := validUpload()
		rec["seats"] = []any{map[string]any{
			"seat": 0, "displayName": "someone", "isBot": false, "finalScore": 42, "userId": user,
		}}
		raw, err := json.Marshal(rec)
		if err != nil {
			t.Fatal(err)
		}
		var gameRec db.GameRecord
		if err := json.Unmarshal(raw, &gameRec); err != nil {
			t.Fatal(err)
		}
		if _, _, err := store.RecordGame(context.Background(), gameRec); err != nil {
			t.Fatal(err)
		}
	}
	recordFor(h.userID)

	_, body := h.do("POST", "/v1/auth/restore", h.token, map[string]any{"accountId": saved.ID})
	token, _ := body["token"].(string)

	// The account id alone is never discarded — it must be the one offered.
	// A well-formed but unknown id is a 404.
	res, body := h.do("DELETE", "/v1/me/abandoned/00000000-0000-0000-0000-000000000000", token, nil)
	expectError(t, res, body, http.StatusNotFound, codeNotFound)

	// Malformed ids are a 400 that never reach the store.
	res, _ = h.do("DELETE", "/v1/me/abandoned/not-an-id", token, nil)
	if res.StatusCode != http.StatusBadRequest {
		t.Errorf("malformed id: status = %d, want 400", res.StatusCode)
	}

	// Discarding the offered account is a clean 204.
	res, body = h.do("DELETE", "/v1/me/abandoned/"+h.userID, token, nil)
	if res.StatusCode != http.StatusNoContent {
		t.Fatalf("delete status = %d, want 204 (body %v)", res.StatusCode, body)
	}
	store.mu.Lock()
	_, stillThere := store.users[h.userID]
	store.mu.Unlock()
	if stillThere {
		t.Error("discarded account still exists")
	}

	// And the offer is consumed.
	res, body = h.do("DELETE", "/v1/me/abandoned/"+h.userID, token, nil)
	if res.StatusCode != http.StatusNotFound {
		t.Errorf("second discard: status = %d, want 404", res.StatusCode)
	}
}

// -------------------------------------------------------------------- games

// validUpload is the payload from the POST /v1/games example in docs/API.md.
func validUpload() map[string]any {
	return map[string]any{
		"clientGameId": "5b0e1c2d-4f7a-4c3e-9a10-4f2c8d5e6b71",
		"mode":         "bots",
		"completed":    true,
		"handsTotal":   5,
		"startedAt":    "2026-08-10T09:10:00Z",
		"finishedAt":   "2026-08-10T09:34:11Z",
		"seats": []any{
			map[string]any{
				"seat": 0, "isYou": false, "displayName": "Amit", "isBot": true,
				"botDifficulty": "normal", "finalScore": 6.1, "place": 3,
				"totalBid": 12, "totalTricks": 11, "handsMade": 3,
			},
			map[string]any{
				"seat": 2, "isYou": true, "displayName": "Nabin", "isBot": false,
				"finalScore": 13.2, "place": 1,
				"totalBid": 14, "totalTricks": 15, "handsMade": 5,
			},
		},
		"hands": []any{
			map[string]any{
				"handIndex": 0, "seat": 0, "bid": 3, "tricksWon": 3,
				"scoreDelta": 3.0, "runningTotal": 3.0,
			},
		},
	}
}

func TestUploadBindsYourSeatAndOnlyYourSeat(t *testing.T) {
	store := newFakeStore()
	h := newHarness(t, store)

	res, body := h.do("POST", "/v1/games", h.token, validUpload())
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body %v)", res.StatusCode, body)
	}

	if len(store.recorded) != 1 {
		t.Fatalf("recorded %d games, want 1", len(store.recorded))
	}
	rec := store.recorded[0]

	if rec.Source != db.SourceClient {
		t.Errorf("source = %q, want %q — a device computed this result", rec.Source, db.SourceClient)
	}
	if rec.Mode != db.ModeBots {
		t.Errorf("mode = %q, want bots", rec.Mode)
	}
	if rec.ClientGameID == "" {
		t.Error("the idempotency key was dropped; a retry would double-count")
	}

	for _, seat := range rec.Seats {
		switch seat.Seat {
		case 2:
			if seat.UserID != h.userID {
				t.Errorf("your seat has user %q, want %q", seat.UserID, h.userID)
			}
		default:
			if seat.UserID != "" {
				t.Errorf("seat %d was attributed to %q; every other seat must be null",
					seat.Seat, seat.UserID)
			}
		}
	}
}

// TestUploadReportsDuplicate covers the idempotency flag reaching the client.
// It is advisory — the upload queue drops on any 2xx — but a client that keeps
// re-sending a game it has already had a 2xx for is a bug in its drop logic,
// and this response is the only place that would ever surface.
func TestUploadReportsDuplicate(t *testing.T) {
	for _, duplicate := range []bool{false, true} {
		store := newFakeStore()
		store.nextDuplicate = duplicate
		h := newHarness(t, store)

		res, body := h.do("POST", "/v1/games", h.token, validUpload())
		if res.StatusCode != http.StatusOK {
			t.Fatalf("status = %d, want 200 — a repeat upload is success, not an error", res.StatusCode)
		}
		if got := body["duplicate"]; got != duplicate {
			t.Errorf("duplicate = %v, want %v", got, duplicate)
		}
		if body["gameId"] != store.nextGame {
			t.Errorf("gameId = %v, want the original id %q", body["gameId"], store.nextGame)
		}
	}
}

func TestUploadSeatOwnershipRules(t *testing.T) {
	// A client controls this payload entirely, so these are the rules that stop
	// it writing history onto somebody else's account.
	cases := map[string]func(m map[string]any){
		"two seats claim to be you": func(m map[string]any) {
			seats := m["seats"].([]any)
			seats[0].(map[string]any)["isYou"] = true
		},
		"no seat is you": func(m map[string]any) {
			for _, s := range m["seats"].([]any) {
				s.(map[string]any)["isYou"] = false
			}
		},
		"a userId on somebody else's seat": func(m map[string]any) {
			seats := m["seats"].([]any)
			seats[0].(map[string]any)["userId"] = "018f3a2b-user-9999"
		},
		"a userId on your own seat": func(m map[string]any) {
			seats := m["seats"].([]any)
			seats[1].(map[string]any)["userId"] = "018f3a2b-user-0001"
		},
	}

	for name, mangle := range cases {
		t.Run(name, func(t *testing.T) {
			store := newFakeStore()
			h := newHarness(t, store)

			payload := validUpload()
			mangle(payload)

			res, body := h.do("POST", "/v1/games", h.token, payload)
			expectError(t, res, body, http.StatusBadRequest, codeBadRequest)

			if len(store.recorded) != 0 {
				t.Fatalf("a rejected payload was still recorded: %+v", store.recorded)
			}
		})
	}
}

func TestUploadValidation(t *testing.T) {
	cases := map[string]func(m map[string]any){
		"a server-played mode":    func(m map[string]any) { m["mode"] = "online" },
		"a private mode":          func(m map[string]any) { m["mode"] = "private" },
		"an unknown mode":         func(m map[string]any) { m["mode"] = "solitaire" },
		"no clientGameId":         func(m map[string]any) { delete(m, "clientGameId") },
		"handsTotal of zero":      func(m map[string]any) { m["handsTotal"] = 0 },
		"a negative handsTotal":   func(m map[string]any) { m["handsTotal"] = -5 },
		"a seat off the table":    func(m map[string]any) { m["seats"].([]any)[0].(map[string]any)["seat"] = 7 },
		"a negative seat":         func(m map[string]any) { m["seats"].([]any)[0].(map[string]any)["seat"] = -1 },
		"no seats at all":         func(m map[string]any) { m["seats"] = []any{} },
		"a hand outside the game": func(m map[string]any) { m["hands"].([]any)[0].(map[string]any)["handIndex"] = 9 },
		"a hand at a bad seat":    func(m map[string]any) { m["hands"].([]any)[0].(map[string]any)["seat"] = 4 },
		"a malformed startedAt":   func(m map[string]any) { m["startedAt"] = "last tuesday" },
		"duplicate seat numbers": func(m map[string]any) {
			seats := m["seats"].([]any)
			seats[0].(map[string]any)["seat"] = 2
		},
		"more hands than handsTotal allows": func(m map[string]any) {
			m["handsTotal"] = 1
			hands := make([]any, 0, 5)
			for i := 0; i < 5; i++ {
				hands = append(hands, map[string]any{
					"handIndex": 0, "seat": 0, "bid": 1, "tricksWon": 1,
					"scoreDelta": 1.0, "runningTotal": 1.0,
				})
			}
			m["hands"] = hands
		},
	}

	for name, mangle := range cases {
		t.Run(name, func(t *testing.T) {
			store := newFakeStore()
			h := newHarness(t, store)

			payload := validUpload()
			mangle(payload)

			res, body := h.do("POST", "/v1/games", h.token, payload)
			expectError(t, res, body, http.StatusBadRequest, codeBadRequest)
			if store.called("RecordGame") {
				t.Error("an invalid upload reached the store")
			}
		})
	}
}

func TestUploadBodyIsCapped(t *testing.T) {
	store := newFakeStore()
	h := newHarness(t, store)

	payload := validUpload()
	payload["clientGameId"] = strings.Repeat("a", 200_000)

	res, body := h.do("POST", "/v1/games", h.token, payload)
	expectError(t, res, body, http.StatusBadRequest, codeBadRequest)
	if store.called("RecordGame") {
		t.Error("an oversized body reached the store")
	}
}

// ------------------------------------------------------------------ history

func TestHistoryQueryHandling(t *testing.T) {
	store := newFakeStore()
	store.page = db.HistoryPage{NextCursor: "eyJ0IjoxNzU"}
	h := newHarness(t, store)

	for _, tc := range []struct {
		query string
		want  int
	}{
		{"", 20},
		{"?limit=5", 5},
		{"?limit=50", 50},
		{"?limit=500", 50}, // clamped, not refused
		{"?limit=0", 1},
		{"?limit=-3", 1},
	} {
		res, body := h.do("GET", "/v1/me/games"+tc.query, h.token, nil)
		if res.StatusCode != http.StatusOK {
			t.Fatalf("%q: status %d (%v)", tc.query, res.StatusCode, body)
		}
		if store.lastQuery.Limit != tc.want {
			t.Errorf("%q: limit = %d, want %d", tc.query, store.lastQuery.Limit, tc.want)
		}
	}

	// A limit that is not a number is a bug in the caller, not a clamp.
	res, body := h.do("GET", "/v1/me/games?limit=twenty", h.token, nil)
	expectError(t, res, body, http.StatusBadRequest, codeBadRequest)

	// Modes are validated against the four the schema accepts.
	for _, mode := range []string{"bots", "private", "online", "lan"} {
		res, _ := h.do("GET", "/v1/me/games?mode="+mode, h.token, nil)
		if res.StatusCode != http.StatusOK {
			t.Errorf("mode=%s was rejected: %d", mode, res.StatusCode)
		}
		if string(store.lastQuery.Mode) != mode {
			t.Errorf("mode = %q, want %q", store.lastQuery.Mode, mode)
		}
	}
	res, body = h.do("GET", "/v1/me/games?mode=chess", h.token, nil)
	expectError(t, res, body, http.StatusBadRequest, codeBadRequest)

	// The cursor is opaque and goes through untouched.
	if _, _ = h.do("GET", "/v1/me/games?cursor=eyJ0IjoxNzU%3D", h.token, nil); store.lastQuery.Cursor != "eyJ0IjoxNzU=" {
		t.Errorf("cursor = %q, want it passed through verbatim", store.lastQuery.Cursor)
	}
	// The caller may only ever read their own history.
	if store.lastQuery.UserID != h.userID {
		t.Errorf("history was queried for %q, want %q", store.lastQuery.UserID, h.userID)
	}
}

func TestGameNotFoundIsNotFound(t *testing.T) {
	store := newFakeStore()
	store.failWith = db.ErrNotFound
	store.failCalls["Game"] = true

	h := newHarness(t, store)
	res, body := h.do("GET", "/v1/games/018f3a2b-somebody-elses-game", h.token, nil)
	expectError(t, res, body, http.StatusNotFound, codeNotFound)
}

// -------------------------------------------------------------------- stats

func TestStatsAlwaysReturnsEveryScopeInOrder(t *testing.T) {
	// A brand-new account has no rows at all, and the profile tab still has to
	// render five scope cards without a null check anywhere.
	h := newHarness(t, newFakeStore())

	res, body := h.do("GET", "/v1/me/stats", h.token, nil)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status = %d (%v)", res.StatusCode, body)
	}

	scopes := array(t, body, "scopes")
	if len(scopes) != len(db.AllScopes) {
		t.Fatalf("got %d scopes, want %d", len(scopes), len(db.AllScopes))
	}
	for i, want := range db.AllScopes {
		got := scopes[i].(map[string]any)
		if got["scope"] != want {
			t.Errorf("scope %d = %v, want %q", i, got["scope"], want)
		}
		if got["gamesPlayed"] != float64(0) {
			t.Errorf("a never-played scope reports %v games", got["gamesPlayed"])
		}
		if got["lastPlayedAt"] != nil {
			t.Errorf("a never-played scope reports lastPlayedAt %v, want null", got["lastPlayedAt"])
		}
	}
}

// ------------------------------------------------------------- rate limiting

func TestRateLimiting(t *testing.T) {
	cfg := config.Config{APIRatePerMinute: 3}
	signer := auth.NewSigner([]byte("test-secret"))
	store := newFakeStore()
	user, _ := store.ResolveIdentity(context.Background(), db.ProviderDevice, "rate-limit-device", "Nabin")
	token, _ := signer.IssueSession(user.ID)

	mux := http.NewServeMux()
	NewServer(cfg, store, signer, slog.New(slog.NewTextHandler(io.Discard, nil))).Handler(mux)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	h := &harness{t: t, server: srv, store: store, signer: signer, token: token, userID: user.ID}

	var limited bool
	for i := 0; i < 6; i++ {
		res, body := h.do("GET", "/v1/me", token, nil)
		if res.StatusCode == http.StatusTooManyRequests {
			expectError(t, res, body, http.StatusTooManyRequests, codeRateLimited)
			limited = true
			break
		}
	}
	if !limited {
		t.Fatal("a burst well past the limit was never refused")
	}

	// The limit is per account: another player is unaffected by this one's burst.
	other, _ := store.ResolveIdentity(context.Background(), db.ProviderDevice, "another-device-id", "Riya")
	otherToken, _ := signer.IssueSession(other.ID)
	if res, body := h.do("GET", "/v1/me", otherToken, nil); res.StatusCode != http.StatusOK {
		t.Fatalf("one player's burst limited another: status %d (%v)", res.StatusCode, body)
	}
}

// ------------------------------------------------------------------- panics

func TestPanicIsContainedAndReportedAsInternal(t *testing.T) {
	// A handler panic must cost one response, not the process — this binary is
	// also holding every live table in memory.
	store := newFakeStore()
	store.panicOn = "Stats"

	h := newHarness(t, store)
	res, body := h.do("GET", "/v1/me/stats", h.token, nil)
	expectError(t, res, body, http.StatusInternalServerError, codeInternal)

	// The server is still serving.
	if res, _ := h.do("GET", "/v1/me", h.token, nil); res.StatusCode != http.StatusOK {
		t.Fatalf("the server stopped working after a panic: status %d", res.StatusCode)
	}
}

// -------------------------------------------------- docs/API.md conformance
//
// The field lists below are transcribed from docs/API.md. A Flutter client is
// decoding exactly these names, so a rename on either side has to fail a test
// here before it can reach two codebases at once.

var (
	userFields = []string{
		"id", "displayName", "isGuest", "avatarId", "country",
		"createdAt", "lastSeenAt", "identities",
	}
	identityFields    = []string{"provider", "linkedAt"}
	gameSummaryFields = []string{
		"id", "mode", "roomCode", "completed", "startedAt", "finishedAt",
		"handsTotal", "you", "players",
	}
	youFields    = []string{"seat", "finalScore", "place", "totalBid", "totalTricks"}
	playerFields = []string{"seat", "userId", "displayName", "isBot", "finalScore", "place"}
	handFields   = []string{"handIndex", "seat", "bid", "tricksWon", "scoreDelta", "runningTotal"}
	statsFields  = []string{
		"scope", "gamesPlayed", "gamesCompleted", "gamesWon", "gamesLost",
		"bestPlace", "handsPlayed", "totalBid", "bidsMade", "bidsFailed",
		"highestBid", "totalTricks", "totalScore", "highestGameScore",
		"lowestGameScore", "highestHandScore", "currentWinStreak",
		"bestWinStreak", "lastPlayedAt",
	}
)

// sampleGame is the gameSummary example from docs/API.md, as db types.
func sampleGame() db.GameSummary {
	return db.GameSummary{
		GameID:      "018f3a2b-7c41-7b3e-9a10-4f2c8d5e6b71",
		Mode:        db.ModeOnline,
		RoomCode:    "QUICKPLAY",
		Completed:   true,
		StartedAt:   time.Date(2026, 8, 10, 9, 10, 0, 0, time.UTC),
		FinishedAt:  time.Date(2026, 8, 10, 9, 34, 11, 0, time.UTC),
		HandsTotal:  5,
		Seat:        2,
		FinalScore:  13.2,
		Place:       1,
		TotalBid:    14,
		TotalTricks: 15,
		Players: []db.GamePlayer{
			{Seat: 0, DisplayName: "Amit", IsBot: true, FinalScore: 6.1, Place: 3},
			{Seat: 1, DisplayName: "Riya", IsBot: true, FinalScore: 8.0, Place: 2},
			{Seat: 2, UserID: "018f3a2b-user-0001", DisplayName: "Nabin", FinalScore: 13.2, Place: 1},
			{Seat: 3, DisplayName: "Sujan", IsBot: true, FinalScore: -2.0, Place: 4},
		},
	}
}

func TestAuthResponseMatchesTheDocument(t *testing.T) {
	h := newHarness(t, newFakeStore())

	_, body := h.do("POST", "/v1/auth/device", "", map[string]any{
		"deviceId": "b1e9c0d2-4f7a-4c3e-9a10-4f2c8d5e6b71", "displayName": "Nabin",
	})
	sameKeys(t, "auth response", body, []string{"token", "expiresAt", "user"})

	user := object(t, body, "user")
	sameKeys(t, "user", user, userFields)

	// avatarId and country are documented as present-and-empty, not absent.
	if user["avatarId"] != "" || user["country"] != "" {
		t.Errorf("avatarId/country = %v/%v, want empty strings", user["avatarId"], user["country"])
	}

	identities := array(t, user, "identities")
	if len(identities) != 1 {
		t.Fatalf("got %d identities, want 1", len(identities))
	}
	identity := identities[0].(map[string]any)
	sameKeys(t, "identity", identity, identityFields)
	if identity["provider"] != "device" {
		t.Errorf("provider = %v, want device", identity["provider"])
	}

	// Timestamps are RFC 3339 in UTC, seconds precision — not Go's default
	// nanosecond-and-offset rendering.
	for _, field := range []string{"expiresAt"} {
		raw, _ := body[field].(string)
		if _, err := time.Parse(time.RFC3339, raw); err != nil {
			t.Errorf("%s = %q is not RFC 3339: %v", field, raw, err)
		}
		if !strings.HasSuffix(raw, "Z") {
			t.Errorf("%s = %q is not UTC", field, raw)
		}
	}
	if got := user["createdAt"]; got != "2026-08-01T12:00:00Z" {
		t.Errorf("createdAt = %v, want an RFC 3339 UTC string", got)
	}

	// The expiry the client is told must be the expiry that was signed.
	expiresAt, _ := time.Parse(time.RFC3339, body["expiresAt"].(string))
	if d := time.Until(expiresAt) - auth.SessionTTL; d > time.Minute || d < -time.Minute {
		t.Errorf("expiresAt is %v away, want ~%v", time.Until(expiresAt), auth.SessionTTL)
	}
}

func TestHistoryResponseMatchesTheDocument(t *testing.T) {
	store := newFakeStore()
	store.page = db.HistoryPage{Games: []db.GameSummary{sampleGame()}, NextCursor: "eyJ0IjoxNzU"}
	h := newHarness(t, store)

	_, body := h.do("GET", "/v1/me/games", h.token, nil)
	sameKeys(t, "history response", body, []string{"games", "nextCursor"})

	games := array(t, body, "games")
	if len(games) != 1 {
		t.Fatalf("got %d games, want 1", len(games))
	}
	game := games[0].(map[string]any)
	sameKeys(t, "gameSummary", game, gameSummaryFields)
	sameKeys(t, "gameSummary.you", object(t, game, "you"), youFields)

	players := array(t, game, "players")
	if len(players) != 4 {
		t.Fatalf("got %d players, want 4", len(players))
	}
	for _, raw := range players {
		sameKeys(t, "gameSummary.players[]", raw.(map[string]any), playerFields)
	}

	// A bot's userId is null, not "". A human's is the account id.
	if got := players[0].(map[string]any)["userId"]; got != nil {
		t.Errorf("a bot's userId = %v, want null", got)
	}
	if got := players[2].(map[string]any)["userId"]; got != "018f3a2b-user-0001" {
		t.Errorf("a human's userId = %v, want the account id", got)
	}

	// Scores are numbers with at most two decimals, and survive the round trip.
	if got := game["you"].(map[string]any)["finalScore"]; got != 13.2 {
		t.Errorf("finalScore = %v, want 13.2", got)
	}
	if got := players[3].(map[string]any)["finalScore"]; got != -2.0 {
		t.Errorf("a negative score = %v, want -2", got)
	}
	if game["startedAt"] != "2026-08-10T09:10:00Z" || game["finishedAt"] != "2026-08-10T09:34:11Z" {
		t.Errorf("timestamps = %v / %v, want RFC 3339 UTC", game["startedAt"], game["finishedAt"])
	}
	if body["nextCursor"] != "eyJ0IjoxNzU" {
		t.Errorf("nextCursor = %v, want it echoed from the store", body["nextCursor"])
	}
}

func TestGameDetailResponseMatchesTheDocument(t *testing.T) {
	store := newFakeStore()
	store.detail = db.GameDetail{
		GameSummary: sampleGame(),
		Hands: []db.HandRecord{
			{HandIndex: 0, Seat: 0, Bid: 3, TricksWon: 3, ScoreDelta: 3.0, RunningTotal: 3.0},
			{HandIndex: 0, Seat: 1, Bid: 4, TricksWon: 2, ScoreDelta: -4.0, RunningTotal: -4.0},
		},
	}
	h := newHarness(t, store)

	_, body := h.do("GET", "/v1/games/018f3a2b-7c41-7b3e-9a10-4f2c8d5e6b71", h.token, nil)
	sameKeys(t, "game response", body, []string{"game", "hands"})
	sameKeys(t, "gameSummary", object(t, body, "game"), gameSummaryFields)

	hands := array(t, body, "hands")
	if len(hands) != 2 {
		t.Fatalf("got %d hands, want 2", len(hands))
	}
	for _, raw := range hands {
		sameKeys(t, "hands[]", raw.(map[string]any), handFields)
	}
	if got := hands[1].(map[string]any)["scoreDelta"]; got != -4.0 {
		t.Errorf("scoreDelta = %v, want -4", got)
	}
}

func TestStatsResponseMatchesTheDocument(t *testing.T) {
	store := newFakeStore()
	store.stats = []db.Stats{{
		Scope: "online", GamesPlayed: 42, GamesCompleted: 40, GamesWon: 17,
		GamesLost: 23, BestPlace: 1, HandsPlayed: 200, TotalBid: 560,
		BidsMade: 141, BidsFailed: 59, HighestBid: 8, TotalTricks: 602,
		TotalScore: 318.4, HighestGameScore: 21.7, LowestGameScore: -9.0,
		HighestHandScore: 8.3, CurrentWinStreak: 2, BestWinStreak: 5,
		LastPlayedAt: time.Date(2026, 8, 10, 9, 34, 11, 0, time.UTC),
	}}
	h := newHarness(t, store)

	_, body := h.do("GET", "/v1/me/stats", h.token, nil)
	sameKeys(t, "stats response", body, []string{"scopes"})

	scopes := array(t, body, "scopes")
	for _, raw := range scopes {
		sameKeys(t, "stats", raw.(map[string]any), statsFields)
	}

	// db.AllScopes puts online second.
	online := scopes[1].(map[string]any)
	if online["scope"] != "online" {
		t.Fatalf("scope 1 = %v, want online", online["scope"])
	}
	for field, want := range map[string]any{
		"gamesPlayed": 42.0, "gamesWon": 17.0, "highestBid": 8.0,
		"totalScore": 318.4, "highestHandScore": 8.3, "lowestGameScore": -9.0,
		"bestWinStreak": 5.0, "lastPlayedAt": "2026-08-10T09:34:11Z",
	} {
		if online[field] != want {
			t.Errorf("%s = %v (%T), want %v", field, online[field], online[field], want)
		}
	}

	// Derived figures are the client's job; sending them would let the two
	// disagree.
	for _, derived := range []string{"winRate", "averageScore", "bidAccuracy"} {
		if _, present := online[derived]; present {
			t.Errorf("%s is derived on the client and must not be sent", derived)
		}
	}
}

func TestUploadResponseMatchesTheDocument(t *testing.T) {
	h := newHarness(t, newFakeStore())

	_, body := h.do("POST", "/v1/games", h.token, validUpload())
	sameKeys(t, "upload response", body, []string{"gameId", "duplicate"})
	if body["gameId"] != "018f3a2b-0000-0000-0000-00000000game" {
		t.Errorf("gameId = %v, want the id the store returned", body["gameId"])
	}
	if _, ok := body["duplicate"].(bool); !ok {
		t.Errorf("duplicate = %v, want a boolean", body["duplicate"])
	}
}

func TestPatchMeResponseMatchesTheDocument(t *testing.T) {
	h := newHarness(t, newFakeStore())

	res, body := h.do("PATCH", "/v1/me", h.token, map[string]any{
		"displayName": "  Nabin B  ",
	})
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status = %d (%v)", res.StatusCode, body)
	}
	sameKeys(t, "me response", body, []string{"user"})
	user := object(t, body, "user")
	sameKeys(t, "user", user, userFields)

	// Sanitised exactly like a socket display name: control characters stripped
	// and trimmed.
	if user["displayName"] != "Nabin B" {
		t.Errorf("displayName = %q, want %q", user["displayName"], "Nabin B")
	}

	// A PATCH with no displayName is malformed, not a rename to nothing.
	res, body = h.do("PATCH", "/v1/me", h.token, map[string]any{})
	expectError(t, res, body, http.StatusBadRequest, codeBadRequest)

	// So is a body that is not JSON at all.
	req, _ := http.NewRequest("PATCH", h.server.URL+"/v1/me", strings.NewReader("{not json"))
	req.Header.Set("Authorization", "Bearer "+h.token)
	raw, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Body.Close()
	if raw.StatusCode != http.StatusBadRequest {
		t.Errorf("malformed JSON returned %d, want 400", raw.StatusCode)
	}
}
