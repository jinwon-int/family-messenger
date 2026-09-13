package chat

import (
	"bytes"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/jinwon-int/family-messenger/server/internal/access"
)

const handshakePath = "/v1/mls/successors/replace-one/handshake"

var handshakePackage = bytes.Repeat([]byte{9}, 32)

func handshakeRequests(q successorReservationRequest) []successorHandshakeRequest {
	return []successorHandshakeRequest{
		{q.ID, q.ContextSHA, "key_package", "", append([]byte{}, handshakePackage...)},
		{q.ID, q.ContextSHA, "welcome", "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd", []byte("synthetic opaque Welcome")},
		{q.ID, q.ContextSHA, "ack", "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd", []byte{}},
	}
}
func handshakeReserve(t *testing.T, call func(string, string, string, any, string, int) []byte) (successorReservation, successorReservationRequest) {
	t.Helper()
	q := reservationRequest(t, call("owner", "GET", successorPath, nil, "alice-next", 200))
	var p successorReservation
	if e := json.Unmarshal(call("owner", "POST", successorReservationPath, q, "alice-next", 201), &p); e != nil {
		t.Fatal(e)
	}
	return p, q
}
func handshakePair(t *testing.T, call func(string, string, string, any, string, int) []byte, q successorReservationRequest) {
	t.Helper()
	call("owner", "POST", successorCustodyPath, custodyRequest(q, "candidate"), "alice-next", 201)
	call("family", "POST", successorCustodyPath, custodyRequest(q, "peer"), "bob-first", 201)
}
func TestSuccessorHandshakeOrderedImmutableBoundedAndInactive(t *testing.T) {
	s, _, _, call := successorContextFixture(t)
	p, q := handshakeReserve(t, call)
	qs := handshakeRequests(q)
	for _, who := range [][2]string{{"owner", "alice-next"}, {"family", "bob-first"}} {
		call(who[0], "GET", handshakePath, nil, who[1], 403)
	}
	call("owner", "POST", handshakePath, qs[0], "alice-next", 403)
	handshakePair(t, call, q)
	reservation := call("owner", "GET", successorReservationPath, nil, "alice-next", 200)
	custody := call("owner", "GET", successorCustodyPath, nil, "alice-next", 200)
	before, _ := s.mlsRoom("source")
	call("family", "POST", handshakePath, qs[1], "bob-first", 409)
	call("owner", "POST", handshakePath, qs[2], "alice-next", 409)
	for index, r := range qs {
		who, device := "owner", "alice-next"
		if index == 1 {
			who, device = "family", "bob-first"
		}
		first := call(who, "POST", handshakePath, r, device, 201)
		if !bytes.Equal(first, call(who, "POST", handshakePath, r, device, 200)) {
			t.Fatal("retry changed bytes")
		}
		var v successorHandshake
		if json.Unmarshal(first, &v) != nil || v.Revision != index+1 || v.Phase != successorHandshakePhases[index+1] {
			t.Fatal(v)
		}
		for old := 0; old <= index; old++ {
			a, d := "owner", "alice-next"
			if old == 1 {
				a, d = "family", "bob-first"
			}
			if !bytes.Equal(first, call(a, "POST", handshakePath, qs[old], d, 200)) {
				t.Fatal("old exact retry did not return current transcript")
			}
		}
	}
	if !bytes.Equal(reservation, call("owner", "GET", successorReservationPath, nil, "alice-next", 200)) || !bytes.Equal(custody, call("family", "GET", successorCustodyPath, nil, "bob-first", 200)) {
		t.Fatal("legacy public binding changed")
	}
	for _, who := range [][2]string{{"owner", "alice-next"}, {"family", "bob-first"}} {
		for _, path := range []string{"/v1/mls/rooms/target/log", "/v1/rooms/target/messages", "/v1/mls/rooms/source/log"} {
			call(who[0], "GET", path, nil, who[1], 403)
		}
		call(who[0], "POST", "/v1/mls/rooms", mlsCreate{"target", qs[1].Group, "alice-next", "bob-first"}, who[1], 403)
	}
	after, _ := s.mlsRoom("source")
	b, _ := json.Marshal(before)
	a, _ := json.Marshal(after)
	if !bytes.Equal(b, a) {
		t.Fatal("old source changed")
	}
	if _, exists, e := s.successorReservation(p.Context); e != nil || !exists {
		t.Fatal("inactive target changed", e)
	}
}
func TestSuccessorHandshakeStrictWireRolesHashAndConflicts(t *testing.T) {
	_, _, _, call := successorContextFixture(t)
	_, q := handshakeReserve(t, call)
	handshakePair(t, call, q)
	qs := handshakeRequests(q)
	for _, who := range [][2]string{{"family", "bob-first"}, {"owner", "alice-first"}, {"outsider", "charlie-first"}, {"family", "alice-next"}} {
		call(who[0], "POST", handshakePath, qs[0], who[1], 403)
	}
	for _, fault := range []string{"package", "oversize", "null", "kind", "group", "reservation", "context"} {
		bad := qs[0]
		code := 400
		switch fault {
		case "package":
			bad.Payload = []byte("different package")
		case "oversize":
			bad.Payload = make([]byte, MLSMaxWire+1)
		case "null":
			bad.Payload = nil
		case "kind":
			bad.Kind = "application"
		case "group":
			bad.Group = qs[1].Group
		case "reservation":
			bad.Reservation = "other"
			code = 409
		case "context":
			bad.ContextSHA = digestMLS([]byte("other"))
			code = 409
		}
		call("owner", "POST", handshakePath, bad, "alice-next", code)
	}
	for _, path := range []string{handshakePath + "?", handshakePath + "?x=1"} {
		call("owner", "POST", path, qs[0], "alice-next", 400)
	}
	call("owner", "PUT", handshakePath, qs[0], "alice-next", 400)
	call("owner", "POST", handshakePath, map[string]any{"reservation_id": q.ID, "context_sha256": q.ContextSHA, "kind": "key_package", "group_id": "", "payload": handshakePackage, "extra": true}, "alice-next", 400)
	call("owner", "POST", handshakePath, qs[0], "alice-next", 201)
	bad := qs[1]
	bad.Group = "abababababababababababababababab"
	call("family", "POST", handshakePath, bad, "bob-first", 400)
	call("family", "POST", handshakePath, qs[1], "bob-first", 201)
	bad = qs[1]
	bad.Payload = []byte("changed Welcome")
	call("family", "POST", handshakePath, bad, "bob-first", 409)
	bad = qs[2]
	bad.Group = "efefefefefefefefefefefefefefefef"
	call("owner", "POST", handshakePath, bad, "alice-next", 409)
	bad = qs[2]
	bad.Payload = []byte("not an empty ack")
	call("owner", "POST", handshakePath, bad, "alice-next", 400)
}
func TestSuccessorHandshakeCommitFailureConcurrencyAndRestart(t *testing.T) {
	s, _, _, call := successorContextFixture(t)
	p, q := handshakeReserve(t, call)
	handshakePair(t, call, q)
	qs := handshakeRequests(q)
	if _, e := s.db.Exec("CREATE TRIGGER fail_handshake BEFORE UPDATE ON mls_successor_handshake BEGIN SELECT RAISE(ABORT,'fixture'); END"); e != nil {
		t.Fatal(e)
	}
	if _, created, e := s.appendSuccessorHandshake(p, "alice", "alice-next", qs[0]); e == nil || created {
		t.Fatal("failed commit acknowledged")
	}
	s.db.Exec("DROP TRIGGER fail_handshake")
	for index, r := range qs {
		actor, device := "alice", "alice-next"
		if index == 1 {
			actor, device = "bob", "bob-first"
		}
		var wg sync.WaitGroup
		var mu sync.Mutex
		wins, retries := 0, 0
		for range 16 {
			wg.Add(1)
			go func() {
				defer wg.Done()
				s.mu.Lock()
				_, created, e := s.appendSuccessorHandshake(p, actor, device, r)
				s.mu.Unlock()
				mu.Lock()
				defer mu.Unlock()
				if e != nil {
					t.Error(e)
				} else if created {
					wins++
				} else {
					retries++
				}
			}()
		}
		wg.Wait()
		if wins != 1 || retries != 15 {
			t.Fatal(wins, retries)
		}
	}
	var path string
	s.db.QueryRow("SELECT file FROM pragma_database_list WHERE name='main'").Scan(&path)
	old, _, _ := s.successorHandshake(p)
	s.Close()
	next, e := Open(filepath.Dir(path))
	if e != nil {
		t.Fatal(e)
	}
	defer next.Close()
	got, created, e := next.appendSuccessorHandshake(p, "alice", "alice-next", qs[0])
	if e != nil || created {
		t.Fatal(e, created)
	}
	a, _ := json.Marshal(old)
	b, _ := json.Marshal(got)
	if !bytes.Equal(a, b) {
		t.Fatal("restart retry differs")
	}
}
func TestSuccessorHandshakeFreshAuthorityAndRetainedTranscript(t *testing.T) {
	for _, fault := range []string{"peer", "actor", "admin", "expiry", "source"} {
		t.Run(fault, func(t *testing.T) {
			s, a, c, call := successorContextFixture(t, func(c *access.Config) {
				if fault == "expiry" {
					c.Successors.Intents[0].ExpiresAt = time.Now().Unix() + 3
				}
			})
			_, q := handshakeReserve(t, call)
			handshakePair(t, call, q)
			r := handshakeRequests(q)[0]
			call("owner", "POST", handshakePath, r, "alice-next", 201)
			var before []byte
			s.db.QueryRow("SELECT transcript FROM mls_successor_handshake").Scan(&before)
			switch fault {
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
			}
			if fault != "expiry" {
				if e := a.Replace(c); e != nil {
					t.Fatal(e)
				}
			}
			call("family", "GET", handshakePath, nil, "bob-first", 403)
			call("family", "POST", handshakePath, handshakeRequests(q)[1], "bob-first", 403)
			var after []byte
			s.db.QueryRow("SELECT transcript FROM mls_successor_handshake").Scan(&after)
			if !bytes.Equal(before, after) {
				t.Fatal("denial changed transcript")
			}
		})
	}
}
func TestSuccessorHandshakeCorruptionFailsClosedWithoutRepair(t *testing.T) {
	for _, fault := range []string{"missing", "null", "whitespace", "order", "device", "context", "digest", "package", "ack-group"} {
		t.Run(fault, func(t *testing.T) {
			s, _, _, call := successorContextFixture(t)
			p, q := handshakeReserve(t, call)
			handshakePair(t, call, q)
			for i, r := range handshakeRequests(q) {
				actor, device := "alice", "alice-next"
				if i == 1 {
					actor, device = "bob", "bob-first"
				}
				if _, _, e := s.appendSuccessorHandshake(p, actor, device, r); e != nil {
					t.Fatal(e)
				}
			}
			v, _, _ := s.successorHandshake(p)
			var raw []byte
			switch fault {
			case "missing":
				s.db.Exec("DELETE FROM mls_successor_handshake")
			case "null":
				raw = []byte("null")
			case "whitespace":
				raw = []byte("[] ")
			case "order":
				v.Records[0], v.Records[1] = v.Records[1], v.Records[0]
			case "device":
				v.Records[0].Device = "alice-first"
			case "context":
				v.Records[1].Request.ContextSHA = digestMLS([]byte("other"))
			case "digest":
				v.Records[1].SHA = digestMLS([]byte("other"))
			case "package":
				v.Records[0].Request.Payload = []byte("changed")
			case "ack-group":
				v.Records[2].Request.Group = "efefefefefefefefefefefefefefefef"
			}
			if fault != "missing" {
				if raw == nil {
					raw, _ = json.Marshal(v.Records)
				}
				if _, e := s.db.Exec("UPDATE mls_successor_handshake SET transcript=?", raw); e != nil {
					t.Fatal(e)
				}
			}
			call("owner", "GET", handshakePath, nil, "alice-next", 422)
			call("owner", "GET", successorReservationPath, nil, "alice-next", 422)
			var after []byte
			e := s.db.QueryRow("SELECT transcript FROM mls_successor_handshake").Scan(&after)
			if fault == "missing" {
				if e != sql.ErrNoRows {
					t.Fatal("row recreated")
				}
			} else if e != nil || !bytes.Equal(raw, after) {
				t.Fatal("corruption changed")
			}
		})
	}
}
func TestSuccessorHandshakeV6SnapshotPreservesDeclarations(t *testing.T) {
	s, _, _, call := successorContextFixture(t)
	p, q := handshakeReserve(t, call)
	handshakePair(t, call, q)
	prior, _, _ := s.successorCustody(p)
	var path string
	s.db.QueryRow("SELECT file FROM pragma_database_list WHERE name='main'").Scan(&path)
	if _, e := s.db.Exec("DROP TABLE mls_successor_lease_events; DROP TABLE mls_successor_closures; DROP TABLE mls_successor_enrolled_events; DROP TABLE mls_successor_enrollments; DROP TABLE mls_successor_retirements; DROP TABLE mls_successor_leases; DROP TABLE mls_successor_confirmation; DROP TABLE mls_successor_handshake; PRAGMA user_version=6"); e != nil {
		t.Fatal(e)
	}
	s.Close()
	dir := filepath.Dir(path)
	next, e := Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	defer next.Close()
	after, _, e := next.successorCustody(p)
	a, _ := json.Marshal(prior)
	b, _ := json.Marshal(after)
	if e != nil || !bytes.Equal(a, b) {
		t.Fatal("custody changed", e)
	}
	got, exists, e := next.successorReservation(p.Context)
	if e != nil || !exists || got.ID != p.ID {
		t.Fatal(e)
	}
	paths, _ := filepath.Glob(filepath.Join(dir, "snapshots", "v6-before-successor-handshake-*.sqlite"))
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
	db.QueryRow("SELECT count(*) FROM mls_successor_custody").Scan(&n)
	if version != 6 || n != 1 {
		t.Fatal(version, n)
	}
	next.Close()
	reopened, e := Open(dir)
	if e != nil {
		t.Fatal("reopen with preserved v6 snapshot", e)
	}
	defer reopened.Close()
}

