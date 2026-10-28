// Typing indicator relay tests (#562 PR A, typing.go). Pinned here: the
// signal piggybacks on GET /events (`typing`, never null, reader excluded),
// clear:true and a fresh application event drop it while a byte-equal replay
// does not, the TTL expires it, the write-side membership gate answers the
// same codes as consuming a key package (404/410/403/403) and a non-member
// reader of a seeded room gets `[]`, the state is bounded (≤ maxMembers per
// room, identifiers and strict JSON as on every route) and it is memory-only:
// a restart forgets it, mls_events never grows and APNs never fires.
package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func typingBody(t *testing.T, device string, clear bool) []byte {
	t.Helper()
	raw, err := json.Marshal(typingPost{Device: device, Clear: clear})
	if err != nil {
		t.Fatalf("marshal typing body: %v", err)
	}
	return raw
}

// postTyping expects 204 and no body.
func postTyping(t *testing.T, srv *httptest.Server, room, device string, clear bool) {
	t.Helper()
	st, raw := doJSON(t, srv, "POST", "/v2/rooms/"+room+"/typing", typingBody(t, device, clear))
	if st != http.StatusNoContent || len(raw) != 0 {
		t.Fatalf("typing %s clear=%v: status=%d body=%s", device, clear, st, raw)
	}
}

// typingOf reads the room as device and returns the `typing` field, failing
// when it is JSON null rather than a list.
func typingOf(t *testing.T, srv *httptest.Server, room, device string) []string {
	t.Helper()
	st, raw := doJSON(t, srv, "GET", "/v2/rooms/"+room+"/events?device="+device, nil)
	if st != http.StatusOK {
		t.Fatalf("get %s: status=%d body=%s", device, st, raw)
	}
	var probe struct {
		Typing json.RawMessage `json:"typing"`
	}
	if err := json.Unmarshal(raw, &probe); err != nil || string(probe.Typing) == "null" || len(probe.Typing) == 0 {
		t.Fatalf("typing field must be a list, got %s (%v)", probe.Typing, err)
	}
	return decodeEventsResponse(t, raw).Typing
}

func seedRoom(t *testing.T, srv *httptest.Server, room string) {
	t.Helper()
	if st, raw := doJSON(t, srv, "POST", "/v2/rooms/"+room+"/events",
		postEventBody(t, "a1", "seed", "application", 0, nil, nil, []byte("seed"))); st != http.StatusCreated {
		t.Fatalf("seed: status=%d body=%s", st, raw)
	}
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestTypingPiggybacksOnGetEventsExcludingReader(t *testing.T) {
	_, srv := newTestRelay(t, testPolicy())
	seedRoom(t, srv, "r")
	if got := typingOf(t, srv, "r", "a1"); len(got) != 0 {
		t.Fatalf("fresh room typing = %v, want []", got)
	}
	postTyping(t, srv, "r", "b1", false)
	postTyping(t, srv, "r", "a1", false)
	if got := typingOf(t, srv, "r", "a1"); !equalStrings(got, []string{"b1"}) {
		t.Fatalf("a1 sees %v, want [b1] (self excluded)", got)
	}
	if got := typingOf(t, srv, "r", "c1"); !equalStrings(got, []string{"a1", "b1"}) {
		t.Fatalf("c1 sees %v, want [a1 b1] sorted", got)
	}
	postTyping(t, srv, "r", "b1", true)
	if got := typingOf(t, srv, "r", "c1"); !equalStrings(got, []string{"a1"}) {
		t.Fatalf("after clear c1 sees %v, want [a1]", got)
	}
	// Clearing a device that never typed, and typing in another room, are
	// both fine and do not leak across rooms.
	postTyping(t, srv, "r", "zz", true)
	seedRoom(t, srv, "other")
	if got := typingOf(t, srv, "other", "c1"); len(got) != 0 {
		t.Fatalf("other room sees %v, want []", got)
	}
}

func TestTypingExpiresAfterTTL(t *testing.T) {
	pol := testPolicy()
	pol.TypingTTLSeconds = -1
	r, srv := newTestRelay(t, pol)
	seedRoom(t, srv, "r")
	postTyping(t, srv, "r", "b1", false)
	if got := typingOf(t, srv, "r", "a1"); len(got) != 0 {
		t.Fatalf("expired signal still visible: %v", got)
	}
	// The expired entry was dropped and the emptied room map released.
	r.typing.mu.Lock()
	n := len(r.typing.rooms)
	r.typing.mu.Unlock()
	if n != 0 {
		t.Fatalf("typing state holds %d rooms after expiry, want 0", n)
	}
}

func TestTypingClearedByFreshApplicationEventNotByReplay(t *testing.T) {
	_, srv := newTestRelay(t, testPolicy())
	seedRoom(t, srv, "r")
	postTyping(t, srv, "r", "b1", false)
	msg := postEventBody(t, "b1", "m1", "application", 0, nil, nil, []byte("hello"))
	if st, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", msg); st != http.StatusCreated {
		t.Fatalf("post: status=%d body=%s", st, raw)
	}
	if got := typingOf(t, srv, "r", "a1"); len(got) != 0 {
		t.Fatalf("after a fresh application event typing = %v, want []", got)
	}
	// Typing again, then a byte-equal replay (200 duplicate) keeps it.
	postTyping(t, srv, "r", "b1", false)
	st, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", msg)
	if st != http.StatusOK || !decodeEventResponse(t, raw).Duplicate {
		t.Fatalf("replay: status=%d body=%s, want 200 duplicate", st, raw)
	}
	if got := typingOf(t, srv, "r", "a1"); !equalStrings(got, []string{"b1"}) {
		t.Fatalf("after a duplicate replay typing = %v, want [b1]", got)
	}
	// A commit is not a message either.
	if st, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "b1", "k1", "commit", 0, nil, nil, []byte("commit"))); st != http.StatusCreated {
		t.Fatalf("commit: status=%d body=%s", st, raw)
	}
	if got := typingOf(t, srv, "r", "a1"); !equalStrings(got, []string{"b1"}) {
		t.Fatalf("after a commit typing = %v, want [b1]", got)
	}
}

