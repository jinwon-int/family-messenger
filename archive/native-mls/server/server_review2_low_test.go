package main

// Review 2 (#231) Low items for the relay, batch f: JWKS redirect policy and
// concurrent-failure behaviour, JWT lifetime bounds, commit/welcome retention
// gated on reader cursors (plus first_seq), unseeded-room acks, the GET page
// byte budget, the read-only -reset-room dry run, and the loopback rule for
// -access-mode disabled. Plus the "pinned room → cap → removal commit →
// posts flow again" recovery the earlier tests stopped short of.

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// jwksTLSVerifier builds a verifier from the file fixture and then points it
// at a TLS server: the constructor's https-only rule is on the configured
// source, the redirect policy is on the client.
func jwksTLSVerifier(t *testing.T, iss *testIssuer, handler http.Handler) (*accessVerifier, *httptest.Server) {
	t.Helper()
	v := iss.verifier()
	tls := httptest.NewTLSServer(handler)
	t.Cleanup(tls.Close)
	client := tls.Client()
	client.CheckRedirect = jwksCheckRedirect
	client.Timeout = 10 * time.Second
	v.client = client
	v.source = tls.URL + "/certs"
	return v, tls
}

func TestJWKSRedirectToPlainHTTPIsRefused(t *testing.T) {
	iss := newTestIssuer(t)
	key2, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	rotatedJWKS, _ := json.Marshal(map[string]any{"keys": []map[string]string{ecJWK("rotated", &key2.PublicKey)}})

	var plainHits atomic.Int32
	plain := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		plainHits.Add(1)
		w.Write(rotatedJWKS)
	}))
	t.Cleanup(plain.Close)

	v, _ := jwksTLSVerifier(t, iss, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, plain.URL+"/certs", http.StatusFound)
	}))
	base := time.Now()
	v.now = func() time.Time { return base.Add(2 * time.Minute) }
	token2 := signES256(t, key2, map[string]any{"alg": "ES256", "kid": "rotated"}, baseClaims("s"))
	if _, err := v.verify(token2); !errors.Is(err, errUnauthorized) {
		t.Fatalf("rotated kid behind an https→http redirect: err=%v, want unauthorized", err)
	}
	if n := plainHits.Load(); n != 0 {
		t.Fatalf("the plain-http JWKS was fetched %d times", n)
	}
	// Known keys keep verifying: the refused reload left the cache alone.
	if _, err := v.verify(iss.mint("s", nil)); err != nil {
		t.Fatalf("known kid after refused redirect: %v", err)
	}
}

func TestJWKSRedirectChainIsBounded(t *testing.T) {
	iss := newTestIssuer(t)
	var hops atomic.Int32
	v, tls := jwksTLSVerifier(t, iss, nil)
	tls.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hops.Add(1)
		http.Redirect(w, r, tls.URL+"/again", http.StatusFound) // https → https, forever
	})
	base := time.Now()
	v.now = func() time.Time { return base.Add(2 * time.Minute) }
	key2, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	token2 := signES256(t, key2, map[string]any{"alg": "ES256", "kid": "rotated"}, baseClaims("s"))
	if _, err := v.verify(token2); !errors.Is(err, errUnauthorized) {
		t.Fatalf("redirect loop: err=%v", err)
	}
	if n := hops.Load(); n > jwksMaxRedirects+1 {
		t.Fatalf("followed %d hops, want at most %d", n, jwksMaxRedirects+1)
	}
}

