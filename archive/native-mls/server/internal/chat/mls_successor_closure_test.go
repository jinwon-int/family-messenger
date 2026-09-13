package chat

import (
	"bytes"
	"crypto/ed25519"
	"database/sql"
	"encoding/json"
	"github.com/jinwon-int/family-messenger/server/internal/access"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

const closurePath = "/v1/mls/successors/replace-one/closure"

func closureReady(t *testing.T, expiry int64) (*Store, *access.Authority, access.Config, successorReservation, []leaseApproval, func(string, string, string, any, string, int) []byte) {
	s, a, c, p, qs, call := enrollmentReady(t, expiry)
	call("owner", "POST", enrollmentPath, qs[0], "alice-next", 201)
	call("family", "POST", enrollmentPath, qs[1], "bob-first", 201)
	v, e := s.enrollmentStatus(p)
	if e != nil {
		t.Fatal(e)
	}
	raw, _ := json.Marshal(v.Enrollment)
	c.Activations = []access.Activation{{Intent: p.Context.Intent, ApprovalSHA256: digestMLS(raw), Status: "active"}}
	if e = a.Replace(c); e != nil {
		t.Fatal(e)
	}
	return s, a, c, p, []leaseApproval{{"candidate", ed25519.Sign(leaseKey(9), closureFrame(v.Enrollment, "candidate"))}, {"peer", ed25519.Sign(leaseKey(2), closureFrame(v.Enrollment, "peer"))}}, call
}
func TestPersistentClosureUnilateralAfterExpiryAndImmutableRetry(t *testing.T) {
	for _, role := range []int{0, 1} {
		t.Run([]string{"candidate", "peer"}[role], func(t *testing.T) {
			s, _, c, p, qs, call := closureReady(t, time.Now().Unix()+3)
			call("owner", "POST", enrolledPath, leaseMessage{"before", "alice-next", []byte("retained opaque")}, "alice-next", 201)
			before, _ := s.enrolledHistory(p)
			saved, _ := json.Marshal(before)
			time.Sleep(time.Until(time.Unix(c.Successors.Intents[0].ExpiresAt, 0)))
			subjects := []string{"owner", "family"}
			devices := []string{"alice-next", "bob-first"}
			winner := call(subjects[role], "POST", closurePath, qs[role], devices[role], 201)
			for i := 0; i < 2; i++ {
				if !bytes.Equal(winner, call(subjects[i], "POST", closurePath, qs[i], devices[i], 200)) {
					t.Fatal("winner replaced")
				}
				if !bytes.Equal(winner, call(subjects[i], "GET", closurePath, nil, devices[i], 200)) {
					t.Fatal("receipt drift")
				}
				call(subjects[i], "GET", enrolledPath, nil, devices[i], 403)
				call(subjects[i], "POST", enrolledPath, leaseMessage{"after", devices[i], []byte("denied")}, devices[i], 403)
				call(subjects[i], "GET", enrollmentPath, nil, devices[i], 403)
			}
			after, _ := s.enrolledHistory(p)
			raw, _ := json.Marshal(after)
			if !bytes.Equal(raw, saved) {
				t.Fatal("history erased")
			}
			var seq int
			var name, path string
			if e := s.db.QueryRow("PRAGMA database_list").Scan(&seq, &name, &path); e != nil {
				t.Fatal(e)
			}
			s.Close()
			next, e := Open(filepath.Dir(path))
			if e != nil {
				t.Fatal(e)
			}
			defer next.Close()
			v, e := next.successorClosure(p)
			got, _ := json.Marshal(v)
			if e != nil || !bytes.Equal(bytes.TrimSpace(winner), got) {
				t.Fatal("restart receipt", e)
			}
			if _, e = next.enrollmentStatus(p); e != ErrForbidden {
				t.Fatal("restart reopened", e)
			}
		})
	}
}
func TestClosureRequiresCurrentExactActivationAndDistinctConsent(t *testing.T) {
	s, a, c, p, qs, call := closureReady(t, 0)
	v, _, _ := s.successorLease(p)
	for _, sig := range [][]byte{ed25519.Sign(leaseKey(9), retirementFrame(v, "candidate")), ed25519.Sign(leaseKey(9), enrollmentFrame(v, "candidate")), ed25519.Sign(leaseKey(2), closureFrame(enrollmentRecord{}, "candidate"))} {
		call("owner", "POST", closurePath, leaseApproval{"candidate", sig}, "alice-next", 403)
	}
	call("family", "POST", closurePath, qs[0], "bob-first", 403)
	c.Activations[0].Status = "revoked"
	if e := a.Replace(c); e != nil {
		t.Fatal(e)
	}
	call("owner", "POST", closurePath, qs[0], "alice-next", 403)
	call("owner", "GET", closurePath, nil, "alice-next", 403)
	st, e := s.successorClosure(p)
	if e != nil || st.Closure != nil {
		t.Fatal("invalid authority mutated", e)
	}
}
func TestClosureMandatoryRowCorruptionFailsClosed(t *testing.T) {
	for _, raw := range [][]byte{[]byte("{}"), []byte("null"), []byte(`{"role":"candidate","signature":"AA=="}`), nil} {
		s, _, _, _, _, call := closureReady(t, 0)
		if raw == nil {
			if _, e := s.db.Exec("DELETE FROM mls_successor_closures"); e != nil {
				t.Fatal(e)
			}
		} else {
			if _, e := s.db.Exec("UPDATE mls_successor_closures SET request=?", raw); e != nil {
				t.Fatal(e)
			}
		}
		call("owner", "GET", closurePath, nil, "alice-next", 422)
		call("owner", "GET", enrolledPath, nil, "alice-next", 422)
	}
}
func TestClosureMessageRaceHasSingleTerminalWinner(t *testing.T) {
	s, _, _, p, qs, _ := closureReady(t, 0)
	var wg sync.WaitGroup
	wins := 0
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			s.mu.Lock()
			defer s.mu.Unlock()
			if i%2 == 0 {
				actor, device := "alice", "alice-next"
				q := qs[0]
				if i%4 == 0 {
					actor, device = "bob", "bob-first"
					q = qs[1]
				}
				_, made, e := s.closeSuccessor(p, actor, device, q)
				if e != nil {
					t.Error(e)
				}
				if made {
					wins++
				}
			} else {
				if _, e := s.enrollmentStatus(p); e == nil {
					_, _, e = s.appendEnrolledMessage(p, leaseMessage{"race", "alice-next", []byte("opaque")})
					if e != nil {
						t.Error(e)
					}
				} else if e != ErrForbidden {
					t.Error(e)
				}
			}
		}(i)
	}
	wg.Wait()
	if wins != 1 {
		t.Fatal(wins)
	}
	if _, e := s.enrollmentStatus(p); e != ErrForbidden {
		t.Fatal(e)
	}
}
func TestSchema11ClosureMigrationKeepsPersistentHistory(t *testing.T) {
	s, _, _, p, _, call := closureReady(t, 0)
	call("owner", "POST", enrolledPath, leaseMessage{"retained", "alice-next", []byte("opaque")}, "alice-next", 201)
	before, e := s.enrollmentState(p)
	if e != nil {
		t.Fatal(e)
	}
	saved, _ := json.Marshal(before)
	events, _ := s.enrolledHistory(p)
	history, _ := json.Marshal(events)
	if _, e = s.db.Exec("DROP TABLE mls_successor_closures;PRAGMA user_version=11;"); e != nil {
		t.Fatal(e)
	}
	var seq int
	var name, path string
	if e = s.db.QueryRow("PRAGMA database_list").Scan(&seq, &name, &path); e != nil {
		t.Fatal(e)
	}
	dir := filepath.Dir(path)
	s.Close()
	next, e := Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	defer next.Close()
	after, e := next.enrollmentStatus(p)
	raw, _ := json.Marshal(after)
	if e != nil || !bytes.Equal(raw, saved) {
		t.Fatal("enrollment drift", e)
	}
	later, _ := next.enrolledHistory(p)
	raw, _ = json.Marshal(later)
	if !bytes.Equal(raw, history) {
		t.Fatal("events drift")
	}
	snaps, e := filepath.Glob(filepath.Join(dir, "snapshots", "v11-before-successor-closure-*.sqlite"))
	if e != nil || len(snaps) != 1 {
		t.Fatal(snaps, e)
	}
	db, e := sql.Open("sqlite3", sqliteURI(snaps[0]))
	if e != nil {
		t.Fatal(e)
	}
	defer db.Close()
	var version int
	if e = db.QueryRow("PRAGMA user_version").Scan(&version); e != nil || version != 11 {
		t.Fatal(version, e)
	}
}
