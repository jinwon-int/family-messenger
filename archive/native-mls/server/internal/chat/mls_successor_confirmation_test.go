package chat

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"github.com/jinwon-int/family-messenger/server/internal/access"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

const confirmationPath = "/v1/mls/successors/replace-one/confirmation"

func confirmationReady(t *testing.T, call func(string, string, string, any, string, int) []byte) (successorReservation, []successorHandshakeRequest) {
	t.Helper()
	p, q := handshakeReserve(t, call)
	handshakePair(t, call, q)
	qs := handshakeRequests(q)
	for i, r := range qs {
		who, device := "owner", "alice-next"
		if i == 1 {
			who, device = "family", "bob-first"
		}
		call(who, "POST", handshakePath, r, device, 201)
	}
	return p, []successorHandshakeRequest{{q.ID, q.ContextSHA, "candidate_proof", qs[1].Group, []byte("opaque candidate MLS")}, {q.ID, q.ContextSHA, "peer_proof", qs[1].Group, []byte("opaque peer MLS")}}
}
func TestSuccessorConfirmationOrderIdentityBoundsAndInactive(t *testing.T) {
	_, _, _, call := successorContextFixture(t)
	call("owner", "GET", confirmationPath, nil, "alice-next", 403)
	_, qs := confirmationReady(t, call)
	legacy := call("owner", "GET", handshakePath, nil, "alice-next", 200)
	call("family", "POST", confirmationPath, qs[1], "bob-first", 409)
	call("family", "POST", confirmationPath, qs[0], "bob-first", 403)
	for _, path := range []string{confirmationPath + "?", confirmationPath + "?a=1"} {
		call("owner", "GET", path, nil, "alice-next", 400)
	}
	for _, mutation := range []func(*successorHandshakeRequest){func(q *successorHandshakeRequest) { q.Kind = "ack" }, func(q *successorHandshakeRequest) { q.Payload = []byte{} }, func(q *successorHandshakeRequest) { q.Payload = bytes.Repeat([]byte{1}, 4097) }} {
		q := qs[0]
		mutation(&q)
		call("owner", "POST", confirmationPath, q, "alice-next", 400)
	}
	for _, mutation := range []func(*successorHandshakeRequest){func(q *successorHandshakeRequest) { q.Reservation = "other" }, func(q *successorHandshakeRequest) { q.ContextSHA = "aa" }, func(q *successorHandshakeRequest) { q.Group = "abababababababababababababababab" }} {
		q := qs[0]
		mutation(&q)
		call("owner", "POST", confirmationPath, q, "alice-next", 409)
	}
	for _, payload := range []any{[]int{1, 2}, nil, "YQ==\n"} {
		call("owner", "POST", confirmationPath, map[string]any{"reservation_id": qs[0].Reservation, "context_sha256": qs[0].ContextSHA, "kind": "candidate_proof", "group_id": qs[0].Group, "payload": payload}, "alice-next", 400)
	}
	for i, q := range qs {
		who, device := "owner", "alice-next"
		if i == 1 {
			who, device = "family", "bob-first"
		}
		raw := call(who, "POST", confirmationPath, q, device, 201)
		if !bytes.Equal(raw, call(who, "POST", confirmationPath, q, device, 200)) {
			t.Fatal("unstable retry")
		}
		bad := q
		bad.Payload = []byte("different")
		call(who, "POST", confirmationPath, bad, device, 409)
	}
	raw := call("owner", "GET", confirmationPath, nil, "alice-next", 200)
	var v successorHandshake
	if json.Unmarshal(raw, &v) != nil || v.Revision != 2 || v.Phase != "confirmations-recorded-inactive" {
		t.Fatal(v)
	}
	if !bytes.Equal(legacy, call("owner", "GET", handshakePath, nil, "alice-next", 200)) {
		t.Fatal("changed Welcome transcript")
	}
	for _, path := range []string{"/v1/mls/rooms/target/log", "/v1/rooms/target/messages"} {
		call("owner", "GET", path, nil, "alice-next", 403)
	}
}
func TestSuccessorConfirmationCASConflictAndRestart(t *testing.T) {
	s, _, _, call := successorContextFixture(t)
	p, qs := confirmationReady(t, call)
	for i, q := range qs {
		var wg sync.WaitGroup
		var created int
		var first []byte
		for n := 0; n < 8; n++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				s.mu.Lock()
				defer s.mu.Unlock()
				pin := handshakePin(p, i)
				v, new, e := s.appendSuccessorConfirmation(p, pin.Actor, pin.ID, q)
				if e != nil {
					t.Error(e)
					return
				}
				if new {
					created++
				}
				raw, _ := json.Marshal(v)
				if first == nil {
					first = raw
				} else if !bytes.Equal(first, raw) {
					t.Error("divergent response")
				}
			}()
		}
		wg.Wait()
		if created != 1 {
			t.Fatal(created)
		}
	}
	var path string
	s.db.QueryRow("SELECT file FROM pragma_database_list WHERE name='main'").Scan(&path)
	before, _, _ := s.successorConfirmation(p)
	s.Close()
	next, e := Open(filepath.Dir(path))
	if e != nil {
		t.Fatal(e)
	}
	defer next.Close()
	after, created, e := next.appendSuccessorConfirmation(p, "alice", "alice-next", qs[0])
	x, _ := json.Marshal(before)
	y, _ := json.Marshal(after)
	if e != nil || created || !bytes.Equal(x, y) {
		t.Fatal("restart reset", e)
	}
}
func TestSuccessorConfirmationAuthorityAndCorruptionRetained(t *testing.T) {
	for _, kind := range []string{"peer", "actor", "admin", "expiry", "source", "missing", "json", "digest"} {
		t.Run(kind, func(t *testing.T) {
			s, a, c, call := successorContextFixture(t, func(c *access.Config) {
				if kind == "expiry" {
					c.Successors.Intents[0].ExpiresAt = time.Now().Unix() + 3
				}
			})
			_, qs := confirmationReady(t, call)
			call("owner", "POST", confirmationPath, qs[0], "alice-next", 201)
			switch kind {
			case "peer":
				c.Devices[1].Status = "revoked"
				c.Devices[1].Revision = 2
			case "actor":
				c.People = c.People[1:]
			case "admin":
				c.Successors.Administrators = nil
			case "expiry":
				time.Sleep(time.Until(time.Unix(c.Successors.Intents[0].ExpiresAt, 0)))
			case "source":
				s.db.Exec("UPDATE mls_rooms SET phase='ack' WHERE room='source'")
			case "missing":
				s.db.Exec("DELETE FROM mls_successor_confirmation")
			case "json":
				s.db.Exec("UPDATE mls_successor_confirmation SET transcript=?", []byte("{"))
			case "digest":
				var raw []byte
				s.db.QueryRow("SELECT transcript FROM mls_successor_confirmation").Scan(&raw)
				var rs []successorHandshakeRecord
				json.Unmarshal(raw, &rs)
				rs[0].SHA = "bad"
				raw, _ = json.Marshal(rs)
				s.db.Exec("UPDATE mls_successor_confirmation SET transcript=?", raw)
			}
			if kind == "peer" || kind == "actor" || kind == "admin" {
				if e := a.Replace(c); e != nil {
					t.Fatal(e)
				}
			}
			var before []byte
			s.db.QueryRow("SELECT transcript FROM mls_successor_confirmation").Scan(&before)
			status := 403
			if kind == "missing" || kind == "json" || kind == "digest" {
				status = 422
			}
			call("family", "GET", confirmationPath, nil, "bob-first", status)
			call("family", "POST", confirmationPath, qs[1], "bob-first", status)
			var after []byte
			e := s.db.QueryRow("SELECT transcript FROM mls_successor_confirmation").Scan(&after)
			if kind == "missing" {
				if e != sql.ErrNoRows {
					t.Fatal("recreated missing row")
				}
			} else if e != nil || !bytes.Equal(before, after) {
				t.Fatal("changed denied state", e)
			}
		})
	}
}
func TestSuccessorConfirmationV7MigrationKeepsCompleteHandshake(t *testing.T) {
	s, _, _, call := successorContextFixture(t)
	p, _ := confirmationReady(t, call)
	before, _, _ := s.successorHandshake(p)
	var path string
	s.db.QueryRow("SELECT file FROM pragma_database_list WHERE name='main'").Scan(&path)
	if _, e := s.db.Exec("DROP TABLE mls_successor_lease_events; DROP TABLE mls_successor_closures; DROP TABLE mls_successor_enrolled_events; DROP TABLE mls_successor_enrollments; DROP TABLE mls_successor_retirements; DROP TABLE mls_successor_leases; DROP TABLE mls_successor_confirmation; PRAGMA user_version=7"); e != nil {
		t.Fatal(e)
	}
	s.Close()
	dir := filepath.Dir(path)
	next, e := Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	after, _, e := next.successorHandshake(p)
	x, _ := json.Marshal(before)
	y, _ := json.Marshal(after)
	if e != nil || !bytes.Equal(x, y) {
		t.Fatal("handshake changed", e)
	}
	proof, _, e := next.successorConfirmation(p)
	if e != nil || proof.Revision != 0 {
		t.Fatal(e)
	}
	paths, _ := filepath.Glob(filepath.Join(dir, "snapshots", "v7-before-successor-confirmation-*.sqlite"))
	if len(paths) != 1 {
		t.Fatal(paths)
	}
	st, e := os.Stat(paths[0])
	if e != nil || st.Mode().Perm() != 0600 {
		t.Fatal(e)
	}
	db, e := sql.Open("sqlite3", sqliteURI(paths[0]))
	if e != nil {
		t.Fatal(e)
	}
	defer db.Close()
	var version, n int
	db.QueryRow("PRAGMA user_version").Scan(&version)
	db.QueryRow("SELECT count(*) FROM mls_successor_handshake").Scan(&n)
	if version != 7 || n != 1 {
		t.Fatal(version, n)
	}
	next.Close()
	again, e := Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	defer again.Close()
}
