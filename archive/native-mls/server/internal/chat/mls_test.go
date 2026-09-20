package chat

import (
	"bytes"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/jinwon-int/family-messenger/server/internal/access"
)

func mlsFixture(t *testing.T) (*Store, *access.Authority, access.Config, *httptest.Server, func(string, string, string, any, string, int) []byte) {
	t.Helper()
	s, a, c, k, server := accessFixture(t)
	for i, p := range c.People {
		key := bytes.Repeat([]byte{byte(i + 1)}, 32)
		sum := sha256.Sum256(key)
		c.Devices = append(c.Devices, access.Device{ID: p.Actor + "-first", Actor: p.Actor, Subject: p.Subject, SigningKey: hex.EncodeToString(key), Fingerprint: hex.EncodeToString(sum[:]), Status: "active", Revision: 1, Acceptance: "out-of-band-fingerprint"})
	}
	if e := a.Replace(c); e != nil {
		t.Fatal(e)
	}
	call := func(sub, method, path string, q any, device string, want int) []byte {
		t.Helper()
		var body []byte
		if q != nil {
			body, _ = json.Marshal(q)
		}
		token := assertion(t, c, k, sub, time.Now().Add(time.Minute))
		status, b := accessRequest(t, server, token, method, path, body, map[string]string{"X-Family-Device": device})
		if status != want {
			t.Fatalf("%s %s status%d want%d: %s", method, path, status, want, b)
		}
		return b
	}
	return s, a, c, server, call
}
func TestMLSTransportOrderRetryAndRevocation(t *testing.T) {
	s, a, c, _, call := mlsFixture(t)
	group := fmt.Sprintf("%032x", 1)
	create := mlsCreate{"secure", group, "alice-first", "bob-first"}
	call("owner", "POST", "/v1/mls/rooms", create, "alice-first", 201)
	call("owner", "POST", "/v1/mls/rooms", create, "alice-first", 200)
	call("family", "GET", "/v1/mls/rooms/secure/status", nil, "alice-first", 403)
	call("outsider", "GET", "/v1/mls/rooms/secure/status", nil, "charlie-first", 403)
	for _, path := range []string{"messages", "events", "attachments"} {
		call("owner", "GET", "/v1/rooms/secure/"+path, nil, "alice-first", 403)
	}
	call("owner", "DELETE", "/v1/rooms/secure/members/bob", nil, "alice-first", 403)
	if bytes.Contains(call("owner", "GET", "/v1/rooms", nil, "alice-first", 200), []byte("secure")) {
		t.Fatal("legacy UI sees MLS room")
	}
	req := func(id, device, kind, target string, rev, epoch int64) MLSRequest {
		return MLSRequest{id, device, group, kind, rev, epoch, target, []byte("synthetic opaque wire")}
	}
	premature := req("early", "alice-first", "application", "", 0, 0)
	call("owner", "POST", "/v1/mls/rooms/secure/log", premature, "alice-first", 409)
	kp := req("kp", "bob-first", "key_package", "alice-first", 0, 0)
	first := call("family", "POST", "/v1/mls/rooms/secure/log", kp, "bob-first", 201)
	if !bytes.Equal(first, call("family", "POST", "/v1/mls/rooms/secure/log", kp, "bob-first", 200)) {
		t.Fatal("retry output drift")
	}
	bad := kp
	bad.Payload = []byte("different")
	call("family", "POST", "/v1/mls/rooms/secure/log", bad, "bob-first", 409)
	welcome := req("welcome", "alice-first", "welcome", "bob-first", 1, 0)
	call("owner", "POST", "/v1/mls/rooms/secure/log", welcome, "alice-first", 201)
	ack := req("ack", "bob-first", "ack", "alice-first", 2, 1)
	ack.Payload = []byte{}
	call("family", "POST", "/v1/mls/rooms/secure/log", ack, "bob-first", 201)
	app := req("app", "alice-first", "application", "", 3, 1)
	original := call("owner", "POST", "/v1/mls/rooms/secure/log", app, "alice-first", 201)
	var logs []MLSEvent
	json.Unmarshal(call("family", "GET", "/v1/mls/rooms/secure/log?after=0", nil, "bob-first", 200), &logs)
	if len(logs) != 4 || logs[3].Seq != 4 || logs[3].Epoch != 1 {
		t.Fatal("order")
	}
	call("owner", "GET", "/v1/mls/rooms/secure/log?after=5", nil, "alice-first", 400)
	commit := req("commit", "alice-first", "commit", "bob-first", 3, 1)
	call("owner", "POST", "/v1/mls/rooms/secure/log", commit, "alice-first", 201)
	stale := app
	stale.ID = "old-epoch"
	call("owner", "POST", "/v1/mls/rooms/secure/log", stale, "alice-first", 409)
	if !bytes.Equal(original, call("owner", "POST", "/v1/mls/rooms/secure/log", app, "alice-first", 200)) {
		t.Fatal("accepted old outcome cannot reconcile")
	}
	// Existing bindings must remain active even for cached-output reconciliation.
	c.Devices[1].Status = "revoked"
	c.Devices[1].Revision = 2
	if e := a.Replace(c); e != nil {
		t.Fatal(e)
	}
	call("owner", "POST", "/v1/mls/rooms/secure/log", app, "alice-first", 403)
	call("family", "GET", "/v1/mls/rooms/secure/log", nil, "bob-first", 403)
	s.mu.Lock()
	var n int
	s.db.QueryRow("SELECT count(*) FROM mls_events").Scan(&n)
	s.mu.Unlock()
	if n != 5 {
		t.Fatal(n)
	}
}
func TestMLSConcurrentCASIntegrityAndLimits(t *testing.T) {
	s, _, c, _, _ := mlsFixture(t)
	group := fmt.Sprintf("%032x", 2)
	s.mu.Lock()
	room, _, e := s.createMLS(mlsCreate{"secure", group, "alice-first", "bob-first"}, "alice", c.Devices)
	s.mu.Unlock()
	if e != nil {
		t.Fatal(e)
	}
	q := MLSRequest{"kp", "bob-first", group, "key_package", 0, 0, "alice-first", []byte("kp")}
	var wg sync.WaitGroup
	results := make(chan bool, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			s.mu.Lock()
			defer s.mu.Unlock()
			r, _ := s.mlsRoom(room.Room)
			candidate := q
			candidate.ID = fmt.Sprint("kp", i)
			_, created, e := s.appendMLS(r, candidate)
			results <- e == nil && created
		}(i)
	}
	wg.Wait()
	close(results)
	wins := 0
	for x := range results {
		if x {
			wins++
		}
	}
	if wins != 1 {
		t.Fatal("CAS wins", wins)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	r, _ := s.mlsRoom(room.Room)
	welcome := MLSRequest{"welcome", "alice-first", group, "welcome", 1, 0, "bob-first", bytes.Repeat([]byte{1}, MLSMaxWire+1)}
	if _, _, e = s.appendMLS(r, welcome); e != ErrInvalid {
		t.Fatal(e)
	}
	welcome.Payload = []byte("w")
	if _, _, e = s.appendMLS(r, welcome); e != nil {
		t.Fatal(e)
	}
	// Damaged opaque bytes must fail retry and history, not be delivered silently.
	s.db.Exec("UPDATE mls_events SET request=? WHERE client_id='welcome'", []byte(`{}`))
	if _, _, e = s.appendMLS(r, welcome); e != ErrIntegrity {
		t.Fatal("corrupt retry", e)
	}
	if _, e = s.mlsHistory(r, "alice-first", 0); e != ErrIntegrity {
		t.Fatal("corrupt history", e)
	}
}
func TestMLSStrictInputAndLegacySeparation(t *testing.T) {
	_, _, _, server, call := mlsFixture(t)
	group := fmt.Sprintf("%032x", 3)
	call("owner", "POST", "/v1/rooms", map[string]any{"id": "legacy", "members": []string{"bob"}}, "alice-first", 201)
	call("owner", "POST", "/v1/mls/rooms", mlsCreate{"legacy", group, "alice-first", "bob-first"}, "alice-first", 409)
	call("owner", "POST", "/v1/mls/rooms", mlsCreate{"secure", group, "alice-first", "bob-first"}, "alice-first", 201)
	call("owner", "POST", "/v1/mls/rooms", mlsCreate{"other", group, "alice-first", "bob-first"}, "alice-first", 409)
	// Parse boundary tested directly so exact aliases and duplicate keys cannot
	// be confused with assertion rejection by an invalid fixture token.
	for _, raw := range []string{`{"room":"a","room":"b","group_id":"x","device_id":"a","peer_device":"b"}`, `{"Room":"a","group_id":"x","device_id":"a","peer_device":"b"}`, `{"room":null,"group_id":"x","device_id":"a","peer_device":"b"}`, `{"room":"a"}`} {
		r := httptest.NewRequest("POST", "/", bytes.NewBufferString(raw))
		r.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		var out mlsCreate
		if decodeMLS(w, r, &out, "room", "group_id", "device_id", "peer_device") {
			t.Fatal("accepted", raw)
		}
	}
	_ = server
}
func TestMLSSchemaSnapshotRestartPreservesLegacy(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "state")
	os.Mkdir(dir, 0700)
	s, e := Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	s.CreateRoom("old", "alice", []string{"bob"})
	s.Send("old", "alice", "one", []byte("synthetic"))
	s.Close()
	// Construct the exact previous additive schema without deleting any files.
	db, e := sql.Open("sqlite3", sqliteURI(filepath.Join(dir, "messages.sqlite")))
	if e != nil {
		t.Fatal(e)
	}
	_, e = db.Exec("DROP TABLE mls_successor_lease_events; DROP TABLE mls_successor_closures; DROP TABLE mls_successor_enrolled_events; DROP TABLE mls_successor_enrollments; DROP TABLE mls_successor_retirements; DROP TABLE mls_successor_leases; DROP TABLE mls_successor_confirmation; DROP TABLE mls_successor_handshake; DROP TABLE mls_successor_custody; DROP TABLE mls_successor_reservations; DROP TABLE mls_preparations; DROP TABLE mls_events; DROP TABLE mls_rooms; PRAGMA user_version=2")
	db.Close()
	if e != nil {
		t.Fatal(e)
	}
	s, e = Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	s.Close()
	snapshots, _ := filepath.Glob(filepath.Join(dir, "snapshots", "v2-before-mls-*.sqlite"))
	if len(snapshots) != 1 {
		t.Fatal(snapshots)
	}
	st, _ := os.Stat(snapshots[0])
	if st.Mode().Perm() != 0600 {
		t.Fatal("snapshot mode")
	}
	db, e = sql.Open("sqlite3", sqliteURI(snapshots[0]))
	if e != nil {
		t.Fatal(e)
	}
	var version, n int
	db.QueryRow("PRAGMA user_version").Scan(&version)
	db.QueryRow("SELECT count(*) FROM messages").Scan(&n)
	db.Close()
	if version != 2 || n != 1 {
		t.Fatal(version, n)
	}
	s, e = Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	messages, e := s.History("old", "bob", 0)
	if e != nil || len(messages) != 1 {
		t.Fatal(e)
	}
	next, _ := filepath.Glob(filepath.Join(dir, "snapshots", "*.sqlite"))
	if len(next) != 1 {
		t.Fatal("repeated snapshot")
	}
}

