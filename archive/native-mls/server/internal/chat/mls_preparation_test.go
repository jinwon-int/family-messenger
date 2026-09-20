package chat

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

func readySource(t *testing.T, call func(string, string, string, any, string, int) []byte) string {
	t.Helper()
	group := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	call("owner", "POST", "/v1/mls/rooms", mlsCreate{"source", group, "alice-first", "bob-first"}, "alice-first", 201)
	call("family", "POST", "/v1/mls/rooms/source/log", MLSRequest{"kp", "bob-first", group, "key_package", 0, 0, "alice-first", []byte("synthetic opaque package")}, "bob-first", 201)
	call("owner", "POST", "/v1/mls/rooms/source/log", MLSRequest{"welcome", "alice-first", group, "welcome", 1, 0, "bob-first", []byte("synthetic opaque welcome")}, "alice-first", 201)
	call("family", "POST", "/v1/mls/rooms/source/log", MLSRequest{"ack", "bob-first", group, "ack", 2, 1, "alice-first", []byte{}}, "bob-first", 201)
	return group
}
func TestPreparationTwoDeclarationsAndNoBindBypass(t *testing.T) {
	_, _, _, _, call := mlsFixture(t)
	group := readySource(t, call)
	q := contextReservation{"target", "source", group}
	path := "/v1/mls/rooms/target/preparation"
	first := call("owner", "POST", "/v1/mls/context-reservations", q, "alice-first", 201)
	if !bytes.Equal(first, call("owner", "POST", "/v1/mls/context-reservations", q, "alice-first", 200)) {
		t.Fatal("reservation retry")
	}
	call("owner", "POST", "/v1/mls/reservations", map[string]string{"room": "target", "peer_actor": "bob"}, "alice-first", 409)
	bind := mlsCreate{"target", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "alice-first", "bob-first"}
	call("owner", "POST", "/v1/mls/rooms", bind, "alice-first", 409)
	ready := map[string]string{"source_room": "source", "source_group": group, "intent_id": "context-one"}
	one := call("owner", "POST", path, ready, "alice-first", 201)
	if !bytes.Equal(one, call("owner", "POST", path, ready, "alice-first", 200)) {
		t.Fatal("declaration retry")
	}
	call("owner", "POST", path, map[string]string{"source_room": "source", "source_group": group, "intent_id": "changed"}, "alice-first", 409)
	call("owner", "POST", "/v1/mls/rooms", bind, "alice-first", 409)
	call("owner", "POST", path, ready, "bob-first", 403)
	two := call("family", "POST", path, ready, "bob-first", 201)
	var p contextPreparation
	if json.Unmarshal(two, &p) != nil || len(p.Prepared) != 2 {
		t.Fatal("pair barrier")
	}
	call("owner", "POST", "/v1/mls/rooms", bind, "alice-first", 201)
	call("owner", "POST", "/v1/mls/rooms", bind, "alice-first", 200)
	if !bytes.Equal(two, call("family", "POST", path, ready, "bob-first", 200)) {
		t.Fatal("old outcome after bind")
	}
	call("family", "POST", "/v1/mls/rooms/target/log", MLSRequest{"kp2", "bob-first", bind.Group, "key_package", 0, 0, "alice-first", []byte("opaque")}, "bob-first", 201)
}
func TestPreparationAdmissionConflictAndRevocation(t *testing.T) {
	_, a, c, _, call := mlsFixture(t)
	group := readySource(t, call)
	q := contextReservation{"target", "source", group}
	call("family", "POST", "/v1/mls/context-reservations", q, "bob-first", 403)
	call("owner", "POST", "/v1/mls/context-reservations", contextReservation{"target", "source", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}, "alice-first", 403)
	call("owner", "POST", "/v1/mls/reservations", map[string]string{"room": "old", "peer_actor": "bob"}, "alice-first", 201)
	call("owner", "POST", "/v1/mls/context-reservations", contextReservation{"old", "source", group}, "alice-first", 409)
	call("owner", "POST", "/v1/mls/context-reservations", q, "alice-first", 201)
	path := "/v1/mls/rooms/target/preparation"
	call("outsider", "GET", path, nil, "charlie-first", 403)
	call("family", "GET", path, nil, "alice-first", 403)
	call("owner", "GET", path+"?x=1", nil, "alice-first", 400)
	call("owner", "POST", path, map[string]string{"source_room": "other", "source_group": group, "intent_id": "one"}, "alice-first", 409)
	c.Devices[1].Status, c.Devices[1].Revision = "revoked", 2
	if e := a.Replace(c); e != nil {
		t.Fatal(e)
	}
	call("owner", "GET", path, nil, "alice-first", 403)
	call("owner", "POST", "/v1/mls/rooms", mlsCreate{"target", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "alice-first", "bob-first"}, "alice-first", 403)
}
func TestPreparationAtomicReservationAndFailClosedCorruption(t *testing.T) {
	s, _, _, _, call := mlsFixture(t)
	group := readySource(t, call)
	// A failure at the final INSERT must not leave an unguarded reservation.
	s.db.Exec("CREATE TRIGGER deny_preparation BEFORE INSERT ON mls_preparations BEGIN SELECT RAISE(ABORT,'synthetic fault'); END")
	call("owner", "POST", "/v1/mls/context-reservations", contextReservation{"target", "source", group}, "alice-first", 500)
	var n int
	s.db.QueryRow("SELECT count(*) FROM rooms WHERE id='target'").Scan(&n)
	if n != 0 {
		t.Fatal("partial reservation")
	}
	s.db.Exec("DROP TRIGGER deny_preparation")
	call("owner", "POST", "/v1/mls/context-reservations", contextReservation{"target", "source", group}, "alice-first", 201)
	s.db.Exec("UPDATE mls_preparations SET prepared='[{\"device_id\":\"alice-first\",\"intent_id\":\"a\"},{\"device_id\":\"alice-first\",\"intent_id\":\"b\"}]'")
	call("owner", "GET", "/v1/mls/rooms/target/preparation", nil, "alice-first", 422)
	call("owner", "POST", "/v1/mls/rooms", mlsCreate{"target", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "alice-first", "bob-first"}, "alice-first", 422)
	s.db.Exec("DELETE FROM mls_preparations")
	call("owner", "POST", "/v1/mls/rooms", mlsCreate{"target", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "alice-first", "bob-first"}, "alice-first", 422)
	call("owner", "GET", "/v1/mls/rooms/target/context", nil, "alice-first", 422)
	s.db.Exec("DROP TABLE mls_preparations")
	call("owner", "POST", "/v1/mls/rooms", mlsCreate{"target", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "alice-first", "bob-first"}, "alice-first", 500)
}
func TestPreparationConcurrentIntentWriters(t *testing.T) {
	s, _, c, _, call := mlsFixture(t)
	group := readySource(t, call)
	call("owner", "POST", "/v1/mls/context-reservations", contextReservation{"target", "source", group}, "alice-first", 201)
	var wg sync.WaitGroup
	out := make(chan error, 2)
	for _, id := range []string{"one", "two"} {
		wg.Add(1)
		go func(id string) {
			defer wg.Done()
			s.mu.Lock()
			defer s.mu.Unlock()
			p, _, e := s.preparation("target")
			if e == nil {
				e = s.admitPreparation(p, "alice", "alice-first", c.Devices)
			}
			if e == nil {
				_, _, e = s.prepareContext(p, "alice-first", id)
			}
			out <- e
		}(id)
	}
	wg.Wait()
	close(out)
	ok, conflict := 0, 0
	for e := range out {
		if e == nil {
			ok++
		} else if e == ErrConflict {
			conflict++
		} else {
			t.Fatal(e)
		}
	}
	if ok != 1 || conflict != 1 {
		t.Fatal(ok, conflict)
	}
}