func TestSuccessorHandshakeGroupCannotAliasAnotherContext(t *testing.T) {
	s, _, _, call := successorContextFixture(t)
	p, q := handshakeReserve(t, call)
	handshakePair(t, call, q)
	qs := handshakeRequests(q)
	s.appendSuccessorHandshake(p, "alice", "alice-next", qs[0])
	s.appendSuccessorHandshake(p, "bob", "bob-first", qs[1])
	other := p.Context
	other.Intent = "other-intent"
	other.Target = "other-target"
	raw, _ := json.Marshal(other)
	p2, _, e := s.reserveSuccessor(other, successorReservationRequest{"other-reservation", digestMLS(raw)})
	if e != nil {
		t.Fatal(e)
	}
	q2 := successorReservationRequest{p2.ID, digestMLS(raw)}
	s.declareSuccessor(p2, "alice", "alice-next", custodyRequest(q2, "candidate"))
	s.declareSuccessor(p2, "bob", "bob-first", custodyRequest(q2, "peer"))
	qs2 := handshakeRequests(q2)
	s.appendSuccessorHandshake(p2, "alice", "alice-next", qs2[0])
	if _, created, e := s.appendSuccessorHandshake(p2, "bob", "bob-first", qs2[1]); e != ErrConflict || created {
		t.Fatal("shared group accepted", e)
	}
	qs2[1].Group = "efefefefefefefefefefefefefefefef"
	if _, created, e := s.appendSuccessorHandshake(p2, "bob", "bob-first", qs2[1]); e != nil || !created {
		t.Fatal(e)
	}
}

