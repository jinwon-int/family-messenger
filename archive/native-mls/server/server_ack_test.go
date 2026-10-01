package main

import (
	"bytes"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"testing"
)

// TestReadDoesNotMoveCursorOnlyAckDoes pins review M2: a read never moves the
// durable cursor, so a response lost on the wire can be fetched again with
// the same `after`, and application pruning waits for the slowest ACK, not
// the slowest read.
func TestReadDoesNotMoveCursorOnlyAckDoes(t *testing.T) {
	pol := testPolicy()
	pol.AppEventTTLSeconds = -1 // every stored app event is stale at prune time
	r, srv := newTestRelay(t, pol)
	post := func(device, client string) {
		t.Helper()
		if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
			postEventBody(t, device, client, "application", 0, nil, nil, []byte(client))); code != http.StatusCreated {
			t.Fatalf("post %s/%s: status=%d body=%s", device, client, code, raw)
		}
	}
	post("a1", "c1")
	post("b1", "c2") // b1 becomes a known reader with cursor 0
	post("a1", "c3")

	// b1 reads everything but never acks (its response is "lost").
	code, raw := doJSON(t, srv, "GET", "/v2/rooms/r/events?device=b1", nil)
	if code != http.StatusOK {
		t.Fatalf("b1 read: status=%d body=%s", code, raw)
	}
	if got := decodeEventsResponse(t, raw); len(got.Events) != 3 || got.NextAfter != 3 || got.Cursor != 0 {
		t.Fatalf("b1 read = %d events next_after %d cursor %d, want 3/3/0", len(got.Events), got.NextAfter, got.Cursor)
	}
	if n := tableCount(t, r, `SELECT seq FROM mls_cursors WHERE room = 'r' AND device = 'b1'`); n != 0 {
		t.Fatalf("a read moved b1's cursor to %d", n)
	}

	// a1 acks everything; that advances a1 and runs a prune, but b1's
	// unacked cursor (0) still gates every application event.
	code, raw = doJSON(t, srv, "GET", "/v2/rooms/r/events?device=a1&after=3&ack=3", nil)
	if code != http.StatusOK || decodeEventsResponse(t, raw).Cursor != 3 {
		t.Fatalf("a1 ack: status=%d body=%s, want cursor 3", code, raw)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_events WHERE room = 'r'`); n != 3 {
		t.Fatalf("pruned past b1's unacked cursor: %d rows left, want 3", n)
	}
	// The lost response is recoverable: re-reading from the same offset
	// returns the same events.
	code, raw = doJSON(t, srv, "GET", "/v2/rooms/r/events?device=b1&after=0", nil)
	if got := decodeEventsResponse(t, raw); code != http.StatusOK || len(got.Events) != 3 {
		t.Fatalf("b1 re-read: status=%d events=%d, want 3", code, len(got.Events))
	}

	// b1 acks: now the minimum ack is 3 and the stale events go.
	code, raw = doJSON(t, srv, "GET", "/v2/rooms/r/events?device=b1&after=3&ack=3", nil)
	if code != http.StatusOK || decodeEventsResponse(t, raw).Cursor != 3 {
		t.Fatalf("b1 ack: status=%d body=%s, want cursor 3", code, raw)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_events WHERE room = 'r'`); n != 0 {
		t.Fatalf("after every ack the stale events must prune: %d left", n)
	}
}

// TestAckIsMonotonicAndBounded: an ack never moves a cursor backwards, may
// not name a seq the room has not produced, and must be a non-negative
// integer.
func TestAckIsMonotonicAndBounded(t *testing.T) {
	_, srv := newTestRelay(t, testPolicy())
	for i := 1; i <= 3; i++ {
		if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
			postEventBody(t, "a1", fmt.Sprintf("c%d", i), "application", 0, nil, nil, []byte("m"))); code != http.StatusCreated {
			t.Fatalf("seed %d: status=%d body=%s", i, code, raw)
		}
	}
	ack := func(v string) (int, []byte) {
		t.Helper()
		return doJSON(t, srv, "GET", "/v2/rooms/r/events?device=a1&ack="+v, nil)
	}
	if code, raw := ack("2"); code != http.StatusOK || decodeEventsResponse(t, raw).Cursor != 2 {
		t.Fatalf("ack 2: status=%d body=%s", code, raw)
	}
	if code, raw := ack("1"); code != http.StatusOK || decodeEventsResponse(t, raw).Cursor != 2 {
		t.Fatalf("ack 1 after 2 must keep cursor 2: status=%d body=%s", code, raw)
	}
	if code, raw := ack("4"); code != http.StatusBadRequest || errField(t, raw) != "bad_ack" {
		t.Fatalf("ack past last_seq: status=%d body=%s, want 400 bad_ack", code, raw)
	}
	for _, bad := range []string{"-1", "x", "1.5"} {
		if code, raw := ack(bad); code != http.StatusBadRequest || errField(t, raw) != "bad_ack" {
			t.Fatalf("ack %q: status=%d body=%s, want 400 bad_ack", bad, code, raw)
		}
	}
	// A read without ack reports the durable cursor unchanged.
	code, raw := doJSON(t, srv, "GET", "/v2/rooms/r/events?device=a1&after=3", nil)
	if code != http.StatusOK || decodeEventsResponse(t, raw).Cursor != 2 {
		t.Fatalf("plain read cursor: status=%d body=%s, want 2", code, raw)
	}
}

