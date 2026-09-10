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

const successorReservationPath = "/v1/mls/successors/replace-one/reservation"

func reservationRequest(t *testing.T, raw []byte) successorReservationRequest {
	t.Helper()
	var c successorContext
	if e := json.Unmarshal(raw, &c); e != nil {
		t.Fatal(e)
	}
	b, _ := json.Marshal(c)
	return successorReservationRequest{"shared-reservation", digestMLS(b)}
}
func TestSuccessorReservationExactRetryAndInactiveBoundary(t *testing.T) {
	s, _, _, call := successorContextFixture(t)
	before, _ := s.mlsRoom("source")
	raw := call("owner", "GET", successorPath, nil, "alice-next", 200)
	q := reservationRequest(t, raw)
	call("owner", "GET", successorReservationPath, nil, "alice-next", 403)
	first := call("owner", "POST", successorReservationPath, q, "alice-next", 201)
	for _, who := range [][2]string{{"owner", "alice-next"}, {"family", "bob-first"}} {
		if !bytes.Equal(first, call(who[0], "POST", successorReservationPath, q, who[1], 200)) || !bytes.Equal(first, call(who[0], "GET", successorReservationPath, nil, who[1], 200)) {
			t.Fatal("retry drift")
		}
		call(who[0], "GET", "/v1/mls/rooms/target/log", nil, who[1], 403)
		call(who[0], "GET", "/v1/rooms/target/messages", nil, who[1], 403)
		call(who[0], "POST", "/v1/mls/rooms", mlsCreate{"target", "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd", who[1], map[string]string{"alice-next": "bob-first", "bob-first": "alice-next"}[who[1]]}, who[1], 403)
	}
	call("owner", "GET", successorPath, nil, "alice-next", 409)
	q.ID = "different"
	call("owner", "POST", successorReservationPath, q, "alice-next", 409)
	q = reservationRequest(t, raw)
	q.ContextSHA = digestMLS([]byte("wrong"))
	call("owner", "POST", successorReservationPath, q, "alice-next", 409)
	after, _ := s.mlsRoom("source")
	b, _ := json.Marshal(before)
	a, _ := json.Marshal(after)
	if !bytes.Equal(a, b) {
		t.Fatal("source changed")
	}
	var count int
	s.db.QueryRow("SELECT count(*) FROM mls_successor_reservations").Scan(&count)
	if count != 1 {
		t.Fatal(count)
	}
}
func TestSuccessorReservationAuthorityRevocationAndExpiry(t *testing.T) {
	for _, kind := range []string{"actor", "admin", "peer", "expiry", "subject", "source"} {
		t.Run(kind, func(t *testing.T) {
			s, a, c, call := successorContextFixture(t, func(c *access.Config) {
				if kind == "expiry" {
					c.Successors.Intents[0].ExpiresAt = time.Now().Unix() + 5
				}
			})
			q := reservationRequest(t, call("owner", "GET", successorPath, nil, "alice-next", 200))
			call("owner", "POST", successorReservationPath, q, "alice-next", 201)
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
			call("family", "GET", successorReservationPath, nil, "bob-first", 403)
			call("family", "POST", successorReservationPath, q, "bob-first", 403)
			var n int
			s.db.QueryRow("SELECT count(*) FROM mls_successor_reservations").Scan(&n)
			if n != 1 {
				t.Fatal("revocation deleted reservation")
			}
		})
	}
}
func TestSuccessorReservationAliasesWrongBindingsAndOccupancy(t *testing.T) {
	_, _, _, call := successorContextFixture(t)
	q := reservationRequest(t, call("owner", "GET", successorPath, nil, "alice-next", 200))
	for _, who := range [][2]string{{"owner", "alice-first"}, {"family", "alice-next"}, {"owner", "bob-first"}, {"outsider", "charlie-first"}} {
		call(who[0], "POST", successorReservationPath, q, who[1], 403)
	}
	for _, path := range []string{successorReservationPath + "?", successorReservationPath + "?x=1"} {
		call("owner", "POST", path, q, "alice-next", 400)
	}
	call("owner", "PUT", successorReservationPath, q, "alice-next", 400)
	call("owner", "POST", successorReservationPath, map[string]any{"reservation_id": q.ID, "context_sha256": q.ContextSHA, "extra": 1}, "alice-next", 400)
	call("owner", "POST", "/v1/rooms", map[string]any{"id": "target", "members": []string{"bob"}}, "alice-next", 201)
	call("owner", "POST", successorReservationPath, q, "alice-next", 409)
	call("owner", "GET", "/v1/rooms/target/messages", nil, "alice-next", 200)
}
func TestSuccessorReservationCompetingWritersAndRollback(t *testing.T) {
	s, _, c, call := successorContextFixture(t)
	q := reservationRequest(t, call("owner", "GET", successorPath, nil, "alice-next", 200))
	s.mu.Lock()
	ctx, e := s.successorContext(c.Successors.Intents[0], "alice", "alice-next", c.Devices)
	s.mu.Unlock()
	if e != nil {
		t.Fatal(e)
	}
	// Abort after both membership inserts but before the final reservation row.
	if _, e = s.db.Exec("CREATE TRIGGER fail_reservation BEFORE INSERT ON mls_successor_reservations BEGIN SELECT RAISE(ABORT,'fixture'); END"); e != nil {
		t.Fatal(e)
	}
	s.mu.Lock()
	_, _, e = s.reserveSuccessor(ctx, q)
	s.mu.Unlock()
	if e == nil {
		t.Fatal("injection did not fail")
	}
	var n int
	s.db.QueryRow("SELECT count(*) FROM rooms WHERE id='target'").Scan(&n)
	if n != 0 {
		t.Fatal("partial target survived rollback")
	}
	s.db.Exec("DROP TRIGGER fail_reservation")
	var wg sync.WaitGroup
	var wins, retries int
	var mu sync.Mutex
	for range 12 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			s.mu.Lock()
			_, created, e := s.reserveSuccessor(ctx, q)
			s.mu.Unlock()
			if e != nil {
				t.Error(e)
				return
			}
			mu.Lock()
			if created {
				wins++
			} else {
				retries++
			}
			mu.Unlock()
		}()
	}
	wg.Wait()
	if wins != 1 || retries != 11 {
		t.Fatal(wins, retries)
	}
}
func TestSuccessorReservationCorruptionRetained(t *testing.T) {
	for _, query := range []string{
		"UPDATE mls_successor_reservations SET context=context||' '",
		"UPDATE mls_successor_reservations SET reservation_id='bad/id'",
		"DELETE FROM mls_rooms WHERE room='target'",
		"DELETE FROM members WHERE room='target' AND actor='bob'",
		"UPDATE mls_rooms SET custody_required=0 WHERE room='target'",
		"UPDATE mls_rooms SET pins='null' WHERE room='target'",
		"UPDATE mls_rooms SET phase='ready' WHERE room='target'",
		"UPDATE rooms SET owner='bob' WHERE id='target'",
	} {
		t.Run(query, func(t *testing.T) {
			s, _, c, call := successorContextFixture(t)
			q := reservationRequest(t, call("owner", "GET", successorPath, nil, "alice-next", 200))
			call("owner", "POST", successorReservationPath, q, "alice-next", 201)
			s.db.Exec("PRAGMA foreign_keys=OFF")
			if _, e := s.db.Exec(query); e != nil {
				t.Fatal(e)
			}
			s.mu.Lock()
			ctx, e := s.successorContext(c.Successors.Intents[0], "alice", "alice-next", c.Devices)
			if e != nil {
				t.Fatal(e)
			}
			_, _, e = s.reserveSuccessor(ctx, q)
			s.mu.Unlock()
			if e == nil {
				t.Fatal("corruption accepted")
			}
			var n int
			s.db.QueryRow("SELECT count(*) FROM mls_successor_reservations").Scan(&n)
			if n != 1 {
				t.Fatal("corruption removed")
			}
		})
	}
}
func TestSuccessorReservationV4SnapshotAndRestart(t *testing.T) {
	dir := t.TempDir()
	os.Chmod(dir, 0700)
	s, e := Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	s.CreateRoom("old", "alice", []string{"bob"})
	s.Send("old", "alice", "one", []byte("generated historical data"))
	s.Close()
	db, e := sql.Open("sqlite3", sqliteURI(filepath.Join(dir, "messages.sqlite")))
	if e != nil {
		t.Fatal(e)
	}
	_, e = db.Exec("DROP TABLE mls_successor_reservations; PRAGMA user_version=4")
	db.Close()
	if e != nil {
		t.Fatal(e)
	}
	s, e = Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	s.Close()
	paths, _ := filepath.Glob(filepath.Join(dir, "snapshots", "v4-before-successor-reservation-*.sqlite"))
	if len(paths) != 1 {
		t.Fatal(paths)
	}
	db, e = sql.Open("sqlite3", sqliteURI(paths[0]))
	if e != nil {
		t.Fatal(e)
	}
	var v, n int
	db.QueryRow("PRAGMA user_version").Scan(&v)
	db.QueryRow("SELECT count(*) FROM messages").Scan(&n)
	db.Close()
	if v != 4 || n != 1 {
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
	after, _ := filepath.Glob(filepath.Join(dir, "snapshots", "*.sqlite"))
	if len(after) != 1 {
		t.Fatal("repeated snapshots")
	}
	_, e = Open(dir)
	if e == nil {
		t.Fatal("competing store allowed")
	}
}

func TestSuccessorReservationConflictRaceAndQuota(t *testing.T) {
	s, _, c, call := successorContextFixture(t)
	q := reservationRequest(t, call("owner", "GET", successorPath, nil, "alice-next", 200))
	s.mu.Lock()
	ctx, e := s.successorContext(c.Successors.Intents[0], "alice", "alice-next", c.Devices)
	s.mu.Unlock()
	if e != nil {
		t.Fatal(e)
	}
	var wg sync.WaitGroup
	results := make(chan error, 2)
	for _, id := range []string{"choice-one", "choice-two"} {
		wg.Add(1)
		go func(id string) {
			defer wg.Done()
			r := q
			r.ID = id
			s.mu.Lock()
			_, _, e := s.reserveSuccessor(ctx, r)
			s.mu.Unlock()
			results <- e
		}(id)
	}
	wg.Wait()
	close(results)
	wins, conflicts := 0, 0
	for e := range results {
		if e == nil {
			wins++
		} else if e == ErrConflict {
			conflicts++
		} else {
			t.Fatal(e)
		}
	}
	if wins != 1 || conflicts != 1 {
		t.Fatal(wins, conflicts)
	}
	// Existing global room quota counts even permanently inactive reservations.
	s2, _, _, call2 := successorContextFixture(t)
	q2 := reservationRequest(t, call2("owner", "GET", successorPath, nil, "alice-next", 200))
	var n int
	if e := s2.db.QueryRow("SELECT count(*) FROM rooms").Scan(&n); e != nil {
		t.Fatal(e)
	}
	for ; n < 32; n++ {
		if _, e := s2.db.Exec("INSERT INTO rooms(id,owner) VALUES(?,'alice')", fmt.Sprintf("quota-%d", n)); e != nil {
			t.Fatal(e)
		}
	}
	call2("owner", "POST", successorReservationPath, q2, "alice-next", 507)
	s2.db.QueryRow("SELECT count(*) FROM rooms WHERE id='target'").Scan(&n)
	if n != 0 {
		t.Fatal("quota allocated target")
	}
}

func TestSuccessorReservationCorruptStateCannotUseOrdinaryNativeRoutes(t *testing.T) {
	for _, kind := range []string{"duplicated-active-pins", "substituted-active-members"} {
		t.Run(kind, func(t *testing.T) {
			s, _, c, call := successorContextFixture(t)
			q := reservationRequest(t, call("owner", "GET", successorPath, nil, "alice-next", 200))
			call("owner", "POST", successorReservationPath, q, "alice-next", 201)
			group := "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd"
			if kind == "duplicated-active-pins" {
				bob, e := activePin(c.Devices, "bob-first")
				if e != nil {
					t.Fatal(e)
				}
				pins, _ := json.Marshal([]MLSPin{bob, bob})
				_, e = s.db.Exec("UPDATE mls_rooms SET group_id=?,creator='bob-first',peer='bob-first',pins=?,revision=3,epoch=1,phase='ready',next_seq=4 WHERE room='target'", group, pins)
				if e != nil {
					t.Fatal(e)
				}
			} else {
				// Even a reserved-state directory must not look like a normal fresh
				// context after damaged membership, causing client slot consumption.
				if _, e := s.db.Exec("UPDATE members SET actor='charlie' WHERE room='target' AND actor='alice'"); e != nil {
					t.Fatal(e)
				}
			}
			for _, endpoint := range []string{"log", "context", "status", "preparation"} {
				call("family", "GET", "/v1/mls/rooms/target/"+endpoint, nil, "bob-first", 403)
			}
			call("family", "POST", "/v1/mls/reservations", map[string]string{"room": "target", "peer_actor": "alice"}, "bob-first", 409)
			call("family", "POST", "/v1/mls/rooms/target/log", MLSRequest{"forbidden-corrupt-send", "bob-first", group, "application", 3, 1, "", []byte("generated ciphertext")}, "bob-first", 403)
			var n int
			s.db.QueryRow("SELECT count(*) FROM mls_events WHERE room='target'").Scan(&n)
			if n != 0 {
				t.Fatal("ordinary route appended to inactive successor")
			}
		})
	}
}