type mlsGateBody struct {
	started, release chan struct{}
	reader           *bytes.Reader
	once             sync.Once
}

func (b *mlsGateBody) Read(p []byte) (int, error) {
	b.once.Do(func() { close(b.started); <-b.release })
	return b.reader.Read(p)
}
func (b *mlsGateBody) Close() error { return nil }

type mlsDeadlineRecorder struct{ *httptest.ResponseRecorder }

func (w mlsDeadlineRecorder) SetReadDeadline(time.Time) error  { return nil }
func (w mlsDeadlineRecorder) SetWriteDeadline(time.Time) error { return nil }
func TestMLSSlowBodyCannotHoldRevocationOrUseRetiredGrant(t *testing.T) {
	s, a, c, k, _ := accessFixture(t)
	for i, p := range c.People {
		raw := bytes.Repeat([]byte{byte(i + 1)}, 32)
		sum := sha256.Sum256(raw)
		c.Devices = append(c.Devices, access.Device{ID: p.Actor + "-first", Actor: p.Actor, Subject: p.Subject, SigningKey: hex.EncodeToString(raw), Fingerprint: hex.EncodeToString(sum[:]), Status: "active", Revision: 1, Acceptance: "out-of-band-fingerprint"})
	}
	if e := a.Replace(c); e != nil {
		t.Fatal(e)
	}
	group := fmt.Sprintf("%032x", 9)
	s.mu.Lock()
	_, _, e := s.createMLS(mlsCreate{"events", group, "alice-first", "bob-first"}, "alice", c.Devices)
	s.mu.Unlock()
	if e != nil {
		t.Fatal(e)
	}
	q := MLSRequest{"kp", "bob-first", group, "key_package", 0, 0, "alice-first", []byte("opaque")}
	raw, _ := json.Marshal(q)
	body := &mlsGateBody{make(chan struct{}), make(chan struct{}), bytes.NewReader(raw), sync.Once{}}
	r := httptest.NewRequest("POST", "http://127.0.0.1:1234/v1/mls/rooms/events/log", body)
	r.Header.Set("Cf-Access-Jwt-Assertion", assertion(t, c, k, "family", time.Now().Add(time.Minute)))
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("X-Family-Device", "bob-first")
	w := mlsDeadlineRecorder{httptest.NewRecorder()}
	handler, _ := NewAccessHandler(s, a, nil)
	done := make(chan struct{})
	go func() { handler.ServeHTTP(w, r); close(done) }()
	select {
	case <-body.started:
	case <-time.After(3 * time.Second):
		t.Fatal("body not read")
	}
	c.Devices[1].Status = "revoked"
	c.Devices[1].Revision = 2
	replaced := make(chan error, 1)
	go func() { replaced <- a.Replace(c) }()
	select {
	case e := <-replaced:
		if e != nil {
			t.Fatal(e)
		}
	case <-time.After(3 * time.Second):
		close(body.release)
		t.Fatal("network body held authority")
	}
	close(body.release)
	<-done
	if w.Code != 403 {
		t.Fatal("retired grant admitted room named events", w.Code)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	var n int
	s.db.QueryRow("SELECT count(*) FROM mls_events").Scan(&n)
	if n != 0 {
		t.Fatal("revoked append committed")
	}
}
func TestMLSRoomCapacityRetainsExactRetries(t *testing.T) {
	s, _, c, _, _ := mlsFixture(t)
	s.mu.Lock()
	defer s.mu.Unlock()
	group := fmt.Sprintf("%032x", 10)
	_, _, e := s.createMLS(mlsCreate{"capacity", group, "alice-first", "bob-first"}, "alice", c.Devices)
	if e != nil {
		t.Fatal(e)
	}
	requests := []MLSRequest{{"kp", "bob-first", group, "key_package", 0, 0, "alice-first", []byte("k")}, {"w", "alice-first", group, "welcome", 1, 0, "bob-first", []byte("w")}, {"ack", "bob-first", group, "ack", 2, 1, "alice-first", []byte{}}}
	for _, q := range requests {
		r, _ := s.mlsRoom("capacity")
		if _, _, e = s.appendMLS(r, q); e != nil {
			t.Fatal(e)
		}
	}
	for i := 3; i < MLSMaxRoomEvents; i++ {
		r, _ := s.mlsRoom("capacity")
		q := MLSRequest{fmt.Sprint("app", i), "alice-first", group, "application", 3, 1, "", []byte("opaque")}
		if _, _, e = s.appendMLS(r, q); e != nil {
			t.Fatal(e)
		}
	}
	r, _ := s.mlsRoom("capacity")
	q := MLSRequest{"overflow", "alice-first", group, "application", 3, 1, "", []byte("opaque")}
	if _, _, e = s.appendMLS(r, q); e != ErrLimit {
		t.Fatal("limit", e)
	}
	q.ID = "app3"
	if _, created, e := s.appendMLS(r, q); e != nil || created {
		t.Fatal("exact retry lost at capacity", e)
	}
}

func TestMLSStoreBoundaryAfterStaleLegacyCheck(t *testing.T) {
	s := testStore(t)
	// Deterministic schedule from the independently reproduced signed HTTP race:
	// early route admits absent ID, then reservation wins before actual operation.
	s.mu.Lock()
	if e := s.legacyRoom("raced"); e != nil {
		t.Fatal(e)
	}
	_, e := s.reserveMLS("raced", "alice", "bob")
	s.mu.Unlock()
	if e != nil {
		t.Fatal(e)
	}
	if _, _, e = s.Send("raced", "alice", "plain", []byte("synthetic")); e != ErrForbidden {
		t.Fatal("plaintext bypass", e)
	}
	if e = s.SetMember("raced", "alice", "charlie", true); e != ErrForbidden {
		t.Fatal("membership bypass", e)
	}
	if _, e = s.History("raced", "alice", 0); e != ErrForbidden {
		t.Fatal("history bypass", e)
	}
	meta := mediaMeta("file", []byte("x"))
	meta.Room = "raced"
	if _, e = s.beginMedia(meta); e != ErrForbidden {
		t.Fatal("media upload bypass", e)
	}
	if _, _, _, e = s.loadMedia("raced", "alice", fmt.Sprintf("%032x", 1)); e != ErrForbidden {
		t.Fatal("media download bypass", e)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, e = s.listMedia("raced", "alice"); e != ErrForbidden {
		t.Fatal("media listing bypass", e)
	}
	if e = s.mediaAuthorized("raced", "alice", 0); e != ErrForbidden {
		t.Fatal("media transfer bypass", e)
	}
	var count int
	s.db.QueryRow("SELECT count(*) FROM messages WHERE room='raced'").Scan(&count)
	if count != 0 {
		t.Fatal("plaintext persisted")
	}
}