// Test gap "JWKS 실패 연속 요청": N concurrent unknown-kid requests while the
// source hangs fetch once, never block known-kid verification, all fail when
// the source answers 500, and stay throttled afterwards.
func TestJWKSFailureUnderConcurrentUnknownKids(t *testing.T) {
	iss := newTestIssuer(t)
	var hits atomic.Int32
	release := make(chan struct{})
	v, _ := jwksTLSVerifier(t, iss, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		<-release
		w.WriteHeader(http.StatusInternalServerError)
	}))
	base := time.Now()
	v.now = func() time.Time { return base.Add(2 * time.Minute) }
	good := iss.mint("s", nil)
	key2, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	token2 := signES256(t, key2, map[string]any{"alg": "ES256", "kid": "rotated"}, baseClaims("s"))

	const n = 8
	var wg sync.WaitGroup
	results := make([]error, n)
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, results[i] = v.verify(token2)
		}(i)
	}
	// While the single fetch hangs, known kids verify (the fetch runs
	// outside mu) — bounded wait so a regression fails instead of hanging.
	deadline := time.Now().Add(5 * time.Second)
	for hits.Load() == 0 {
		if time.Now().After(deadline) {
			t.Fatal("no JWKS fetch started")
		}
		time.Sleep(5 * time.Millisecond)
	}
	done := make(chan error, 1)
	go func() { _, err := v.verify(good); done <- err }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("known kid during a hanging fetch: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("known-kid verification blocked behind the JWKS fetch")
	}
	close(release)
	wg.Wait()
	for i, err := range results {
		if !errors.Is(err, errUnauthorized) {
			t.Fatalf("goroutine %d: err=%v, want unauthorized", i, err)
		}
	}
	if got := hits.Load(); got != 1 {
		t.Fatalf("JWKS fetched %d times for %d concurrent unknown kids, want 1", got, n)
	}
	// Within the gap of the failed attempt nothing refetches.
	v.now = func() time.Time { return base.Add(2*time.Minute + 20*time.Second) }
	if _, err := v.verify(token2); !errors.Is(err, errUnauthorized) {
		t.Fatalf("after the failed attempt: err=%v", err)
	}
	if got := hits.Load(); got != 1 {
		t.Fatalf("throttle: %d fetches, want 1", got)
	}
}

func TestAccessVerifierLifetimeBounds(t *testing.T) {
	iss := newTestIssuer(t)
	v := iss.verifier()
	now := time.Now().Unix()
	bad := map[string]func(map[string]any){
		"exp far future":   func(c map[string]any) { c["exp"] = now + 10*365*24*3600 },
		"exp past max":     func(c map[string]any) { c["exp"] = now + int64((accessMaxLifetime + 2*accessLeeway).Seconds()) },
		"iat in future":    func(c map[string]any) { c["iat"] = now + 3600 },
		"iat-exp too long": func(c map[string]any) { c["iat"] = now - 400*3600; c["exp"] = now + 400*3600 },
	}
	for name, mutate := range bad {
		if _, err := v.verify(iss.mint("s", mutate)); !errors.Is(err, errUnauthorized) {
			t.Fatalf("%s: err=%v, want errUnauthorized", name, err)
		}
	}
	for name, mutate := range map[string]func(map[string]any){
		"exp 23h ahead":  func(c map[string]any) { c["exp"] = now + 23*3600 },
		"exp 730h ahead": func(c map[string]any) { c["exp"] = now + 730*3600 }, // the account's real session length
		"no iat":         func(c map[string]any) { delete(c, "iat"); c["exp"] = now + 23*3600 },
		"iat 30s ahead":  func(c map[string]any) { c["iat"] = now + 30 },
		"iat 23h ago":    func(c map[string]any) { c["iat"] = now - 23*3600; c["exp"] = now + 600 },
		"exp = iat + max": func(c map[string]any) {
			c["iat"] = now - 3600
			c["exp"] = now - 3600 + int64(accessMaxLifetime.Seconds())
		},
	} {
		if _, err := v.verify(iss.mint("s", mutate)); err != nil {
			t.Fatalf("%s must verify: %v", name, err)
		}
	}
	// The operator override tightens the bound.
	v.maxLifetime = 24 * time.Hour
	if _, err := v.verify(iss.mint("s", func(c map[string]any) { c["exp"] = now + 47*3600 })); !errors.Is(err, errUnauthorized) {
		t.Fatalf("47h with a 24h override: err=%v, want unauthorized", err)
	}
	if _, err := v.verify(iss.mint("s", func(c map[string]any) { c["exp"] = now + 23*3600 })); err != nil {
		t.Fatalf("23h with a 24h override: %v", err)
	}
}

