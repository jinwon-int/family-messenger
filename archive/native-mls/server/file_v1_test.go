// file-v1 retirement (#499 decision 6, file_v1.go): before the cutoff a
// file-v1 post is stored as today; at and after it a new kind=application
// post whose client_id starts with `file-v1-` gets 410 file_v1_retired with
// nothing stored, file-v2 / status / ordinary ids and commits are unaffected,
// already-stored v1 rows stay readable, and a byte-equal retry of one is
// refused 410 too (no 200 duplicate).
package main

import (
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

const (
	fileV1ID  = "file-v1-0f3c2a9b-1d2e-4f5a-8b6c-7d8e9fa0b1c2"
	fileV1ID2 = "file-v1-1f3c2a9b-1d2e-4f5a-8b6c-7d8e9fa0b1c2"
	fileV2ID  = "file-v2-0f3c2a9b-1d2e-4f5a-8b6c-7d8e9fa0b1c2"
	statusID  = "status-0f3c2a9b-1d2e-4f5a-8b6c-7d8e9fa0b1c2"
)

// newClockRelay is newTestRelay with relay.now wired to clk (Unix seconds)
// before the server starts, so the race detector sees the clock write
// happen before any handler goroutine.
func newClockRelay(t *testing.T, pol policy, clk *atomic.Int64) (*relay, *httptest.Server) {
	t.Helper()
	db, err := openStore(t.TempDir())
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	r := &relay{db: db, policy: pol, now: func() time.Time { return time.Unix(clk.Load(), 0) }}
	srv := httptest.NewServer(r.routes())
	t.Cleanup(srv.Close)
	return r, srv
}

func countRows(t *testing.T, r *relay, query string, args ...any) int {
	t.Helper()
	var n int
	if err := r.db.QueryRow(query, args...).Scan(&n); err != nil {
		t.Fatalf("%s: %v", query, err)
	}
	return n
}

func postV1App(t *testing.T, srv *httptest.Server, room, device, clientID string, payload []byte) (int, []byte) {
	t.Helper()
	return doJSON(t, srv, "POST", "/v2/rooms/"+room+"/events",
		postEventBody(t, device, clientID, "application", 0, nil, nil, payload))
}

func TestFileV1RetireAtIsDecisionSixCutoff(t *testing.T) {
	want := time.Date(2026, time.December, 2, 15, 0, 0, 0, time.UTC)
	if !fileV1RetireAt.Equal(want) {
		t.Fatalf("fileV1RetireAt = %s, want 2026-12-03T00:00:00+09:00 (%s)", fileV1RetireAt, want)
	}
	if got := defaultPolicy().FileV1RetireAtUnix; got != want.Unix() {
		t.Fatalf("defaultPolicy().FileV1RetireAtUnix = %d, want %d", got, want.Unix())
	}
	if got := fileV1RetireAt.Format(time.RFC3339); got != "2026-12-03T00:00:00+09:00" {
		t.Fatalf("flag default = %q", got)
	}
}

func TestFileV1PostBeforeCutoffIsStored(t *testing.T) {
	var clk atomic.Int64
	clk.Store(fileV1RetireAt.Unix() - 1) // 2026-12-02 23:59:59 KST
	r, srv := newClockRelay(t, testPolicy(), &clk)

	st, raw := postV1App(t, srv, "r", "a1", fileV1ID, []byte("v1-photo"))
	if st != http.StatusCreated {
		t.Fatalf("v1 post before cutoff: status=%d body=%s, want 201", st, raw)
	}
	if n := countRows(t, r, `SELECT COUNT(*) FROM mls_events WHERE client_id = ?`, fileV1ID); n != 1 {
		t.Fatalf("stored v1 rows = %d, want 1", n)
	}
}

func TestFileV1PostAtAndAfterCutoffIsRefused410(t *testing.T) {
	var clk atomic.Int64
	clk.Store(fileV1RetireAt.Unix())
	r, srv := newClockRelay(t, testPolicy(), &clk)

	// A refused first post to a fresh room must not create the room either.
	for _, at := range []int64{fileV1RetireAt.Unix(), fileV1RetireAt.Unix() + 86400, fileV1RetireAt.Unix() + 365*86400} {
		clk.Store(at)
		for _, id := range []string{
			fileV1ID,
			"file-v1-short", // non-canonical: prefix rule
			"file-v1-0F3C2A9B-1D2E-4F5A-8B6C-7D8E9FA0B1C2",   // uppercase uuid
			"file-v1-0f3c2a9b-1d2e-4f5a-8b6c-7d8e9fa0b1c2-x", // suffix
		} {
			st, raw := postV1App(t, srv, "fresh", "a1", id, []byte("v1-photo"))
			if st != http.StatusGone {
				t.Fatalf("at %d %s: status=%d body=%s, want 410", at, id, st, raw)
			}
			if e := decodeAPIError(t, raw); e.Error != "file_v1_retired" {
				t.Fatalf("at %d %s: error = %q, want file_v1_retired", at, id, e.Error)
			}
		}
	}
	if n := countRows(t, r, `SELECT COUNT(*) FROM mls_events`); n != 0 {
		t.Fatalf("events stored after refusal = %d, want 0", n)
	}
	if n := countRows(t, r, `SELECT COUNT(*) FROM mls_rooms`); n != 0 {
		t.Fatalf("rooms created by a refused post = %d, want 0", n)
	}
	if st, raw := doJSON(t, srv, "GET", "/v2/rooms/fresh/events?device=a1", nil); st != http.StatusNotFound {
		t.Fatalf("GET after refused-only posts: status=%d body=%s, want 404 no_such_room", st, raw)
	}
}

// In an existing room a refusal leaves the epoch/revision CAS pointer, the
// byte accounting and the sequence untouched.
func TestFileV1RefusalHasNoCASOrStorageSideEffects(t *testing.T) {
	var clk atomic.Int64
	clk.Store(fileV1RetireAt.Unix())
	r, srv := newClockRelay(t, testPolicy(), &clk)

	if st, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "a1", "c1", "commit", 0, nil, nil, []byte("commit-one"))); st != http.StatusCreated {
		t.Fatalf("seed commit: status=%d body=%s", st, raw)
	}
	before := decodeEventsResponse(t, mustGet(t, srv, "/v2/rooms/r/events?device=a1"))
	var bytesBefore int64
	if err := r.db.QueryRow(`SELECT COALESCE(SUM(LENGTH(bytes)),0) FROM mls_events`).Scan(&bytesBefore); err != nil {
		t.Fatal(err)
	}

	st, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "a1", fileV1ID, "application", 1, i64p(1), nil, []byte("v1-photo")))
	if st != http.StatusGone || errField(t, raw) != "file_v1_retired" {
		t.Fatalf("v1 post in existing room: status=%d body=%s, want 410 file_v1_retired", st, raw)
	}

	after := decodeEventsResponse(t, mustGet(t, srv, "/v2/rooms/r/events?device=a1"))
	if after.Epoch != before.Epoch || after.Revision != before.Revision || len(after.Events) != len(before.Events) {
		t.Fatalf("refusal moved state: before epoch/rev/events=%d/%d/%d after=%d/%d/%d",
			before.Epoch, before.Revision, len(before.Events), after.Epoch, after.Revision, len(after.Events))
	}
	var bytesAfter int64
	if err := r.db.QueryRow(`SELECT COALESCE(SUM(LENGTH(bytes)),0) FROM mls_events`).Scan(&bytesAfter); err != nil {
		t.Fatal(err)
	}
	if bytesAfter != bytesBefore {
		t.Fatalf("stored bytes %d → %d after a refused post", bytesBefore, bytesAfter)
	}
	// The next fresh post at the unchanged epoch/revision pointer is accepted
	// and gets the very next seq: nothing was reserved.
	st, raw = doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "a1", "a1-text-1", "application", 1, i64p(1), nil, []byte("hello")))
	if st != http.StatusCreated {
		t.Fatalf("text after refusal: status=%d body=%s", st, raw)
	}
	if seq := decodeEventResponse(t, raw).Seq; seq != before.Events[len(before.Events)-1].Seq+1 {
		t.Fatalf("seq after refusal = %d, want %d", seq, before.Events[len(before.Events)-1].Seq+1)
	}
}

