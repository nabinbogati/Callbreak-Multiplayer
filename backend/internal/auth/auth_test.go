package auth

import (
	"strings"
	"testing"
	"time"
)

func newSigner() *Signer { return NewSigner([]byte("test-secret")) }

func TestGuestRoundTrip(t *testing.T) {
	s := newSigner()
	id := NewGuestID()
	got, err := s.VerifyGuest(s.IssueGuest(id))
	if err != nil {
		t.Fatal(err)
	}
	if got != id {
		t.Fatalf("got %q, want %q", got, id)
	}
}

func TestResumeRoundTrip(t *testing.T) {
	s := newSigner()
	id := NewGuestID()
	seat, err := s.VerifyResume(s.IssueResume(id, "7QF2", 2))
	if err != nil {
		t.Fatal(err)
	}
	if seat.Player != id || seat.Room != "7QF2" || seat.Seat != 2 {
		t.Fatalf("got %+v", seat)
	}
}

func TestSessionRoundTrip(t *testing.T) {
	s := newSigner()
	const userID = "018f3a2b-7c41-7b3e-9a10-4f2c8d5e6b71"

	token, expires := s.IssueSession(userID)
	got, err := s.VerifySession(token)
	if err != nil {
		t.Fatal(err)
	}
	if got != userID {
		t.Fatalf("got %q, want %q", got, userID)
	}

	// The reported expiry must be the one that was signed, to the second: the
	// client shows it and decides when to refresh.
	if d := expires.Sub(time.Now().Add(SessionTTL)); d > time.Second || d < -time.Second {
		t.Fatalf("expiry %v is not ~SessionTTL away", expires)
	}
	if expires.Truncate(time.Second) != expires {
		t.Fatalf("expiry %v carries sub-second precision the token cannot", expires)
	}
}

func TestTokensAreNotInterchangeable(t *testing.T) {
	// No token kind may be spent as another. A guest token minting a seat would
	// let a player sit anywhere they can name; a guest or resume token passing as
	// a session would hand the bearer an account's whole history.
	s := newSigner()
	id := NewGuestID()
	session, _ := s.IssueSession("018f3a2b-7c41-7b3e-9a10-4f2c8d5e6b71")

	if _, err := s.VerifyResume(s.IssueGuest(id)); err != ErrWrongKind {
		t.Errorf("guest token accepted as a resume token: %v", err)
	}
	if _, err := s.VerifyGuest(s.IssueResume(id, "ROOM", 0)); err != ErrWrongKind {
		t.Errorf("resume token accepted as a guest token: %v", err)
	}

	if _, err := s.VerifySession(s.IssueGuest(id)); err != ErrWrongKind {
		t.Errorf("guest token accepted as a session token: %v", err)
	}
	if _, err := s.VerifySession(s.IssueResume(id, "ROOM", 0)); err != ErrWrongKind {
		t.Errorf("resume token accepted as a session token: %v", err)
	}
	if _, err := s.VerifyGuest(session); err != ErrWrongKind {
		t.Errorf("session token accepted as a guest token: %v", err)
	}
	if _, err := s.VerifyResume(session); err != ErrWrongKind {
		t.Errorf("session token accepted as a resume token: %v", err)
	}
}

func TestSessionRejectsForgeryAndExpiry(t *testing.T) {
	s := newSigner()
	const userID = "018f3a2b-7c41-7b3e-9a10-4f2c8d5e6b71"
	token, _ := s.IssueSession(userID)

	// A session signed with a different secret must not verify here: the whole
	// point of the single-algorithm design is that only this key mints identity.
	other := NewSigner([]byte("another-secret"))
	foreign, _ := other.IssueSession(userID)
	if _, err := s.VerifySession(foreign); err != ErrSignature {
		t.Errorf("a session from a foreign secret verified: %v", err)
	}

	body, sig, _ := strings.Cut(token, ".")
	if _, err := s.VerifySession("x" + body[1:] + "." + sig); err == nil {
		t.Error("a mangled session payload verified")
	}
	for _, bad := range []string{"", ".", "abc", "abc.", ".abc", "a.b.c", "!!!.???"} {
		if _, err := s.VerifySession(bad); err == nil {
			t.Errorf("garbage token %q verified as a session", bad)
		}
	}

	future := NewSigner([]byte("test-secret"))
	future.now = func() time.Time { return time.Now().Add(SessionTTL + time.Minute) }
	if _, err := future.VerifySession(token); err == nil || !strings.Contains(err.Error(), "expired") {
		t.Fatalf("expired session verified: %v", err)
	}
}

func TestTamperingIsRejected(t *testing.T) {
	s := newSigner()
	token := s.IssueResume(NewGuestID(), "7QF2", 0)

	body, sig, _ := strings.Cut(token, ".")

	// Re-signing with a different secret must not verify.
	other := NewSigner([]byte("another-secret"))
	if _, err := s.VerifyResume(other.IssueResume(NewGuestID(), "7QF2", 3)); err != ErrSignature {
		t.Errorf("a token from a foreign secret verified: %v", err)
	}

	// Flipping a payload byte invalidates the signature.
	mangled := "x" + body[1:] + "." + sig
	if _, err := s.VerifyResume(mangled); err == nil {
		t.Error("a mangled payload verified")
	}

	for _, bad := range []string{"", ".", "abc", "abc.", ".abc", "a.b.c", "!!!.???"} {
		if _, err := s.VerifyGuest(bad); err == nil {
			t.Errorf("garbage token %q verified", bad)
		}
	}
}

func TestExpiry(t *testing.T) {
	s := newSigner()
	token := s.IssueResume(NewGuestID(), "7QF2", 1)

	future := NewSigner([]byte("test-secret"))
	future.now = func() time.Time { return time.Now().Add(ResumeTTL + time.Minute) }

	if _, err := future.VerifyResume(token); err == nil || !strings.Contains(err.Error(), "expired") {
		t.Fatalf("expired token verified: %v", err)
	}
}

func TestResolveGuestAlwaysYieldsAnIdentity(t *testing.T) {
	s := newSigner()

	fresh, token := s.ResolveGuest("")
	if fresh == "" || token == "" {
		t.Fatal("an empty token must still mint an identity")
	}

	same, reissued := s.ResolveGuest(token)
	if same != fresh {
		t.Fatalf("a valid token produced a different identity: %q vs %q", same, fresh)
	}
	if reissued == "" {
		t.Fatal("a valid token must be refreshed, not dropped")
	}

	// Forged input must not error out the join — it just makes a new player.
	replaced, _ := s.ResolveGuest("not-a-real-token")
	if replaced == "" || replaced == fresh {
		t.Fatal("a forged token must produce a new identity, not reuse one")
	}
}