// TestNonMemberAckIsRefused: with membership tracking on, a device that is
// not a tracked member of a seeded room may read (GET stays open) but its ack
// is refused — it must not become a pruning gate.
func TestNonMemberAckIsRefused(t *testing.T) {
	r, srv, st, _, first := newEnforcedRelay(t, testPolicy())
	enrollDevice(t, st, first, "a1", "alice")
	enrollDevice(t, st, first, "c1", "carol")
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", postCommitBody(t, "a1", "c1", 0, nil, membersOf([2]string{"a1", "alice"}), []byte("boot"))); code != http.StatusCreated {
		t.Fatalf("bootstrap: status=%d body=%s", code, raw)
	}
	if code, raw := doJSON(t, srv, "GET", "/v2/rooms/r/events?device=c1&ack=1", nil); code != http.StatusForbidden || errField(t, raw) != "not_a_member" {
		t.Fatalf("non-member ack: status=%d body=%s, want 403 not_a_member", code, raw)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_cursors WHERE room = 'r' AND device = 'c1'`); n != 0 {
		t.Fatalf("refused ack created a cursor: %d", n)
	}
	if code, raw := doJSON(t, srv, "GET", "/v2/rooms/r/events?device=a1&ack=1", nil); code != http.StatusOK || decodeEventsResponse(t, raw).Cursor != 1 {
		t.Fatalf("member ack: status=%d body=%s, want cursor 1", code, raw)
	}
}

// TestDataDirLockAdmitsOneHolder: the relay holds an exclusive data-dir lock
// for its lifetime, so a second relay or the offline -reset-room tool cannot
// open the same database underneath it.
func TestDataDirLockAdmitsOneHolder(t *testing.T) {
	dir := t.TempDir()
	st, err := openStore(dir)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if _, err := openStore(dir); !errors.Is(err, errStoreLocked) {
		t.Fatalf("second open = %v, want errStoreLocked", err)
	}
	if _, err := resetRoom(dir, "r", true); !errors.Is(err, errStoreLocked) {
		t.Fatalf("reset under a live store = %v, want errStoreLocked", err)
	}
	st.Close()
	st2, err := openStore(dir)
	if err != nil {
		t.Fatalf("reopen after close: %v", err)
	}
	st2.Close()
}

// TestResetRoomOfflineDeletesOnlyThatRoom pins the H3 operator recovery:
// dry run by default, exact per-table counts, only the named room's rows
// deleted, other rooms untouched, and no database created from nothing.
func TestResetRoomOfflineDeletesOnlyThatRoom(t *testing.T) {
	dir := t.TempDir()
	if _, err := resetRoom(dir, "r", true); err == nil {
		t.Fatal("reset on an empty dir must refuse instead of creating a database")
	}
	rA, srvA, _ := newTestRelayAt(t, testPolicy(), dir)
	for _, room := range []string{"squatted", "keep"} {
		for i := 1; i <= 2; i++ {
			if code, raw := doJSON(t, srvA, "POST", "/v2/rooms/"+room+"/events",
				postEventBody(t, "a1", fmt.Sprintf("c%d", i), "application", 0, nil, nil, []byte("m"))); code != http.StatusCreated {
				t.Fatalf("seed %s: status=%d body=%s", room, code, raw)
			}
		}
	}
	srvA.Close()
	if err := rA.db.Close(); err != nil {
		t.Fatalf("close relay: %v", err)
	}

	var out bytes.Buffer
	if code := runResetRoom(&out, dir, "squatted", false); code != 2 {
		t.Fatalf("dry run exit = %d, want 2; out=%s", code, out.String())
	}
	if !strings.Contains(out.String(), "events=2") || !strings.Contains(out.String(), "dry run") {
		t.Fatalf("dry run output = %q", out.String())
	}
	c, err := resetRoom(dir, "squatted", false)
	if err != nil || c.Rooms != 1 || c.Events != 2 || c.Cursors != 1 {
		t.Fatalf("dry-run counts = %+v err=%v, want rooms 1 events 2 cursors 1", c, err)
	}
	out.Reset()
	if code := runResetRoom(&out, dir, "squatted", true); code != 0 {
		t.Fatalf("confirmed reset exit = %d, want 0; out=%s", code, out.String())
	}
	if c, err := resetRoom(dir, "squatted", false); err != nil || c.total() != 0 {
		t.Fatalf("after reset counts = %+v err=%v, want zero", c, err)
	}
	if c, err := resetRoom(dir, "keep", false); err != nil || c.Events != 2 || c.Rooms != 1 {
		t.Fatalf("other room touched: %+v err=%v", c, err)
	}

	// A relay reopened over the file sees the squatted name as new again.
	_, srvB, _ := newTestRelayAt(t, testPolicy(), dir)
	if code, raw := doJSON(t, srvB, "GET", "/v2/rooms/squatted/events?device=a1", nil); code != http.StatusNotFound {
		t.Fatalf("reset room still served: status=%d body=%s, want 404", code, raw)
	}
	if code, raw := doJSON(t, srvB, "POST", "/v2/rooms/squatted/events",
		postEventBody(t, "a2", "fresh", "application", 0, nil, nil, []byte("m"))); code != http.StatusCreated || decodeEventResponse(t, raw).Seq != 1 {
		t.Fatalf("fresh bootstrap after reset: status=%d body=%s, want 201 seq 1", code, raw)
	}
}
