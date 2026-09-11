package chat

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/jinwon-int/family-messenger/server/internal/access"
)

const successorCustodyPath = "/v1/mls/successors/replace-one/custody"

func custodyRequest(q successorReservationRequest, role string) successorDeclarationRequest {
	return successorDeclarationRequest{q.ID, q.ContextSHA, role, role + "-committed"}
}
func readCustody(t *testing.T, b []byte) successorCustody {
	t.Helper()
	var v successorCustody
	if e := json.Unmarshal(b, &v); e != nil {
		t.Fatal(e)
	}
	return v
}

func TestSuccessorCustodyBothOrdersExactRetryAndNoActivation(t *testing.T) {
	for _, firstRole := range []string{"candidate", "peer"} {
		t.Run(firstRole, func(t *testing.T) {
			s, _, _, call := successorContextFixture(t)
			q := reservationRequest(t, call("owner", "GET", successorPath, nil, "alice-next", 200))
			call("owner", "GET", successorCustodyPath, nil, "alice-next", 403)
			reserved := call("owner", "POST", successorReservationPath, q, "alice-next", 201)
			before, _ := s.mlsRoom("source")
			v := readCustody(t, call("family", "GET", successorCustodyPath, nil, "bob-first", 200))
			if v.Revision != 0 || v.Phase != "custody-pending" || v.Declarations == nil {
				t.Fatal(v)
			}
			roles := []string{"candidate", "peer"}
			if firstRole == "peer" {
				roles = []string{"peer", "candidate"}
			}
			for index, role := range roles {
				actor, device := "owner", "alice-next"
				if role == "peer" {
					actor, device = "family", "bob-first"
				}
				r := custodyRequest(q, role)
				first := call(actor, "POST", successorCustodyPath, r, device, 201)
				if !bytes.Equal(first, call(actor, "POST", successorCustodyPath, r, device, 200)) {
					t.Fatal("retry drift")
				}
				v = readCustody(t, first)
				if v.Revision != index+1 || len(v.Declarations) != index+1 {
					t.Fatal(v)
				}
				if !bytes.Equal(reserved, call(actor, "GET", successorReservationPath, nil, device, 200)) || !bytes.Equal(reserved, call(actor, "POST", successorReservationPath, q, device, 200)) {
					t.Fatal("custody changed immutable reservation")
				}
			}
			if v.Phase != "pair-declared-inactive" || v.Declarations[0].Role != "candidate" || v.Declarations[1].Role != "peer" {
				t.Fatal(v)
			}
			// An old exact declaration retry reconciles current readiness, retaining
			// the exact per-role receipt even after its peer declared.
			if got := readCustody(t, call("owner", "POST", successorCustodyPath, custodyRequest(q, "candidate"), "alice-next", 200)); got.Revision != 2 {
				t.Fatal(got)
			}
			for _, who := range [][2]string{{"owner", "alice-next"}, {"family", "bob-first"}} {
				for _, path := range []string{"/v1/mls/rooms/target/log", "/v1/mls/rooms/target/context", "/v1/mls/rooms/target/preparation", "/v1/rooms/target/messages", "/v1/mls/rooms/source/log"} {
					call(who[0], "GET", path, nil, who[1], 403)
				}
				call(who[0], "POST", "/v1/mls/rooms", mlsCreate{"target", "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd", "alice-next", "bob-first"}, who[1], 403)
			}
			after, _ := s.mlsRoom("source")
			b, _ := json.Marshal(before)
			a, _ := json.Marshal(after)
			if !bytes.Equal(b, a) {
				t.Fatal("source changed")
			}
		})
	}
}

func TestSuccessorCustodyWrongRoleBindingsAndStrictWire(t *testing.T) {
	_, _, _, call := successorContextFixture(t)
	q := reservationRequest(t, call("owner", "GET", successorPath, nil, "alice-next", 200))
	call("owner", "POST", successorReservationPath, q, "alice-next", 201)
	r := custodyRequest(q, "candidate")
	for _, who := range [][2]string{{"owner", "alice-first"}, {"family", "alice-next"}, {"outsider", "charlie-first"}, {"family", "bob-first"}} {
		call(who[0], "POST", successorCustodyPath, r, who[1], 403)
	}
	call("owner", "POST", successorCustodyPath, custodyRequest(q, "peer"), "alice-next", 403)
	for _, field := range []string{"id", "hash", "role", "declaration"} {
		wrong := r
		code := 409
		switch field {
		case "id":
			wrong.Reservation = "wrong"
		case "hash":
			wrong.ContextSHA = digestMLS([]byte("substituted key/package/room"))
		case "role":
			wrong.Role = "owner"
			code = 400
		case "declaration":
			wrong.ID = "../bad"
			code = 400
		}
		call("owner", "POST", successorCustodyPath, wrong, "alice-next", code)
	}
	for _, path := range []string{successorCustodyPath + "?", successorCustodyPath + "?x=1"} {
		call("owner", "POST", path, r, "alice-next", 400)
	}
	call("owner", "PUT", successorCustodyPath, r, "alice-next", 400)
	call("owner", "POST", successorCustodyPath, map[string]any{"reservation_id": q.ID, "context_sha256": q.ContextSHA, "role": "candidate", "declaration_id": "one", "extra": 1}, "alice-next", 400)
	call("owner", "POST", successorCustodyPath, r, "alice-next", 201)
	r.ID = "another-id"
	call("owner", "POST", successorCustodyPath, r, "alice-next", 409)
	if got := readCustody(t, call("owner", "GET", successorCustodyPath, nil, "alice-next", 200)); got.Revision != 1 {
		t.Fatal(got)
	}
}