// Commit/welcome events past the keep window stay while a known reader's
// cursor has not passed them; the hard backstop prunes regardless.
func TestCommitRetentionWaitsForReaderCursors(t *testing.T) {
	pol := testPolicy()
	pol.CommitWelcomeKeepEpochs = 2
	pol.CommitWelcomeHardMaxEpochs = 6
	pol.AppEventTTLSeconds = -1
	r, srv := newTestRelay(t, pol)
	post := func(device, id, kind string, epoch int64, targets []string) eventResponse {
		t.Helper()
		code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", postEventBody(t, device, id, kind, epoch, nil, targets, []byte(id)))
		if code != http.StatusCreated {
			t.Fatalf("post %s: status=%d body=%s", id, code, raw)
		}
		return decodeEventResponse(t, raw)
	}
	commits := func() int {
		return tableCount(t, r, `SELECT COUNT(*) FROM mls_events WHERE room = 'r' AND kind IN ('commit','welcome')`)
	}
	// b1 becomes a known reader at seq 1 (Welcome target) and never acks.
	post("a1", "w0", "welcome", 0, []string{"b1"})
	var epoch int64
	for i := 1; i <= 5; i++ {
		resp := post("a1", fmt.Sprintf("c%d", i), "commit", epoch, nil)
		epoch = resp.Epoch
	}
	// a1 acks everything → prune runs with min cursor = b1's 1 (its Welcome
	// floor). Epochs 0..3 are outside keep=2 at epoch 5 but b1 has not read
	// them: nothing goes.
	if code, raw := doJSON(t, srv, "GET", "/v2/rooms/r/events?device=a1&ack=6", nil); code != http.StatusOK {
		t.Fatalf("a1 ack: status=%d body=%s", code, raw)
	}
	if n := commits(); n != 6 {
		t.Fatalf("commits pruned past b1's cursor: %d left, want 6", n)
	}
	// b1 catches up: GET from its floor still returns the old commits, and
	// first_seq tells it the history is contiguous.
	code, raw := doJSON(t, srv, "GET", "/v2/rooms/r/events?device=b1&after=0", nil)
	page := decodeEventsResponse(t, raw)
	if code != http.StatusOK || len(page.Events) != 6 || page.FirstSeq != 1 {
		t.Fatalf("b1 catch-up: status=%d events=%d first_seq=%d", code, len(page.Events), page.FirstSeq)
	}
	// b1 acks seq 4: commits at seq ≤4 outside the keep window go, the
	// rest stay.
	if code, raw := doJSON(t, srv, "GET", "/v2/rooms/r/events?device=b1&ack=4", nil); code != http.StatusOK {
		t.Fatalf("b1 ack: status=%d body=%s", code, raw)
	}
	if n := commits(); n != 2 {
		t.Fatalf("after b1 ack 4: %d commit/welcome rows, want 2 (seq 5 and 6)", n)
	}
	// Backstop: push the epoch 7 past the oldest surviving row while b1
	// stalls again — it is pruned regardless of the cursor.
	for i := 6; i <= 12; i++ {
		resp := post("a1", fmt.Sprintf("c%d", i), "commit", epoch, nil)
		epoch = resp.Epoch
	}
	if code, raw := doJSON(t, srv, "GET", "/v2/rooms/r/events?device=a1&ack=13", nil); code != http.StatusOK {
		t.Fatalf("a1 ack: status=%d body=%s", code, raw)
	}
	var oldest sql.NullInt64
	if err := r.db.QueryRow(`SELECT MIN(epoch) FROM mls_events WHERE room = 'r' AND kind = 'commit'`).Scan(&oldest); err != nil {
		t.Fatal(err)
	}
	if !oldest.Valid || oldest.Int64 <= epoch-pol.CommitWelcomeHardMaxEpochs {
		t.Fatalf("backstop did not prune: oldest commit epoch %v at epoch %d", oldest, epoch)
	}
	// And the lagging reader sees the gap: first_seq is above its after+1.
	code, raw = doJSON(t, srv, "GET", "/v2/rooms/r/events?device=b1&after=4", nil)
	page = decodeEventsResponse(t, raw)
	if code != http.StatusOK || page.FirstSeq <= 5 {
		t.Fatalf("history gap not signalled: status=%d first_seq=%d", code, page.FirstSeq)
	}
}