func TestFileV1RetirementLeavesOtherIDsAndKindsAlone(t *testing.T) {
	var clk atomic.Int64
	clk.Store(fileV1RetireAt.Unix() + 86400)
	_, srv := newClockRelay(t, testPolicy(), &clk)

	// kind=commit/welcome are out of scope even with the prefix (no client
	// sends that; refusing a commit could wedge the epoch chain).
	if st, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "a1", "file-v1-commit", "commit", 0, nil, nil, []byte("commit-one"))); st != http.StatusCreated {
		t.Fatalf("commit with file-v1- prefix: status=%d body=%s, want 201", st, raw)
	}
	if st, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "a1", "file-v1-welcome", "welcome", 1, nil, []string{"b1"}, []byte("welcome-one"))); st != http.StatusCreated {
		t.Fatalf("welcome with file-v1- prefix: status=%d body=%s, want 201", st, raw)
	}
	for i, id := range []string{fileV2ID, statusID, "a1-0f3c2a9b", "file-v1", "file-v2-short", "xfile-v1-0f3c2a9b"} {
		st, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
			postEventBody(t, "a1", id, "application", 1, nil, nil, []byte{byte(i), 'x'}))
		if st != http.StatusCreated {
			t.Fatalf("%s after cutoff: status=%d body=%s, want 201", id, st, raw)
		}
	}
}

