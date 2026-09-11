package chat

import (
	"bytes"
	"crypto/ed25519"
	"database/sql"
	"encoding/json"
	"github.com/jinwon-int/family-messenger/server/internal/access"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

const retirementPath = "/v1/mls/successors/replace-one/retirement"

func TestRetirementSignedTerminalAndRetainedRestart(t *testing.T) {
	s, _, _, p, qs, call := leaseReady(t)
	call("owner", "GET", retirementPath, nil, "alice-next", 403)
	call("owner", "POST", leasePath, qs[0], "alice-next", 201)
	call("family", "POST", leasePath, qs[1], "bob-first", 201)
	m := leaseMessage{"retained", "alice-next", []byte("generated opaque pending history")}
	call("owner", "POST", channelPath, m, "alice-next", 201)
	before := call("owner", "GET", channelPath, nil, "alice-next", 200)
	var v successorRetirement
	json.Unmarshal(call("owner", "GET", retirementPath, nil, "alice-next", 200), &v)
	q := leaseApproval{"candidate", ed25519.Sign(leaseKey(9), retirementFrame(v.Lease, "candidate"))}
	call("owner", "POST", retirementPath, qs[0], "alice-next", 403)
	call("family", "POST", retirementPath, q, "bob-first", 403)
	call("owner", "POST", leasePath, q, "alice-next", 403)
	call("owner", "POST", retirementPath, map[string]any{"role": "candidate", "signature": []int{1, 2}}, "alice-next", 400)
	done := call("owner", "POST", retirementPath, q, "alice-next", 201)
	if !bytes.Equal(done, call("owner", "POST", retirementPath, q, "alice-next", 200)) {
		t.Fatal("retry drift")
	}
	other := leaseApproval{"peer", ed25519.Sign(leaseKey(2), retirementFrame(v.Lease, "peer"))}
	if !bytes.Equal(done, call("family", "POST", retirementPath, other, "bob-first", 200)) {
		t.Fatal("other participant overwrote terminal receipt")
	}
	for _, path := range []string{leasePath, channelPath} {
		call("owner", "GET", path, nil, "alice-next", 403)
	}
	call("owner", "POST", leasePath, qs[0], "alice-next", 403)
	call("owner", "POST", channelPath, m, "alice-next", 403)
	history, e := s.leaseHistory(p)
	if e != nil {
		t.Fatal(e)
	}
	raw, _ := json.Marshal(history)
	if !bytes.Equal(bytes.TrimSpace(before), raw) {
		t.Fatal("history changed")
	}
	var path string
	s.db.QueryRow("SELECT file FROM pragma_database_list WHERE name='main'").Scan(&path)
	s.Close()
	next, e := Open(filepath.Dir(path))
	if e != nil {
		t.Fatal(e)
	}
	defer next.Close()
	receipt, e := next.successorRetirement(p)
	if e != nil {
		t.Fatal(e)
	}
	raw, _ = json.Marshal(receipt)
	if !bytes.Equal(bytes.TrimSpace(done), raw) {
		t.Fatal("restart lost retirement")
	}
}
func TestRetirementConcurrentSingleWinner(t *testing.T) {
	s, _, _, p, qs, call := leaseReady(t)
	call("owner", "POST", leasePath, qs[0], "alice-next", 201)
	call("family", "POST", leasePath, qs[1], "bob-first", 201)
	v, _, _ := s.successorLease(p)
	closures := []leaseApproval{{"candidate", ed25519.Sign(leaseKey(9), retirementFrame(v, "candidate"))}, {"peer", ed25519.Sign(leaseKey(2), retirementFrame(v, "peer"))}}
	created := 0
	var first []byte
	var wg sync.WaitGroup
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			s.mu.Lock()
			defer s.mu.Unlock()
			pin := p.Context.Candidate
			if i == 1 {
				pin = p.Context.Peer
			}
			v, new, e := s.retireSuccessor(p, pin.Actor, pin.ID, closures[i])
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
				t.Error("winner drift")
			}
		}(i % 2)
	}
	wg.Wait()
	if created != 1 {
		t.Fatal(created)
	}
}
func TestRetirementExpiryIsReadOnlyAndAuthorityIsCurrent(t *testing.T) {
	s, a, c, call := leaseContextFixture(t, func(c *access.Config) { c.Successors.Intents[0].ExpiresAt = time.Now().Unix() + 3 })
	p, qs := confirmationReady(t, call)
	call("owner", "POST", confirmationPath, qs[0], "alice-next", 201)
	call("family", "POST", confirmationPath, qs[1], "bob-first", 201)
	v, _, e := s.successorLease(p)
	if e != nil {
		t.Fatal(e)
	}
	call("owner", "POST", leasePath, leaseApproval{"candidate", ed25519.Sign(leaseKey(9), leaseFrame(v, "candidate"))}, "alice-next", 201)
	call("family", "POST", leasePath, leaseApproval{"peer", ed25519.Sign(leaseKey(2), leaseFrame(v, "peer"))}, "bob-first", 201)
	q := leaseApproval{"candidate", ed25519.Sign(leaseKey(9), retirementFrame(v, "candidate"))}
	done := call("owner", "POST", retirementPath, q, "alice-next", 201)
	time.Sleep(time.Until(time.Unix(c.Successors.Intents[0].ExpiresAt, 0)))
	if !bytes.Equal(done, call("owner", "GET", retirementPath, nil, "alice-next", 200)) {
		t.Fatal("expired terminal observation drift")
	}
	call("owner", "POST", retirementPath, q, "alice-next", 403)
	call("owner", "POST", channelPath, leaseMessage{"expired", "alice-next", []byte("x")}, "alice-next", 403)
	c.Successors.Administrators = nil
	if e := a.Replace(c); e != nil {
		t.Fatal(e)
	}
	call("owner", "GET", retirementPath, nil, "alice-next", 403)
}
func TestRetirementCorruptionFailsClosed(t *testing.T) {
	s, _, _, p, qs, call := leaseReady(t)
	call("owner", "POST", leasePath, qs[0], "alice-next", 201)
	call("family", "POST", leasePath, qs[1], "bob-first", 201)
	for _, raw := range [][]byte{[]byte("{}"), []byte("null"), []byte(`{"role":"candidate","signature":"AA=="}`), {}} {
		if _, e := s.db.Exec("UPDATE mls_successor_retirements SET request=?", raw); e != nil {
			t.Fatal(e)
		}
		if _, e := s.retirementRequest(p); e != ErrIntegrity {
			t.Fatalf("corruption %q: %v", raw, e)
		}
		call("owner", "GET", channelPath, nil, "alice-next", 422)
	}
	s.db.Exec("DELETE FROM mls_successor_enrolled_events")
	s.db.Exec("DELETE FROM mls_successor_enrollments")
	s.db.Exec("DELETE FROM mls_successor_retirements")
	if _, e := s.retirementRequest(p); e != ErrIntegrity {
		t.Fatal(e)
	}
	call("owner", "POST", leasePath, qs[0], "alice-next", 422)
}

