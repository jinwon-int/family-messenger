// Review batch 1 hardening tests (#177): H1 depth bomb, H2 prune before the
// byte cap and prune on GET, H3a removed-member cursor grace, M4 paging and
// body limit, M5 key-package idempotency, L1 commit replay epoch, L8
// identifier validation, plus the schema migration for pre-existing files.
package main

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
)

func TestDepthBombReturns400NotCrash(t *testing.T) {
	_, srv := newTestRelay(t, testPolicy())
	bomb := bytes.Repeat([]byte("["), maxBodyBytes) // exactly the body limit, never closed
	for _, path := range []string{"/v2/rooms/r/events", "/v2/rooms/r/keypackages"} {
		code, raw := doJSON(t, srv, "POST", path, bomb)
		if code != http.StatusBadRequest || errField(t, raw) != "json_too_deep" {
			t.Fatalf("%s depth bomb: status=%d body=%s", path, code, raw)
		}
	}
	// Nesting inside an otherwise valid object is capped the same way;
	// shallow nesting is an ordinary decode error, not json_too_deep.
	deep := []byte(`{"device":"a1","client_id":"c1","kind":"application","epoch":0,"bytes":` + strings.Repeat("[", 40) + strings.Repeat("]", 40) + `}`)
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", deep); code != http.StatusBadRequest || errField(t, raw) != "json_too_deep" {
		t.Fatalf("40-deep field: status=%d body=%s", code, raw)
	}
	shallow := []byte(`{"device":"a1","client_id":"c1","kind":"application","epoch":0,"bytes":` + strings.Repeat("[", 10) + strings.Repeat("]", 10) + `}`)
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", shallow); code != http.StatusBadRequest || errField(t, raw) != "bad_request" {
		t.Fatalf("10-deep field: status=%d body=%s", code, raw)
	}
	// The relay is still alive and the room untouched.
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", postEventBody(t, "a1", "c1", "application", 0, nil, nil, []byte("ok"))); code != http.StatusCreated {
		t.Fatalf("post after bombs: status=%d body=%s", code, raw)
	}
}

// TestRoomCapChecksAfterPrune pins H2: stale application events every reader
// has passed are reclaimed before the cap is measured, so a room "full" of
// expired traffic still accepts the next commit.
func TestRoomCapChecksAfterPrune(t *testing.T) {
	pol := testPolicy()
	pol.RoomBytesCap = 1 << 10 // 1 KiB
	pol.AppEventTTLSeconds = -1
	r, srv := newTestRelay(t, pol)

	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "a1", "c1", "application", 0, nil, nil, bytes.Repeat([]byte("a"), 600))); code != http.StatusCreated {
		t.Fatalf("seed 600B: status=%d body=%s", code, raw)
	}
	// Every known reader (a1 only) has read seq 1 — set directly so no GET
	// gets a chance to prune first; this isolates the POST path.
	if _, err := r.db.Exec(`UPDATE mls_cursors SET seq = 1 WHERE room = 'r'`); err != nil {
		t.Fatal(err)
	}
	code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "a1", "c2", "commit", 0, nil, nil, bytes.Repeat([]byte("b"), 600)))
	if code != http.StatusCreated {
		t.Fatalf("commit into a room full of stale events: status=%d body=%s, want 201 (prune before cap)", code, raw)
	}
	if resp := decodeEventResponse(t, raw); resp.Seq != 2 || resp.Epoch != 1 {
		t.Fatalf("commit response = %+v, want seq 2 epoch 1 (seq never restarts after a prune)", resp)
	}
	var used int64
	if err := r.db.QueryRow(`SELECT SUM(LENGTH(bytes)) FROM mls_events WHERE room = 'r'`).Scan(&used); err != nil {
		t.Fatal(err)
	}
	if used != 600 {
		t.Fatalf("room holds %d bytes after the commit, want 600 (stale seed reclaimed)", used)
	}
	// Live traffic nobody has read is still capped.
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "a1", "c3", "application", 1, nil, nil, bytes.Repeat([]byte("c"), 600))); code != http.StatusRequestEntityTooLarge || errField(t, raw) != "room_bytes_cap" {
		t.Fatalf("unread traffic over the cap: status=%d body=%s", code, raw)
	}
}

