// Actor-wide read position tests (#571 B, read.go). Pinned here: POST /read
// keys the value by the tracked member's actor so a second device of the
// same person sees it in GET /events `read_seq` while another actor sees its
// own (0 until it posts); the value only grows; the gate answers the typing
// codes (404 / 410 / 403 device_not_allowed / 403 not_a_member) with the
// membership verdict before the 400 bad_seq range check; the body is strict
// JSON with a required identifier; and — unlike typing — the row is durable
// across a relay restart.
package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/jinwon-int/family-messenger/archive/native-mls/server/internal/devicepolicy"
)

func readBody(t *testing.T, device string, seq int64) []byte {
	t.Helper()
	raw, err := json.Marshal(readPost{Device: device, Seq: seq})
	if err != nil {
		t.Fatalf("marshal read body: %v", err)
	}
	return raw
}

// postRead expects 200 and returns the answered read_seq.
func postRead(t *testing.T, srv *httptest.Server, room, device string, seq int64) int64 {
	t.Helper()
	st, raw := doJSON(t, srv, "POST", "/v2/rooms/"+room+"/read", readBody(t, device, seq))
	if st != http.StatusOK {
		t.Fatalf("read %s seq=%d: status=%d body=%s", device, seq, st, raw)
	}
	var resp readResponse
	if err := json.Unmarshal(raw, &resp); err != nil {
		t.Fatalf("decode read response %s: %v", raw, err)
	}
	return resp.ReadSeq
}

// readSeqOf reads the room as device and returns GET /events `read_seq`.
func readSeqOf(t *testing.T, srv *httptest.Server, room, device string) int64 {
	t.Helper()
	st, raw := doJSON(t, srv, "GET", "/v2/rooms/"+room+"/events?device="+device, nil)
	if st != http.StatusOK {
		t.Fatalf("get %s: status=%d body=%s", device, st, raw)
	}
	return decodeEventsResponse(t, raw).ReadSeq
}

// seedActors enrolls alice (a1, a2), bob (b1) and carol (c1, never a member)
// and founds room r with a1, a2, b1 (seq 1), then a2 posts one application
// event (seq 2).
func seedActors(t *testing.T, srv *httptest.Server, st *devicepolicy.DevicePolicyStore, first map[string]string) {
	t.Helper()
	enrollDevice(t, st, first, "a1", "alice")
	enrollDevice(t, st, first, "a2", "alice")
	enrollDevice(t, st, first, "b1", "bob")
	enrollDevice(t, st, first, "c1", "carol")
	boot := postCommitBody(t, "a1", "c1", 0, nil, membersOf([2]string{"a1", "alice"}, [2]string{"a2", "alice"}, [2]string{"b1", "bob"}), []byte("bootstrap"))
	if st, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", boot); st != http.StatusCreated {
		t.Fatalf("bootstrap: status=%d body=%s", st, raw)
	}
	if st, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "a2", "m1", "application", 1, nil, nil, []byte("hello"))); st != http.StatusCreated {
		t.Fatalf("application: status=%d body=%s", st, raw)
	}
}

func TestReadPositionIsSharedAcrossOneActorsDevices(t *testing.T) {
	_, srv, st, _, first := newEnforcedRelay(t, testPolicy())
	seedActors(t, srv, st, first)

	for _, d := range []string{"a1", "a2", "b1"} {
		if got := readSeqOf(t, srv, "r", d); got != 0 {
			t.Fatalf("fresh read_seq for %s = %d, want 0", d, got)
		}
	}
	if got := postRead(t, srv, "r", "a1", 2); got != 2 {
		t.Fatalf("a1 read → %d, want 2", got)
	}
	// The same actor's other device sees it; another actor does not.
	if got := readSeqOf(t, srv, "r", "a2"); got != 2 {
		t.Fatalf("a2 read_seq = %d, want 2 (alice-wide)", got)
	}
	if got := readSeqOf(t, srv, "r", "b1"); got != 0 {
		t.Fatalf("b1 read_seq = %d, want 0 (bob has not read)", got)
	}
	if got := postRead(t, srv, "r", "b1", 1); got != 1 {
		t.Fatalf("b1 read → %d, want 1", got)
	}
	if got := readSeqOf(t, srv, "r", "a1"); got != 2 {
		t.Fatalf("a1 read_seq after bob's read = %d, want 2", got)
	}
	// Never shrinks: a lower post from either alice device keeps 2.
	if got := postRead(t, srv, "r", "a2", 1); got != 2 {
		t.Fatalf("a2 lower read → %d, want 2 (monotonic)", got)
	}
	if got := postRead(t, srv, "r", "a1", 0); got != 2 {
		t.Fatalf("a1 zero read → %d, want 2 (monotonic)", got)
	}
	// Reading never writes: GET after GET stays at 2 for alice, 1 for bob.
	if got := readSeqOf(t, srv, "r", "b1"); got != 1 {
		t.Fatalf("b1 read_seq = %d, want 1", got)
	}
}