func TestPreparationNoncanonicalSourceDeniedBeforeWrite(t *testing.T) {
	s, _, _, _, call := mlsFixture(t)
	group := readySource(t, call)
	var raw []byte
	if e := s.db.QueryRow("SELECT pins FROM mls_rooms WHERE room='source'").Scan(&raw); e != nil {
		t.Fatal(e)
	}
	var pins []MLSPin
	if e := json.Unmarshal(raw, &pins); e != nil {
		t.Fatal(e)
	}
	pins[0], pins[1] = pins[1], pins[0]
	corrupt, _ := json.Marshal(pins)
	if _, e := s.db.Exec("UPDATE mls_rooms SET pins=? WHERE room='source'", corrupt); e != nil {
		t.Fatal(e)
	}
	call("owner", "POST", "/v1/mls/context-reservations", contextReservation{"target", "source", group}, "alice-first", 422)
	var n int
	if e := s.db.QueryRow("SELECT count(*) FROM rooms WHERE id='target'").Scan(&n); e != nil || n != 0 {
		t.Fatal("allocated on corrupt source", n, e)
	}
	if e := s.db.QueryRow("SELECT pins FROM mls_rooms WHERE room='source'").Scan(&raw); e != nil || !bytes.Equal(raw, corrupt) {
		t.Fatal("source changed", e)
	}
}
func TestPreparationV3SnapshotAndRestart(t *testing.T) {
	dir := t.TempDir()
	os.Chmod(dir, 0700)
	s, e := Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	s.CreateRoom("old", "alice", []string{"bob"})
	s.Send("old", "alice", "one", []byte("generated retained message"))
	s.Close()
	db, e := sql.Open("sqlite3", sqliteURI(filepath.Join(dir, "messages.sqlite")))
	if e != nil {
		t.Fatal(e)
	}
	_, e = db.Exec("DROP TABLE mls_successor_lease_events; DROP TABLE mls_successor_closures; DROP TABLE mls_successor_enrolled_events; DROP TABLE mls_successor_enrollments; DROP TABLE mls_successor_retirements; DROP TABLE mls_successor_leases; DROP TABLE mls_successor_confirmation; DROP TABLE mls_successor_handshake; DROP TABLE mls_successor_custody; DROP TABLE mls_successor_reservations; DROP TABLE mls_preparations; ALTER TABLE mls_rooms DROP COLUMN custody_required; PRAGMA user_version=3")
	db.Close()
	if e != nil {
		t.Fatal(e)
	}
	s, e = Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	s.Close()
	files, _ := filepath.Glob(filepath.Join(dir, "snapshots", "v3-before-preparation-*.sqlite"))
	if len(files) != 1 {
		t.Fatal(files)
	}
	db, e = sql.Open("sqlite3", sqliteURI(files[0]))
	if e != nil {
		t.Fatal(e)
	}
	var v, n int
	db.QueryRow("PRAGMA user_version").Scan(&v)
	db.QueryRow("SELECT count(*) FROM messages").Scan(&n)
	db.Close()
	if v != 3 || n != 1 {
		t.Fatal(v, n)
	}
	s, e = Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	m, e := s.History("old", "bob", 0)
	if e != nil || len(m) != 1 {
		t.Fatal(e)
	}
	next, _ := filepath.Glob(filepath.Join(dir, "snapshots", "*.sqlite"))
	if len(next) != 1 {
		t.Fatal("repeated snapshot")
	}
}