// TestGetPrunesWhenCursorAdvances pins the H2 read-side half: a read that
// moves the minimum cursor reclaims the stale events it passed.
func TestGetPrunesWhenCursorAdvances(t *testing.T) {
	pol := testPolicy()
	pol.AppEventTTLSeconds = -1
	r, srv := newTestRelay(t, pol)
	for i := 1; i <= 3; i++ {
		if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
			postEventBody(t, "a1", fmt.Sprintf("c%d", i), "application", 0, nil, nil, []byte("m"))); code != http.StatusCreated {
			t.Fatalf("seed %d: status=%d body=%s", i, code, raw)
		}
	}
	code, raw := doJSON(t, srv, "GET", "/v2/rooms/r/events?device=a1", nil)
	if code != http.StatusOK {
		t.Fatalf("get: status=%d body=%s", code, raw)
	}
	if got := decodeEventsResponse(t, raw); len(got.Events) != 3 || got.NextAfter != 3 {
		t.Fatalf("first read = %d events next_after %d, want 3/3", len(got.Events), got.NextAfter)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_events WHERE room = 'r'`); n != 0 {
		t.Fatalf("read did not prune what it passed: %d rows left", n)
	}
	// The next write continues the order.
	code, raw = doJSON(t, srv, "POST", "/v2/rooms/r/events", postEventBody(t, "a1", "c4", "application", 0, nil, nil, []byte("m")))
	if code != http.StatusCreated || decodeEventResponse(t, raw).Seq != 4 {
		t.Fatalf("post after read-prune: status=%d body=%s, want seq 4", code, raw)
	}
}

func TestKeyPackageRefIdempotency(t *testing.T) {
	pol := testPolicy()
	pol.KeyPackagesMaxPerDevice = 2
	_, srv := newTestRelay(t, pol)
	post := func(ref string, b []byte) (int, keyPackagesResponse, []byte) {
		t.Helper()
		body, _ := json.Marshal(keyPackagePost{Device: "a1", Packages: []keyPackageInput{{Ref: ref, Bytes: b}}})
		code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/keypackages", body)
		var res keyPackagesResponse
		_ = json.Unmarshal(raw, &res)
		return code, res, raw
	}
	if code, res, raw := post("k1", []byte("A")); code != http.StatusCreated || res.Stored != 1 || res.Duplicates != 0 {
		t.Fatalf("first k1: status=%d body=%s", code, raw)
	}
	if code, res, raw := post("k1", []byte("A")); code != http.StatusOK || res.Stored != 0 || res.Duplicates != 1 {
		t.Fatalf("byte-equal k1 replay: status=%d body=%s, want 200 idempotent", code, raw)
	}
	if code, _, raw := post("k1", []byte("B")); code != http.StatusConflict || errField(t, raw) != "key_package_ref_conflict" {
		t.Fatalf("k1 with different bytes: status=%d body=%s", code, raw)
	}
	if code, _, raw := post("k2", []byte("C")); code != http.StatusCreated {
		t.Fatalf("k2: status=%d body=%s", code, raw)
	}
	// Replays do not consume the live cap; a new ref beyond it does.
	if code, _, raw := post("k2", []byte("C")); code != http.StatusOK {
		t.Fatalf("k2 replay at the cap: status=%d body=%s", code, raw)
	}
	if code, _, raw := post("k3", []byte("D")); code != http.StatusConflict || errField(t, raw) != "key_package_limit" {
		t.Fatalf("k3 over the cap: status=%d body=%s", code, raw)
	}
	// A consumed ref keeps its identity: same bytes idempotent, new bytes 409.
	if code, raw := doJSON(t, srv, "GET", "/v2/rooms/r/keypackages?device=a1&consumer=b1", nil); code != http.StatusOK {
		t.Fatalf("consume: status=%d body=%s", code, raw)
	}
	if code, _, raw := post("k1", []byte("A")); code != http.StatusOK {
		t.Fatalf("consumed k1 replay: status=%d body=%s", code, raw)
	}
	if code, _, raw := post("k1", []byte("Z")); code != http.StatusConflict {
		t.Fatalf("consumed k1 repointed: status=%d body=%s", code, raw)
	}
}

func TestCommitReplayReturnsPostCommitEpoch(t *testing.T) {
	_, srv := newTestRelay(t, testPolicy())
	commit := postEventBody(t, "a1", "c1", "commit", 0, nil, nil, []byte("commit"))
	code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", commit)
	if code != http.StatusCreated {
		t.Fatalf("commit: status=%d body=%s", code, raw)
	}
	first := decodeEventResponse(t, raw)
	if first.Epoch != 1 {
		t.Fatalf("commit epoch = %d, want 1", first.Epoch)
	}
	code, raw = doJSON(t, srv, "POST", "/v2/rooms/r/events", commit)
	if code != http.StatusOK {
		t.Fatalf("replay: status=%d body=%s", code, raw)
	}
	if replay := decodeEventResponse(t, raw); !replay.Duplicate || replay.Epoch != 1 || replay.Seq != first.Seq {
		t.Fatalf("commit replay = %+v, want duplicate at the post-commit epoch 1 (L1)", replay)
	}
	// An application replay keeps its own epoch.
	app := postEventBody(t, "a1", "c2", "application", 1, nil, nil, []byte("app"))
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", app); code != http.StatusCreated {
		t.Fatalf("app: status=%d body=%s", code, raw)
	}
	code, raw = doJSON(t, srv, "POST", "/v2/rooms/r/events", app)
	if code != http.StatusOK || decodeEventResponse(t, raw).Epoch != 1 {
		t.Fatalf("app replay: status=%d body=%s, want 200 at epoch 1", code, raw)
	}
}

func TestIdentifierValidation(t *testing.T) {
	_, srv := newTestRelay(t, testPolicy())
	long := strings.Repeat("x", 65)
	cases := []struct {
		name, method, path string
		body               []byte
	}{
		{"device with space", "POST", "/v2/rooms/r/events", postEventBody(t, "a 1", "c1", "application", 0, nil, nil, []byte("x"))},
		{"device with slash", "POST", "/v2/rooms/r/events", postEventBody(t, "a/1", "c1", "application", 0, nil, nil, []byte("x"))},
		{"device too long", "POST", "/v2/rooms/r/events", postEventBody(t, long, "c1", "application", 0, nil, nil, []byte("x"))},
		{"welcome target", "POST", "/v2/rooms/r/events", postEventBody(t, "a1", "c1", "welcome", 0, nil, []string{"ok", "bad!"}, []byte("x"))},
		{"member device", "POST", "/v2/rooms/r/events", postCommitBody(t, "a1", "c1", 0, nil, []memberWire{{Device: "a1", Actor: "alice"}, {Device: "b 1", Actor: "bob"}}, []byte("x"))},
		{"member actor", "POST", "/v2/rooms/r/events", postCommitBody(t, "a1", "c1", 0, nil, []memberWire{{Device: "a1", Actor: "al.ice"}}, []byte("x"))},
		{"empty member actor", "POST", "/v2/rooms/r/events", postCommitBody(t, "a1", "c1", 0, nil, []memberWire{{Device: "a1", Actor: ""}}, []byte("x"))},
		{"keypackage device", "POST", "/v2/rooms/r/keypackages", []byte(`{"device":"a#1","packages":[{"ref":"k","bytes":"aGk="}]}`)},
		{"get device", "GET", "/v2/rooms/r/events?device=a%201", nil},
		{"consume device", "GET", "/v2/rooms/r/keypackages?device=a%2F1&consumer=b1", nil},
		{"consume consumer", "GET", "/v2/rooms/r/keypackages?device=a1&consumer=" + long, nil},
		{"close device", "POST", "/v2/rooms/r/close?device=a!1", nil},
	}
	for _, c := range cases {
		code, raw := doJSON(t, srv, c.method, c.path, c.body)
		if code != http.StatusBadRequest || errField(t, raw) != "bad_identifier" {
			t.Fatalf("%s: status=%d body=%s", c.name, code, raw)
		}
	}
	// The full alphabet at the length limit is fine.
	ok := "ABCxyz019_-" + strings.Repeat("z", 53)
	if len(ok) != 64 {
		t.Fatalf("test identifier length %d", len(ok))
	}
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", postEventBody(t, ok, "c1", "application", 0, nil, nil, []byte("x"))); code != http.StatusCreated {
		t.Fatalf("64-char identifier: status=%d body=%s", code, raw)
	}
}

func TestGetEventsLimitAndNextAfter(t *testing.T) {
	_, srv := newTestRelay(t, testPolicy())
	post := func(id, kind string, targets []string) {
		t.Helper()
		if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", postEventBody(t, "a1", id, kind, 0, nil, targets, []byte(id))); code != http.StatusCreated {
			t.Fatalf("post %s: status=%d body=%s", id, code, raw)
		}
	}
	post("m1", "application", nil)        // 1
	post("m2", "application", nil)        // 2
	post("w3", "welcome", []string{"b1"}) // 3, invisible to a1
	post("m4", "application", nil)        // 4
	post("m5", "application", nil)        // 5
	post("m6", "application", nil)        // 6
	get := func(query string) eventsResponse {
		t.Helper()
		code, raw := doJSON(t, srv, "GET", "/v2/rooms/r/events?"+query, nil)
		if code != http.StatusOK {
			t.Fatalf("get %s: status=%d body=%s", query, code, raw)
		}
		return decodeEventsResponse(t, raw)
	}
	seqs := func(r eventsResponse) []int64 {
		var out []int64
		for _, e := range r.Events {
			out = append(out, e.Seq)
		}
		return out
	}
	page := get("device=a1&limit=2")
	if fmt.Sprint(seqs(page)) != "[1 2]" || page.NextAfter != 2 {
		t.Fatalf("page 1 = %v next_after %d", seqs(page), page.NextAfter)
	}
	// The filtered Welcome at 3 counts as scanned: next_after passes it.
	page = get("device=a1&after=2&limit=2")
	if fmt.Sprint(seqs(page)) != "[4]" || page.NextAfter != 4 {
		t.Fatalf("page 2 = %v next_after %d, want [4] / 4", seqs(page), page.NextAfter)
	}
	page = get("device=a1&after=4&limit=2")
	if fmt.Sprint(seqs(page)) != "[5 6]" || page.NextAfter != 6 {
		t.Fatalf("page 3 = %v next_after %d", seqs(page), page.NextAfter)
	}
	page = get("device=a1&after=6&limit=2")
	if len(page.Events) != 0 || page.NextAfter != 6 {
		t.Fatalf("empty page = %v next_after %d, want next_after == after", seqs(page), page.NextAfter)
	}
	// The target sees its Welcome on a one-row page.
	page = get("device=b1&after=2&limit=1")
	if fmt.Sprint(seqs(page)) != "[3]" || page.Events[0].Kind != "welcome" || page.NextAfter != 3 {
		t.Fatalf("b1 page = %+v next_after %d", page.Events, page.NextAfter)
	}
	// Default and clamped limits return everything visible.
	if page = get("device=a1"); len(page.Events) != 5 || page.NextAfter != 6 {
		t.Fatalf("default limit = %v next_after %d", seqs(page), page.NextAfter)
	}
	if page = get("device=a1&limit=99999"); len(page.Events) != 5 {
		t.Fatalf("clamped limit = %v", seqs(page))
	}
	for _, bad := range []string{"0", "-1", "abc"} {
		if code, raw := doJSON(t, srv, "GET", "/v2/rooms/r/events?device=a1&limit="+bad, nil); code != http.StatusBadRequest || errField(t, raw) != "bad_limit" {
			t.Fatalf("limit=%s: status=%d body=%s", bad, code, raw)
		}
	}
}

// TestRemovedMemberCursorGrace pins H3a: a member removed by commit keeps
// gating application-event pruning until it reads its own removal (ack) or
// the grace elapses; it never gains a fresh cursor by reading afterwards.
func TestRemovedMemberCursorGrace(t *testing.T) {
	setup := func(t *testing.T, grace int64) (*relay, *httptest.Server, string) {
		pol := testPolicy()
		pol.AppEventTTLSeconds = -1
		pol.RemovedCursorGraceSeconds = grace
		r, srv, st, _, first := newEnforcedRelay(t, pol)
		enrollDevice(t, st, first, "a1", "alice")
		enrollDevice(t, st, first, "b1", "bob")
		must := func(name string, body []byte) {
			t.Helper()
			if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", body); code != http.StatusCreated {
				t.Fatalf("%s: status=%d body=%s", name, code, raw)
			}
		}
		must("bootstrap", postCommitBody(t, "a1", "c1", 0, nil, membersOf([2]string{"a1", "alice"}, [2]string{"b1", "bob"}), []byte("boot"))) // 1
		must("b1 app", postEventBody(t, "b1", "c2", "application", 1, nil, nil, []byte("from b1")))                                           // 2
		must("a1 app", postEventBody(t, "a1", "c3", "application", 1, nil, nil, []byte("from a1")))                                           // 3
		if code, _ := doJSON(t, srv, "GET", "/v2/rooms/r/events?device=a1", nil); code != http.StatusOK {
			t.Fatal("a1 read")
		}
		if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_events WHERE room = 'r' AND kind = 'application'`); n != 2 {
			t.Fatalf("b1 (unread) must gate both app events: %d left", n)
		}
		must("remove b1", postCommitBody(t, "a1", "c4", 1, nil, membersOf([2]string{"a1", "alice"}), []byte("remove b1"))) // 4
		return r, srv, "r"
	}
	appRows := func(t *testing.T, r *relay) int {
		return tableCount(t, r, `SELECT COUNT(*) FROM mls_events WHERE room = 'r' AND kind = 'application'`)
	}

	t.Run("gates until the removed device reads its removal", func(t *testing.T) {
		r, srv, _ := setup(t, 7*24*3600)
		if code, _ := doJSON(t, srv, "GET", "/v2/rooms/r/events?device=a1", nil); code != http.StatusOK {
			t.Fatal("a1 read")
		}
		if n := appRows(t, r); n != 2 {
			t.Fatalf("removed b1 within grace must still gate: %d app rows left", n)
		}
		if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_cursors WHERE room = 'r' AND device = 'b1' AND removed_at IS NOT NULL AND removed_seq = 4`); n != 1 {
			t.Fatalf("b1 cursor not marked removed at seq 4: %d", n)
		}
		// b1 reads: sees everything up to and including its removal (ack).
		code, raw := doJSON(t, srv, "GET", "/v2/rooms/r/events?device=b1", nil)
		if code != http.StatusOK {
			t.Fatalf("b1 read: status=%d body=%s", code, raw)
		}
		if got := decodeEventsResponse(t, raw); len(got.Events) != 4 || got.NextAfter != 4 {
			t.Fatalf("b1 must still fetch what led to its removal: %d events next_after %d", len(got.Events), got.NextAfter)
		}
		if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_cursors WHERE room = 'r' AND device = 'b1'`); n != 0 {
			t.Fatalf("acked removal must drop the cursor: %d rows", n)
		}
		if n := appRows(t, r); n != 0 {
			t.Fatalf("after the ack the stale events prune: %d left", n)
		}
		// Reading again as a non-member does not resurrect a gate.
		if code, _ := doJSON(t, srv, "GET", "/v2/rooms/r/events?device=b1", nil); code != http.StatusOK {
			t.Fatal("b1 second read")
		}
		if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_cursors WHERE room = 'r' AND device = 'b1'`); n != 0 {
			t.Fatalf("non-member read created a cursor: %d rows", n)
		}
	})

	t.Run("drops after the grace elapsed", func(t *testing.T) {
		r, srv, _ := setup(t, -1)
		if code, _ := doJSON(t, srv, "GET", "/v2/rooms/r/events?device=a1", nil); code != http.StatusOK {
			t.Fatal("a1 read")
		}
		if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_cursors WHERE room = 'r' AND device = 'b1'`); n != 0 {
			t.Fatalf("expired grace must drop the cursor: %d rows", n)
		}
		if n := appRows(t, r); n != 0 {
			t.Fatalf("after the grace the stale events prune: %d left", n)
		}
	})

	// Re-adding needs the actor still on the roster (§3.3), so this flow
	// removes and re-adds a second device of an actor who stays: a2 of alice.
	t.Run("re-added device is a reader again", func(t *testing.T) {
		pol := testPolicy()
		r, srv, st, _, first := newEnforcedRelay(t, pol)
		enrollDevice(t, st, first, "a1", "alice")
		enrollDevice(t, st, first, "a2", "alice")
		alice2 := membersOf([2]string{"a1", "alice"}, [2]string{"a2", "alice"})
		steps := []struct {
			name string
			body []byte
		}{
			{"bootstrap", postCommitBody(t, "a1", "c1", 0, nil, alice2, []byte("boot"))},
			{"a2 app", postEventBody(t, "a2", "c2", "application", 1, nil, nil, []byte("from a2"))},
			{"remove a2", postCommitBody(t, "a1", "c3", 1, nil, membersOf([2]string{"a1", "alice"}), []byte("remove a2"))},
		}
		for _, s := range steps {
			if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", s.body); code != http.StatusCreated {
				t.Fatalf("%s: status=%d body=%s", s.name, code, raw)
			}
		}
		if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_cursors WHERE room = 'r' AND device = 'a2' AND removed_at IS NOT NULL`); n != 1 {
			t.Fatalf("removed a2 cursor not marked: %d", n)
		}
		if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
			postCommitBody(t, "a1", "c4", 2, nil, alice2, []byte("re-add a2"))); code != http.StatusCreated {
			t.Fatalf("re-add: status=%d body=%s", code, raw)
		}
		if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_cursors WHERE room = 'r' AND device = 'a2' AND removed_at IS NULL`); n != 1 {
			t.Fatalf("re-added a2 cursor not revived: %d", n)
		}
	})
}