func TestSuccessorHandshakeMaximumPayloadAndCanonicalWire(t *testing.T) {
	payload := bytes.Repeat([]byte{19}, MLSMaxWire)
	s, _, _, call := successorContextFixture(t, func(c *access.Config) { c.Successors.Intents[0].PackageSHA256 = digestMLS(payload) })
	p, q := handshakeReserve(t, call)
	handshakePair(t, call, q)
	qs := handshakeRequests(q)
	qs[0].Payload = payload
	qs[1].Payload = payload
	for _, bad := range []any{[]int{9, 9}, base64.StdEncoding.EncodeToString(payload) + "\n"} {
		call("owner", "POST", handshakePath, map[string]any{"reservation_id": q.ID, "context_sha256": q.ContextSHA, "kind": "key_package", "group_id": "", "payload": bad}, "alice-next", 400)
	}
	for i, r := range qs {
		who, device := "owner", "alice-next"
		if i == 1 {
			who, device = "family", "bob-first"
		}
		raw := call(who, "POST", handshakePath, r, device, 201)
		if len(raw) > successorHandshakeMax {
			t.Fatal("response exceeds bound")
		}
	}
	if v, _, e := s.successorHandshake(p); e != nil || v.Revision != 3 {
		t.Fatal(e)
	}
}