func TestSuccessorCustodyFreshAdmissionRetainsDeclarations(t *testing.T) {
	for _, kind := range []string{"actor", "admin", "peer", "subject", "expiry", "source"} {
		t.Run(kind, func(t *testing.T) {
			s, a, c, call := successorContextFixture(t, func(c *access.Config) {
				if kind == "expiry" {
					c.Successors.Intents[0].ExpiresAt = time.Now().Unix() + 3
				}
			})
			q := reservationRequest(t, call("owner", "GET", successorPath, nil, "alice-next", 200))
			call("owner", "POST", successorReservationPath, q, "alice-next", 201)
			r := custodyRequest(q, "candidate")
			call("owner", "POST", successorCustodyPath, r, "alice-next", 201)
			var before []byte
			s.db.QueryRow("SELECT declarations FROM mls_successor_custody").Scan(&before)
			switch kind {
			case "actor":
				c.People = c.People[1:]
			case "admin":
				c.Successors.Administrators = nil
			case "peer":
				c.Devices[1].Status = "revoked"
				c.Devices[1].Revision = 2
			case "subject":
				c.People[0].Subject = "changed"
			case "expiry":
				time.Sleep(time.Until(time.Unix(c.Successors.Intents[0].ExpiresAt, 0)))
			case "source":
				s.db.Exec("UPDATE mls_rooms SET phase='ack' WHERE room='source'")
			}
			if kind != "expiry" {
				if e := a.Replace(c); e != nil {
					t.Fatal(e)
				}
			}
			call("family", "GET", successorCustodyPath, nil, "bob-first", 403)
			call("family", "POST", successorCustodyPath, custodyRequest(q, "peer"), "bob-first", 403)
			var after []byte
			s.db.QueryRow("SELECT declarations FROM mls_successor_custody").Scan(&after)
			if !bytes.Equal(before, after) {
				t.Fatal("denial mutated committed declaration")
			}
		})
	}
}

func TestSuccessorCustodyConflictsConcurrencyAndFailedCommit(t *testing.T) {
	s, _, _, call := successorContextFixture(t)
	q := reservationRequest(t, call("owner", "GET", successorPath, nil, "alice-next", 200))
	var p successorReservation
	json.Unmarshal(call("owner", "POST", successorReservationPath, q, "alice-next", 201), &p)
	// SQLite abort before durable update must not release a successful receipt.
	if _, e := s.db.Exec("CREATE TRIGGER fail_custody BEFORE UPDATE ON mls_successor_custody BEGIN SELECT RAISE(ABORT,'fixture'); END"); e != nil {
		t.Fatal(e)
	}
	if _, created, e := s.declareSuccessor(p, "alice", "alice-next", custodyRequest(q, "candidate")); e == nil || created {
		t.Fatal("failed commit acknowledged")
	}
	s.db.Exec("DROP TRIGGER fail_custody")
	var wg sync.WaitGroup
	var mu sync.Mutex
	wins, retries, conflicts := 0, 0, 0
	for n := range 24 {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			role, actor, device := "candidate", "alice", "alice-next"
			if n%2 == 1 {
				role, actor, device = "peer", "bob", "bob-first"
			}
			r := custodyRequest(q, role)
			if n >= 12 {
				r.ID = "conflict"
			}
			s.mu.Lock()
			_, created, e := s.declareSuccessor(p, actor, device, r)
			s.mu.Unlock()
			mu.Lock()
			defer mu.Unlock()
			if e == ErrConflict {
				conflicts++
			} else if e != nil {
				t.Error(e)
			} else if created {
				wins++
			} else {
				retries++
			}
		}(n)
	}
	wg.Wait()
	if wins != 2 || retries != 10 || conflicts != 12 {
		t.Fatal(wins, retries, conflicts)
	}
	v, _, e := s.successorCustody(p)
	if e != nil || v.Revision != 2 {
		t.Fatal(v, e)
	}
}