func TestReadGateMembershipBeforeRange(t *testing.T) {
	_, srv, st, _, first := newEnforcedRelay(t, testPolicy())
	seedActors(t, srv, st, first)

	cases := []struct {
		name   string
		room   string
		body   []byte
		status int
		err    string
	}{
		{"above last_seq", "r", readBody(t, "a1", 3), http.StatusBadRequest, "bad_seq"},
		{"negative", "r", readBody(t, "a1", -1), http.StatusBadRequest, "bad_seq"},
		{"unknown room", "nope", readBody(t, "a1", 0), http.StatusNotFound, "no_such_room"},
		{"unknown device", "r", readBody(t, "ghost", 1), http.StatusForbidden, "device_not_allowed"},
		// carol is policy-active but not on the roster: 403, and the range
		// check does not leak last_seq (99 would be bad_seq for a member).
		{"active non-member", "r", readBody(t, "c1", 99), http.StatusForbidden, "not_a_member"},
		{"device required", "r", []byte(`{"seq":1}`), http.StatusBadRequest, "device_required"},
		{"bad identifier", "r", []byte(`{"device":"a 1","seq":1}`), http.StatusBadRequest, "bad_identifier"},
		{"unknown field", "r", []byte(`{"device":"a1","seq":1,"actor":"bob"}`), http.StatusBadRequest, "bad_request"},
	}
	for _, c := range cases {
		code, raw := doJSON(t, srv, "POST", "/v2/rooms/"+c.room+"/read", c.body)
		if code != c.status || (c.err != "" && errField(t, raw) != c.err) {
			t.Fatalf("%s: status=%d body=%s, want %d %s", c.name, code, raw, c.status, c.err)
		}
	}
	// Nothing above moved the value.
	if got := readSeqOf(t, srv, "r", "a1"); got != 0 {
		t.Fatalf("read_seq after refused posts = %d, want 0", got)
	}
	// A non-member reader of a seeded room gets read_seq 0, never 403 on GET.
	if got := readSeqOf(t, srv, "r", "c1"); got != 0 {
		t.Fatalf("non-member read_seq = %d, want 0", got)
	}
	// Closed room: 410.
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/close?device=a1", nil); code != http.StatusOK {
		t.Fatalf("close: status=%d body=%s", code, raw)
	}
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/read", readBody(t, "a1", 1)); code != http.StatusGone || errField(t, raw) != "room_closed" {
		t.Fatalf("read on closed room: status=%d body=%s", code, raw)
	}
}

func TestReadPositionSurvivesRestart(t *testing.T) {
	policyDir := t.TempDir()
	if err := os.Chmod(policyDir, 0700); err != nil {
		t.Fatal(err)
	}
	st, err := devicepolicy.OpenDevicePolicyStore(policyDir)
	if err != nil {
		t.Fatalf("open device policy: %v", err)
	}
	if _, err := st.Init(); err != nil {
		t.Fatalf("init device policy: %v", err)
	}
	dataDir := t.TempDir()
	first := map[string]string{}
	r1, srv1, _ := newTestRelayAt(t, testPolicy(), dataDir)
	r1.devices = st
	seedActors(t, srv1, st, first)
	if got := postRead(t, srv1, "r", "a1", 2); got != 2 {
		t.Fatalf("a1 read → %d, want 2", got)
	}
	srv1.Close()
	if err := r1.db.Close(); err != nil {
		t.Fatalf("close first relay: %v", err)
	}

	r2, srv2, _ := newTestRelayAt(t, testPolicy(), dataDir)
	r2.devices = st
	if got := readSeqOf(t, srv2, "r", "a2"); got != 2 {
		t.Fatalf("read_seq after restart = %d, want 2 (durable, unlike typing)", got)
	}
}