func TestRetirementV9MigrationRetainsLeasedChannel(t *testing.T) {
	s, _, _, p, qs, call := leaseReady(t)
	call("owner", "POST", leasePath, qs[0], "alice-next", 201)
	call("family", "POST", leasePath, qs[1], "bob-first", 201)
	call("owner", "POST", channelPath, leaseMessage{"kept", "alice-next", []byte("generated opaque event")}, "alice-next", 201)
	leaseBefore := call("owner", "GET", leasePath, nil, "alice-next", 200)
	eventsBefore := call("owner", "GET", channelPath, nil, "alice-next", 200)
	var path string
	s.db.QueryRow("SELECT file FROM pragma_database_list WHERE name='main'").Scan(&path)
	if _, e := s.db.Exec("DROP TABLE mls_successor_enrolled_events; DROP TABLE mls_successor_enrollments; DROP TABLE mls_successor_retirements; PRAGMA user_version=9"); e != nil {
		t.Fatal(e)
	}
	s.Close()
	dir := filepath.Dir(path)
	next, e := Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	defer next.Close()
	v, _, e := next.successorLease(p)
	raw, _ := json.Marshal(v)
	if e != nil || !bytes.Equal(bytes.TrimSpace(leaseBefore), raw) {
		t.Fatal("lease migration drift", e)
	}
	events, e := next.leaseHistory(p)
	raw, _ = json.Marshal(events)
	if e != nil || !bytes.Equal(bytes.TrimSpace(eventsBefore), raw) {
		t.Fatal("events migration drift", e)
	}
	if q, e := next.retirementRequest(p); e != nil || q != nil {
		t.Fatal("new retirement not empty", e)
	}
	snapshots, _ := filepath.Glob(filepath.Join(dir, "snapshots", "v9-before-successor-retirement-*.sqlite"))
	if len(snapshots) != 1 {
		t.Fatal(snapshots)
	}
	st, e := os.Stat(snapshots[0])
	if e != nil || st.Mode().Perm() != 0600 {
		t.Fatal("snapshot permissions", e)
	}
	db, e := sql.Open("sqlite3", sqliteURI(snapshots[0]))
	if e != nil {
		t.Fatal(e)
	}
	defer db.Close()
	var version, count int
	db.QueryRow("PRAGMA user_version").Scan(&version)
	db.QueryRow("SELECT count(*) FROM mls_successor_lease_events").Scan(&count)
	if version != 9 || count != 1 {
		t.Fatal(version, count)
	}
}