// TestNonMemberReadDoesNotCreateCursor: with membership tracking on, an
// active device outside a seeded room may read (GET is not membership-gated)
// but never becomes a pruning gate.
func TestNonMemberReadDoesNotCreateCursor(t *testing.T) {
	r, srv, st, _, first := newEnforcedRelay(t, testPolicy())
	enrollDevice(t, st, first, "a1", "alice")
	enrollDevice(t, st, first, "c1", "carol")
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", postCommitBody(t, "a1", "c1", 0, nil, membersOf([2]string{"a1", "alice"}), []byte("boot"))); code != http.StatusCreated {
		t.Fatalf("bootstrap: status=%d body=%s", code, raw)
	}
	if code, raw := doJSON(t, srv, "GET", "/v2/rooms/r/events?device=c1", nil); code != http.StatusOK {
		t.Fatalf("c1 read: status=%d body=%s", code, raw)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_cursors WHERE room = 'r' AND device = 'c1'`); n != 0 {
		t.Fatalf("non-member c1 gained a cursor: %d", n)
	}
}

// TestOpenStoreMigratesOlderSchema pins the ALTER TABLE path: a database
// created before last_seq/removed_at existed opens, gains the columns and
// backfills last_seq from the surviving events.
func TestOpenStoreMigratesOlderSchema(t *testing.T) {
	dir := t.TempDir()
	old, err := sql.Open("sqlite3", sqliteURI(filepath.Join(dir, "native-mls-v2.db")))
	if err != nil {
		t.Fatal(err)
	}
	oldSchema := `
CREATE TABLE mls_rooms (room TEXT PRIMARY KEY, group_id TEXT NOT NULL, epoch INTEGER NOT NULL DEFAULT 0,
	revision INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, closed_at INTEGER);
CREATE TABLE mls_events (room TEXT NOT NULL REFERENCES mls_rooms(room), seq INTEGER NOT NULL, device TEXT NOT NULL,
	client_id TEXT NOT NULL, kind TEXT NOT NULL, epoch INTEGER NOT NULL, targets TEXT, bytes BLOB NOT NULL,
	sha256 TEXT NOT NULL, created_at INTEGER NOT NULL, UNIQUE (room, device, client_id), PRIMARY KEY (room, seq));
CREATE TABLE mls_cursors (room TEXT NOT NULL REFERENCES mls_rooms(room), device TEXT NOT NULL, seq INTEGER NOT NULL, PRIMARY KEY (room, device));
INSERT INTO mls_rooms (room, group_id, epoch, revision, created_at) VALUES ('r', 'r', 0, 7, 1);
INSERT INTO mls_events VALUES ('r', 7, 'a1', 'c7', 'application', 0, NULL, x'00', 'x', 1);
INSERT INTO mls_cursors VALUES ('r', 'a1', 7);`
	if _, err := old.Exec(oldSchema); err != nil {
		t.Fatal(err)
	}
	old.Close()

	db, err := openStore(dir)
	if err != nil {
		t.Fatalf("open migrated store: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	var lastSeq int64
	if err := db.QueryRow(`SELECT last_seq FROM mls_rooms WHERE room = 'r'`).Scan(&lastSeq); err != nil || lastSeq != 7 {
		t.Fatalf("last_seq backfill = %d err=%v, want 7", lastSeq, err)
	}
	var removed sql.NullInt64
	if err := db.QueryRow(`SELECT removed_at FROM mls_cursors WHERE room = 'r' AND device = 'a1'`).Scan(&removed); err != nil || removed.Valid {
		t.Fatalf("removed_at after migration = %v err=%v", removed, err)
	}
	// Reopening is idempotent.
	db2, err := openStore(dir)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	db2.Close()
	// And the next event continues at seq 8 through the real path.
	r := &relay{db: db, policy: testPolicy()}
	stored, err := r.storeEvent("r", eventInput{device: "a1", clientID: "c8", kind: "application", bytes: []byte("x")})
	if err != nil || stored.seq != 8 {
		t.Fatalf("post after migration = %+v err=%v, want seq 8", stored, err)
	}
}