// A v1 row stored before the cutoff stays readable through GET /events
// after it, and a byte-equal retry of that same post is refused 410 — not
// answered 200 duplicate: the sender must stop either way, and the check
// runs before the K4 replay lookup.
func TestFileV1StoredRowStaysReadableAndRetryIsRefused(t *testing.T) {
	var clk atomic.Int64
	clk.Store(fileV1RetireAt.Unix() - 60)
	r, srv := newClockRelay(t, testPolicy(), &clk)

	body := postEventBody(t, "a1", fileV1ID, "application", 0, nil, nil, []byte("v1-photo"))
	st, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", body)
	if st != http.StatusCreated {
		t.Fatalf("v1 before cutoff: status=%d body=%s", st, raw)
	}
	seq := decodeEventResponse(t, raw).Seq
	if st, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", body); st != http.StatusOK || !decodeEventResponse(t, raw).Duplicate {
		t.Fatalf("byte-equal retry before cutoff: status=%d body=%s, want 200 duplicate", st, raw)
	}

	clk.Store(fileV1RetireAt.Unix())
	st, raw = doJSON(t, srv, "POST", "/v2/rooms/r/events", body)
	if st != http.StatusGone || errField(t, raw) != "file_v1_retired" {
		t.Fatalf("byte-equal retry after cutoff: status=%d body=%s, want 410 file_v1_retired", st, raw)
	}
	if st, raw := postV1App(t, srv, "r", "a1", fileV1ID2, []byte("v1-other")); st != http.StatusGone {
		t.Fatalf("new v1 after cutoff: status=%d body=%s, want 410", st, raw)
	}
	if n := countRows(t, r, `SELECT COUNT(*) FROM mls_events WHERE client_id LIKE 'file-v1-%'`); n != 1 {
		t.Fatalf("v1 rows = %d, want the one stored before the cutoff", n)
	}

	got := decodeEventsResponse(t, mustGet(t, srv, "/v2/rooms/r/events?device=b1"))
	if len(got.Events) != 1 || got.Events[0].Seq != seq || got.Events[0].ClientID != fileV1ID || string(got.Events[0].Bytes) != "v1-photo" {
		t.Fatalf("GET after cutoff = %+v, want the stored v1 row seq=%d", got.Events, seq)
	}
}

func TestFileV1RetirementOffAcceptsAfterCutoff(t *testing.T) {
	var clk atomic.Int64
	clk.Store(fileV1RetireAt.Unix() + 86400)
	pol := testPolicy()
	pol.FileV1RetireAtUnix = 0
	_, srv := newClockRelay(t, pol, &clk)
	if st, raw := postV1App(t, srv, "r", "a1", fileV1ID, []byte("v1-photo")); st != http.StatusCreated {
		t.Fatalf("v1 with retirement off: status=%d body=%s, want 201", st, raw)
	}
}

// The default clock is the wall clock: a relay without relay.now still
// enforces the cutoff once it has passed (pinned with a cutoff in the past).
func TestFileV1RetirementUsesWallClockByDefault(t *testing.T) {
	pol := testPolicy()
	pol.FileV1RetireAtUnix = time.Now().Add(-time.Hour).Unix()
	_, srv := newTestRelay(t, pol)
	if st, raw := postV1App(t, srv, "r", "a1", fileV1ID, []byte("v1-photo")); st != http.StatusGone {
		t.Fatalf("past cutoff on the wall clock: status=%d body=%s, want 410", st, raw)
	}
	pol.FileV1RetireAtUnix = time.Now().Add(time.Hour).Unix()
	_, srv = newTestRelay(t, pol)
	if st, raw := postV1App(t, srv, "r", "a1", fileV1ID, []byte("v1-photo")); st != http.StatusCreated {
		t.Fatalf("future cutoff on the wall clock: status=%d body=%s, want 201", st, raw)
	}
}

func TestParseFileV1RetireAt(t *testing.T) {
	if got, err := parseFileV1RetireAt(fileV1RetireAt.Format(time.RFC3339)); err != nil || got != fileV1RetireAt.Unix() {
		t.Fatalf("default flag value = %d, %v", got, err)
	}
	if got, err := parseFileV1RetireAt("2026-12-02T15:00:00Z"); err != nil || got != fileV1RetireAt.Unix() {
		t.Fatalf("UTC spelling = %d, %v", got, err)
	}
	if got, err := parseFileV1RetireAt("off"); err != nil || got != 0 {
		t.Fatalf("off = %d, %v", got, err)
	}
	for _, bad := range []string{"", "2026-12-03", "tomorrow", "OFF", "1970-01-01T00:00:00Z"} {
		if _, err := parseFileV1RetireAt(bad); err == nil {
			t.Fatalf("parseFileV1RetireAt(%q) accepted", bad)
		}
	}
}

func mustGet(t *testing.T, srv *httptest.Server, path string) []byte {
	t.Helper()
	st, raw := doJSON(t, srv, "GET", path, nil)
	if st != http.StatusOK {
		t.Fatalf("GET %s: status=%d body=%s", path, st, raw)
	}
	return raw
}