func TestSuccessorHandshakeGroupClaimExcludesOrdinaryRoomBothOrders(t *testing.T) {
	for _, first := range []string{"handshake", "ordinary"} {
		t.Run(first, func(t *testing.T) {
			_, _, _, call := successorContextFixture(t)
			_, q := handshakeReserve(t, call)
			handshakePair(t, call, q)
			qs := handshakeRequests(q)
			call("owner", "POST", handshakePath, qs[0], "alice-next", 201)
			ordinary := mlsCreate{"unrelated", qs[1].Group, "charlie-first", "bob-first"}
			if first == "handshake" {
				call("family", "POST", handshakePath, qs[1], "bob-first", 201)
				// Both fresh create and existing ordinary reservation bind share the guard.
				call("outsider", "POST", "/v1/mls/rooms", ordinary, "charlie-first", 409)
				call("outsider", "POST", "/v1/mls/reservations", map[string]string{"room": "unrelated", "peer_actor": "bob"}, "charlie-first", 201)
				call("outsider", "POST", "/v1/mls/rooms", ordinary, "charlie-first", 409)
			} else {
				call("outsider", "POST", "/v1/mls/rooms", ordinary, "charlie-first", 201)
				call("family", "POST", handshakePath, qs[1], "bob-first", 409)
			}
			call("owner", "GET", handshakePath, nil, "alice-next", 200)
			call("owner", "GET", successorReservationPath, nil, "alice-next", 200)
			call("owner", "GET", successorCustodyPath, nil, "alice-next", 200)
		})
	}
}

func TestSuccessorHandshakeOrdinaryAndWelcomeRaceOneGroupClaim(t *testing.T) {
	for range 8 {
		s, _, c, call := successorContextFixture(t)
		p, q := handshakeReserve(t, call)
		handshakePair(t, call, q)
		qs := handshakeRequests(q)
		call("owner", "POST", handshakePath, qs[0], "alice-next", 201)
		var wg sync.WaitGroup
		var mu sync.Mutex
		wins, conflicts := 0, 0
		gate := make(chan struct{})
		for i := range 2 {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				<-gate
				s.mu.Lock()
				var created bool
				var e error
				if i == 0 {
					_, created, e = s.appendSuccessorHandshake(p, "bob", "bob-first", qs[1])
				} else {
					_, created, e = s.createMLS(mlsCreate{"unrelated", qs[1].Group, "charlie-first", "bob-first"}, "charlie", c.Devices)
				}
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
					t.Error("unexpected retry")
				}
			}(i)
		}
		close(gate)
		wg.Wait()
		if wins != 1 || conflicts != 1 {
			t.Fatal(wins, conflicts)
		}
		if _, _, e := s.successorHandshake(p); e != nil {
			t.Fatal("race made retained transcript unreadable", e)
		}
	}
}