func TestSuccessorCustodyCorruptMissingAndSwappedRowsRetained(t *testing.T) {
	for _, mutation := range []string{"missing", "null", "alias", "order", "duplicate", "device", "binding", "reservation"} {
		t.Run(mutation, func(t *testing.T) {
			s, _, _, call := successorContextFixture(t)
			q := reservationRequest(t, call("owner", "GET", successorPath, nil, "alice-next", 200))
			call("owner", "POST", successorReservationPath, q, "alice-next", 201)
			var raw []byte
			call("owner", "POST", successorCustodyPath, custodyRequest(q, "candidate"), "alice-next", 201)
			v := readCustody(t, call("family", "POST", successorCustodyPath, custodyRequest(q, "peer"), "bob-first", 201))
			d := v.Declarations
			switch mutation {
			case "missing":
				s.db.Exec("DELETE FROM mls_successor_custody")
			case "null":
				raw = []byte("null")
			case "alias":
				raw = []byte("[] ")
			case "order":
				d[0], d[1] = d[1], d[0]
			case "duplicate":
				d[1] = d[0]
			case "device":
				d[0].Device = "alice-first"
			case "binding":
				d[0].ContextSHA = digestMLS([]byte("different package"))
			case "reservation":
				d[0].Reservation = "different-reservation"
			}
			if mutation != "missing" {
				if raw == nil {
					raw, _ = json.Marshal(d)
				}
				if _, e := s.db.Exec("UPDATE mls_successor_custody SET declarations=?", raw); e != nil {
					t.Fatal(e)
				}
			}
			call("owner", "GET", successorCustodyPath, nil, "alice-next", 422)
			call("owner", "POST", successorCustodyPath, custodyRequest(q, "candidate"), "alice-next", 422)
			call("owner", "GET", successorReservationPath, nil, "alice-next", 422)
			var after []byte
			e := s.db.QueryRow("SELECT declarations FROM mls_successor_custody").Scan(&after)
			if mutation == "missing" {
				if e != sql.ErrNoRows {
					t.Fatal("missing row recreated")
				}
			} else if e != nil || !bytes.Equal(raw, after) {
				t.Fatal("corrupt row changed", e)
			}
		})
	}
}

func TestSuccessorCustodyV5SnapshotPreservesReservationAndRestart(t *testing.T) {
	s, _, _, call := successorContextFixture(t)
	q := reservationRequest(t, call("owner", "GET", successorPath, nil, "alice-next", 200))
	var p successorReservation
	json.Unmarshal(call("owner", "POST", successorReservationPath, q, "alice-next", 201), &p)
	var dbpath string
	if e := s.db.QueryRow("SELECT file FROM pragma_database_list WHERE name='main'").Scan(&dbpath); e != nil {
		t.Fatal(e)
	}
	// Fixture-only downgrade reconstructs the exact previous additive schema.
	if _, e := s.db.Exec("DROP TABLE mls_successor_handshake; DROP TABLE mls_successor_custody; PRAGMA user_version=5"); e != nil {
		t.Fatal(e)
	}
	s.Close()
	dir := filepath.Dir(dbpath)
	next, e := Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	got, exists, e := next.successorReservation(p.Context)
	if e != nil || !exists {
		t.Fatal(e)
	}
	a, _ := json.Marshal(got)
	b, _ := json.Marshal(p)
	if !bytes.Equal(a, b) {
		t.Fatal("migration changed reservation")
	}
	paths, _ := filepath.Glob(filepath.Join(dir, "snapshots", "v5-before-successor-custody-*.sqlite"))
	if len(paths) != 1 {
		t.Fatal(paths)
	}
	db, e := sql.Open("sqlite3", sqliteURI(paths[0]))
	if e != nil {
		t.Fatal(e)
	}
	var version, n int
	db.QueryRow("PRAGMA user_version").Scan(&version)
	db.QueryRow("SELECT count(*) FROM mls_successor_reservations").Scan(&n)
	db.Close()
	st, _ := os.Stat(paths[0])
	if version != 5 || n != 1 || st.Mode().Perm() != 0600 {
		t.Fatal(version, n)
	}
	if _, _, e = next.declareSuccessor(p, "alice", "alice-next", custodyRequest(q, "candidate")); e != nil {
		t.Fatal(e)
	}
	next.Close()
	next, e = Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	defer next.Close()
	v, created, e := next.declareSuccessor(p, "alice", "alice-next", custodyRequest(q, "candidate"))
	if e != nil || created || v.Revision != 1 {
		t.Fatal(v, created, e)
	}
	if _, e = Open(dir); e == nil {
		t.Fatal("competing process store allowed")
	}
	all, _ := filepath.Glob(filepath.Join(dir, "snapshots", "*.sqlite"))
	if len(all) != 1 {
		t.Fatal(fmt.Sprint(all))
	}
}