// Recovery the earlier cap tests stopped short of: a non-acking reader pins
// the room to the cap, the removal commit is accepted, its cursor is dropped
// after the grace, pruning frees the room and application posts flow again.
func TestPinnedRoomRecoversAfterRemovalCommit(t *testing.T) {
	pol := testPolicy()
	pol.RoomBytesCap = 1 << 10
	pol.AppEventTTLSeconds = -1
	pol.RemovedCursorGraceSeconds = 0
	pol.CommitWelcomeKeepEpochs = 1
	r, srv, st, _, first := newEnforcedRelay(t, pol)
	enrollDevice(t, st, first, "a1", "alice")
	enrollDevice(t, st, first, "b1", "bob")
	post := func(body []byte) (int, []byte) {
		t.Helper()
		return doJSON(t, srv, "POST", "/v2/rooms/r/events", body)
	}
	if code, raw := post(postCommitBody(t, "a1", "boot", 0, nil, membersOf([2]string{"a1", "alice"}, [2]string{"b1", "bob"}), []byte("boot"))); code != http.StatusCreated {
		t.Fatalf("bootstrap: status=%d body=%s", code, raw)
	}
	if code, raw := post(postEventBody(t, "a1", "w1", "welcome", 1, nil, []string{"b1"}, []byte("welcome-b1"))); code != http.StatusCreated {
		t.Fatalf("welcome: status=%d body=%s", code, raw)
	}
	if code, raw := post(postEventBody(t, "a1", "m1", "application", 1, nil, nil, bytes.Repeat([]byte("a"), 900))); code != http.StatusCreated {
		t.Fatalf("fill: status=%d body=%s", code, raw)
	}
	if code, raw := post(postEventBody(t, "a1", "m2", "application", 1, nil, nil, bytes.Repeat([]byte("b"), 300))); code != http.StatusRequestEntityTooLarge {
		t.Fatalf("over cap: status=%d body=%s", code, raw)
	}
	// a1 acks; b1 (never read) still pins m1.
	if code, raw := doJSON(t, srv, "GET", "/v2/rooms/r/events?device=a1&ack=3", nil); code != http.StatusOK {
		t.Fatalf("a1 ack: status=%d body=%s", code, raw)
	}
	if code, raw := post(postEventBody(t, "a1", "m3", "application", 1, nil, nil, bytes.Repeat([]byte("c"), 300))); code != http.StatusRequestEntityTooLarge {
		t.Fatalf("still pinned by b1: status=%d body=%s", code, raw)
	}
	// The commit removing b1 is exempt from the cap.
	code, raw := post(postCommitBody(t, "a1", "rm", 1, nil, membersOf([2]string{"a1", "alice"}), []byte("remove-b1")))
	if code != http.StatusCreated {
		t.Fatalf("removal commit: status=%d body=%s", code, raw)
	}
	// Grace is zero: the next ack-driven prune drops b1's cursor and m1 goes.
	if code, raw := doJSON(t, srv, "GET", "/v2/rooms/r/events?device=a1&ack=4", nil); code != http.StatusOK {
		t.Fatalf("a1 ack after removal: status=%d body=%s", code, raw)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_cursors WHERE room = 'r' AND device = 'b1'`); n != 0 {
		t.Fatalf("removed reader still holds a cursor: %d", n)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_events WHERE room = 'r' AND kind = 'application'`); n != 0 {
		t.Fatalf("application rows after recovery: %d, want 0", n)
	}
	if code, raw := post(postEventBody(t, "a1", "m4", "application", 2, nil, nil, bytes.Repeat([]byte("d"), 300))); code != http.StatusCreated {
		t.Fatalf("post after recovery: status=%d body=%s", code, raw)
	}
	// And the evicted device is an outsider now.
	if code, raw := post(postEventBody(t, "b1", "x", "application", 2, nil, nil, []byte("x"))); code != http.StatusForbidden || errField(t, raw) != "not_a_member" {
		t.Fatalf("evicted device post: status=%d body=%s", code, raw)
	}
}