func TestTypingEnforcedMembershipGate(t *testing.T) {
	r, srv, st, _, first := newEnforcedRelay(t, testPolicy())
	enrollDevice(t, st, first, "a1", "alice")
	enrollDevice(t, st, first, "b1", "bob")
	enrollDevice(t, st, first, "c1", "carol")
	enrollDevice(t, st, first, "d1", "dave")

	// Unknown room: 404, and the typing POST did not found it.
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/nope/typing", typingBody(t, "a1", false)); code != http.StatusNotFound || errField(t, raw) != "no_such_room" {
		t.Fatalf("unknown room: status=%d body=%s", code, raw)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_rooms WHERE room = 'nope'`); n != 0 {
		t.Fatalf("typing founded a room: %d rows", n)
	}

	boot := postCommitBody(t, "a1", "c1", 0, nil, membersOf([2]string{"a1", "alice"}, [2]string{"b1", "bob"}), []byte("bootstrap"))
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", boot); code != http.StatusCreated {
		t.Fatalf("bootstrap: status=%d body=%s", code, raw)
	}
	postTyping(t, srv, "r", "b1", false)
	// Active outsider: 403 not_a_member. Revoked: 403 device_not_allowed.
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/typing", typingBody(t, "c1", false)); code != http.StatusForbidden || errField(t, raw) != "not_a_member" {
		t.Fatalf("outsider: status=%d body=%s", code, raw)
	}
	revokeDevice(t, st, "d1")
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/typing", typingBody(t, "d1", false)); code != http.StatusForbidden || errField(t, raw) != "device_not_allowed" {
		t.Fatalf("revoked: status=%d body=%s", code, raw)
	}
	// Member reader sees b1; the non-member reader (history stays open) gets [].
	if got := typingOf(t, srv, "r", "a1"); !equalStrings(got, []string{"b1"}) {
		t.Fatalf("member a1 sees %v, want [b1]", got)
	}
	if got := typingOf(t, srv, "r", "c1"); len(got) != 0 {
		t.Fatalf("non-member c1 sees %v, want []", got)
	}
	// Closed room: 410.
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/close?device=a1", nil); code != http.StatusOK {
		t.Fatalf("close: status=%d body=%s", code, raw)
	}
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/typing", typingBody(t, "a1", false)); code != http.StatusGone || errField(t, raw) != "room_closed" {
		t.Fatalf("closed room: status=%d body=%s", code, raw)
	}
}

func TestTypingInputHardeningAndRoomBound(t *testing.T) {
	r, srv := newTestRelay(t, testPolicy())
	seedRoom(t, srv, "r")
	bad := []struct {
		name string
		path string
		body []byte
		want string
	}{
		{"bad room", "/v2/rooms/r%0Aoom/typing", typingBody(t, "a1", false), "bad_identifier"},
		{"bad device", "/v2/rooms/r/typing", []byte(`{"device":"a 1"}`), "bad_identifier"},
		{"long device", "/v2/rooms/r/typing", []byte(`{"device":"` + strings.Repeat("a", maxIdentifierLen+1) + `"}`), "bad_identifier"},
		{"missing device", "/v2/rooms/r/typing", []byte(`{"clear":true}`), "device_required"},
		{"unknown field", "/v2/rooms/r/typing", []byte(`{"device":"a1","room":"r"}`), "bad_request"},
		{"duplicate key", "/v2/rooms/r/typing", []byte(`{"device":"a1","device":"b1"}`), "bad_request"},
		{"null field", "/v2/rooms/r/typing", []byte(`{"device":"a1","clear":null}`), "bad_request"},
		{"empty body", "/v2/rooms/r/typing", []byte{}, "empty_body"},
	}
	for _, tc := range bad {
		code, raw := doJSON(t, srv, "POST", tc.path, tc.body)
		if code != http.StatusBadRequest || errField(t, raw) != tc.want {
			t.Fatalf("%s: status=%d body=%s, want 400 %s", tc.name, code, raw, tc.want)
		}
	}
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/typing", bytes.Repeat([]byte("x"), maxBodyBytes+1)); code != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversized body: status=%d body=%s", code, raw)
	}
	if got := typingOf(t, srv, "r", "zz"); len(got) != 0 {
		t.Fatalf("rejected posts left typing = %v", got)
	}
	// 70 distinct devices: the room keeps at most maxMembers of them and the
	// extra ones are dropped silently (still 204).
	for i := 0; i < 70; i++ {
		postTyping(t, srv, "r", "dev"+jsonInt(int64(i)), false)
	}
	if got := typingOf(t, srv, "r", "reader"); len(got) != maxMembers {
		t.Fatalf("room holds %d typing devices, want %d", len(got), maxMembers)
	}
	r.typing.mu.Lock()
	n := len(r.typing.rooms["r"])
	r.typing.mu.Unlock()
	if n != maxMembers {
		t.Fatalf("typing map holds %d devices, want %d", n, maxMembers)
	}
}

func TestTypingRefreshFloorKeepsFirstExpiry(t *testing.T) {
	var ts typingState
	ts.set("r", "a1", 100, 6)
	ts.set("r", "a1", 100, 60) // < 1s later: ignored, expiry stays 106
	if got := ts.snapshot("r", "", 106); len(got) != 0 {
		t.Fatalf("refresh within the floor re-armed the entry: %v", got)
	}
	ts.set("r", "a1", 100, 6)
	ts.set("r", "a1", 101, 6) // 1s later: accepted, expiry 107
	if got := ts.snapshot("r", "", 106); !equalStrings(got, []string{"a1"}) {
		t.Fatalf("refresh after the floor was ignored: %v", got)
	}
	if got := ts.snapshot("nope", "", 0); got == nil {
		t.Fatal("snapshot of an unknown room must be a non-nil empty slice")
	}
}

func TestTypingIsMemoryOnlyNoRowsNoPush(t *testing.T) {
	pol := testPolicy()
	dir := t.TempDir()
	rA, srvA, _ := newTestRelayAt(t, pol, dir)
	fake := newFakeAPNs(t)
	sender, err := newAPNsSender(fake.srv.URL, "TEAM123456", "KEY1234567", testAPNsKey(t), fake.srv.Client())
	if err != nil {
		t.Fatal(err)
	}
	rA.push = sender
	const topic = "com.seoyoon-family.hande"
	if st, raw := doJSON(t, srvA, "POST", "/v2/push/devices", pushBody("a1", []byte{0xa1, 0x01}, topic)); st != http.StatusNoContent {
		t.Fatalf("register push: %d %s", st, raw)
	}
	seedRoom(t, srvA, "r")
	// b1 joins the room's readers, then types: a1 is registered for push and
	// behind, yet no APNs call happens — only events push.
	if st, raw := doJSON(t, srvA, "POST", "/v2/rooms/r/events",
		postEventBody(t, "b1", "m1", "application", 0, nil, nil, []byte("hi"))); st != http.StatusCreated {
		t.Fatalf("b1 post: status=%d body=%s", st, raw)
	}
	rA.pushWG.Wait()
	fake.taken()
	events := tableCount(t, rA, `SELECT COUNT(*) FROM mls_events`)
	for i := 0; i < 3; i++ {
		postTyping(t, srvA, "r", "b1", false)
	}
	rA.pushWG.Wait()
	if calls := fake.taken(); len(calls) != 0 {
		t.Fatalf("typing pushed %d APNs alerts, want 0", len(calls))
	}
	if n := tableCount(t, rA, `SELECT COUNT(*) FROM mls_events`); n != events {
		t.Fatalf("mls_events grew from %d to %d on typing", events, n)
	}
	if got := typingOf(t, srvA, "r", "a1"); !equalStrings(got, []string{"b1"}) {
		t.Fatalf("before restart a1 sees %v, want [b1]", got)
	}
	srvA.Close()
	if err := rA.db.Close(); err != nil {
		t.Fatalf("close relay 1: %v", err)
	}
	// Relay instance 2 over the same file: history is there, typing is not.
	_, srvB, _ := newTestRelayAt(t, pol, dir)
	st, raw := doJSON(t, srvB, "GET", "/v2/rooms/r/events?device=a1", nil)
	if st != http.StatusOK {
		t.Fatalf("get after restart: status=%d body=%s", st, raw)
	}
	got := decodeEventsResponse(t, raw)
	if len(got.Events) != events {
		t.Fatalf("restart kept %d events, want %d", len(got.Events), events)
	}
	if got.Typing == nil || len(got.Typing) != 0 {
		t.Fatalf("after restart typing = %v, want []", got.Typing)
	}
}