// Unseeded room: a device that is neither a known reader nor a seated member
// cannot create a cursor by acking.
func TestAckOnUnseededRoomCreatesNoCursor(t *testing.T) {
	t.Run("enforced", func(t *testing.T) {
		pol := testPolicy()
		pol.AppEventTTLSeconds = -1
		r, srv, st, _, first := newEnforcedRelay(t, pol)
		enrollDevice(t, st, first, "a1", "alice")
		enrollDevice(t, st, first, "c1", "carol")
		if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
			postEventBody(t, "a1", "pre", "application", 0, nil, nil, []byte("pre"))); code != http.StatusCreated {
			t.Fatalf("seed app: status=%d body=%s", code, raw)
		}
		// Empty roster: the ack is ignored (no 403 oracle, no row), cursor 0.
		code, raw := doJSON(t, srv, "GET", "/v2/rooms/r/events?device=c1&ack=1", nil)
		if code != http.StatusOK || decodeEventsResponse(t, raw).Cursor != 0 {
			t.Fatalf("outsider ack on unseeded room: status=%d body=%s", code, raw)
		}
		if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_cursors WHERE room = 'r' AND device = 'c1'`); n != 0 {
			t.Fatalf("outsider got a cursor row: %d", n)
		}
		// Only the poster gates: its ack prunes the stale event.
		if code, raw := doJSON(t, srv, "GET", "/v2/rooms/r/events?device=a1&ack=1", nil); code != http.StatusOK {
			t.Fatalf("a1 ack: status=%d body=%s", code, raw)
		}
		if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_events WHERE room = 'r'`); n != 0 {
			t.Fatalf("stale event pinned by a non-reader: %d rows", n)
		}
	})
	t.Run("legacy", func(t *testing.T) {
		pol := testPolicy()
		r, srv := newTestRelay(t, pol)
		if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
			postEventBody(t, "a1", "pre", "application", 0, nil, nil, []byte("pre"))); code != http.StatusCreated {
			t.Fatalf("seed app: status=%d body=%s", code, raw)
		}
		code, raw := doJSON(t, srv, "GET", "/v2/rooms/r/events?device=z9&ack=1", nil)
		if code != http.StatusOK || decodeEventsResponse(t, raw).Cursor != 0 {
			t.Fatalf("legacy unknown reader ack: status=%d body=%s", code, raw)
		}
		if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_cursors WHERE room = 'r' AND device = 'z9'`); n != 0 {
			t.Fatalf("legacy unknown reader got a cursor row: %d", n)
		}
		// badAck still answers 400 for a known reader.
		if code, raw := doJSON(t, srv, "GET", "/v2/rooms/r/events?device=a1&ack=9", nil); code != http.StatusBadRequest || errField(t, raw) != "bad_ack" {
			t.Fatalf("ack beyond last_seq: status=%d body=%s", code, raw)
		}
	})
}

func TestGetEventsPageByteBudget(t *testing.T) {
	pol := testPolicy()
	pol.RoomBytesCap = 64 << 20
	pol.DeviceBytesCap = 256 << 20
	_, srv := newTestRelay(t, pol)
	const rowBytes = 700 << 10 // under maxBodyBytes once base64-encoded? no: 700 KiB raw → ~933 KiB JSON
	payload := bytes.Repeat([]byte("p"), rowBytes)
	for i := 1; i <= 14; i++ {
		id := fmt.Sprintf("m%02d", i)
		targets := []string(nil)
		kind := "application"
		if i == 7 {
			kind, targets = "welcome", []string{"b1"} // invisible to a1, still scanned
		}
		if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", postEventBody(t, "a1", id, kind, 0, nil, targets, payload)); code != http.StatusCreated {
			t.Fatalf("post %s: status=%d body=%s", id, code, raw)
		}
	}
	var got []int64
	after := int64(0)
	pages := 0
	for {
		code, raw := doJSON(t, srv, "GET", fmt.Sprintf("/v2/rooms/r/events?device=a1&after=%d&limit=2000", after), nil)
		if code != http.StatusOK {
			t.Fatalf("page: status=%d body=%s", code, raw)
		}
		page := decodeEventsResponse(t, raw)
		pages++
		var total int
		for _, e := range page.Events {
			total += len(e.Bytes)
			got = append(got, e.Seq)
		}
		if total > maxPageBytes {
			t.Fatalf("page carried %d bytes > budget %d", total, maxPageBytes)
		}
		if page.NextAfter == after {
			break
		}
		after = page.NextAfter
	}
	if pages < 2 {
		t.Fatalf("budget never split the page (%d pages)", pages)
	}
	want := []int64{1, 2, 3, 4, 5, 6, 8, 9, 10, 11, 12, 13, 14}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("paged seqs = %v, want %v (no gap, no repeat)", got, want)
	}
}

func TestResetRoomDryRunDoesNotMigrate(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "native-mls-v2.db")
	old, err := sql.Open("sqlite3", sqliteURI(path))
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
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	sumBefore := sha256.Sum256(before)

	var out strings.Builder
	if code := runResetRoom(&out, dir, "r", false); code != 2 {
		t.Fatalf("dry run exit=%d out=%s", code, out.String())
	}
	if !strings.Contains(out.String(), "rooms=1 events=1 key_packages=0 members=0 cursors=1") {
		t.Fatalf("dry run counts: %s", out.String())
	}
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if sha256.Sum256(after) != sumBefore {
		t.Fatal("dry run modified the database file")
	}
	raw, err := sql.Open("sqlite3", sqliteURI(path))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { raw.Close() })
	var n int
	if err := raw.QueryRow(`SELECT COUNT(*) FROM pragma_table_info('mls_cursors') WHERE name = 'removed_at'`).Scan(&n); err != nil || n != 0 {
		t.Fatalf("dry run migrated mls_cursors (removed_at present=%d err=%v)", n, err)
	}
	if err := raw.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE name = 'mls_members'`).Scan(&n); err != nil || n != 0 {
		t.Fatalf("dry run created mls_members (%d err=%v)", n, err)
	}
	raw.Close()
	// The confirmed run deletes without creating tables either.
	out.Reset()
	if code := runResetRoom(&out, dir, "r", true); code != 0 {
		t.Fatalf("confirmed exit=%d out=%s", code, out.String())
	}
	raw2, err := sql.Open("sqlite3", sqliteURI(path))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { raw2.Close() })
	if err := raw2.QueryRow(`SELECT COUNT(*) FROM mls_events WHERE room = 'r'`).Scan(&n); err != nil || n != 0 {
		t.Fatalf("confirmed reset left %d events err=%v", n, err)
	}
	if err := raw2.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE name = 'mls_members'`).Scan(&n); err != nil || n != 0 {
		t.Fatalf("confirmed reset created mls_members (%d err=%v)", n, err)
	}
}

func TestValidateListen(t *testing.T) {
	for _, tc := range []struct {
		mode, addr string
		ok         bool
	}{
		{accessModeDisabled, "127.0.0.1:1", true},
		{accessModeDisabled, "127.0.0.2:18921", true},
		{accessModeDisabled, "[::1]:1", true},
		{accessModeDisabled, "localhost:1", true},
		{accessModeDisabled, "0.0.0.0:1", false},
		{accessModeDisabled, ":1", false},
		{accessModeDisabled, "[::]:1", false},
		{accessModeDisabled, "192.168.1.5:1", false},
		{accessModeDisabled, "example.com:1", false},
		{accessModeDisabled, "nonsense", false},
		{accessModeRequired, "0.0.0.0:1", true},
		{accessModeRequired, ":1", true},
	} {
		err := validateListen(tc.mode, tc.addr)
		if (err == nil) != tc.ok {
			t.Errorf("validateListen(%s, %q) = %v, want ok=%v", tc.mode, tc.addr, err, tc.ok)
		}
	}
}
