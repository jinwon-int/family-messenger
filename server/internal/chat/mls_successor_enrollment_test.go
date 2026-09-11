package chat

import (
	"bytes"
	"crypto/ed25519"
	"database/sql"
	"encoding/json"
	"fmt"
	"github.com/jinwon-int/family-messenger/server/internal/access"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

const enrollmentPath = "/v1/mls/successors/replace-one/enrollment"
const enrolledPath = "/v1/mls/successors/replace-one/enrolled-channel"

func enrollmentReady(t *testing.T, expiry int64) (*Store, *access.Authority, access.Config, successorReservation, []leaseApproval, func(string, string, string, any, string, int) []byte) {
	s, a, c, call := leaseContextFixture(t, func(c *access.Config) {
		if expiry != 0 {
			c.Successors.Intents[0].ExpiresAt = expiry
		}
	})
	p, proofs := confirmationReady(t, call)
	call("owner", "POST", confirmationPath, proofs[0], "alice-next", 201)
	call("family", "POST", confirmationPath, proofs[1], "bob-first", 201)
	v, _, e := s.successorLease(p)
	if e != nil {
		t.Fatal(e)
	}
	call("owner", "POST", leasePath, leaseApproval{"candidate", ed25519.Sign(leaseKey(9), leaseFrame(v, "candidate"))}, "alice-next", 201)
	call("family", "POST", leasePath, leaseApproval{"peer", ed25519.Sign(leaseKey(2), leaseFrame(v, "peer"))}, "bob-first", 201)
	return s, a, c, p, []leaseApproval{{"candidate", ed25519.Sign(leaseKey(9), enrollmentFrame(v, "candidate"))}, {"peer", ed25519.Sign(leaseKey(2), enrollmentFrame(v, "peer"))}}, call
}
func TestEnrollmentPairThenSeparatePolicyAndActualExpiry(t *testing.T) {
	s, a, c, p, qs, call := enrollmentReady(t, time.Now().Unix()+4)
	v, _, _ := s.successorLease(p)
	call("owner", "POST", enrollmentPath, leaseApproval{"candidate", ed25519.Sign(leaseKey(9), leaseFrame(v, "candidate"))}, "alice-next", 403)
	call("owner", "GET", enrolledPath, nil, "alice-next", 403)
	first := call("owner", "POST", enrollmentPath, qs[0], "alice-next", 201)
	if !bytes.Equal(first, call("owner", "POST", enrollmentPath, qs[0], "alice-next", 200)) {
		t.Fatal("replay")
	}
	call("owner", "POST", channelPath, leaseMessage{"old", "alice-next", []byte("x")}, "alice-next", 403)
	call("family", "POST", enrollmentPath, qs[1], "bob-first", 201)
	call("owner", "GET", enrolledPath, nil, "alice-next", 403)
	st, e := s.enrollmentStatus(p)
	if e != nil {
		t.Fatal(e)
	}
	raw, _ := json.Marshal(st.Enrollment)
	c.Activations = []access.Activation{{Intent: "replace-one", ApprovalSHA256: digestMLS(raw), Status: "active"}}
	if e = a.Replace(c); e != nil {
		t.Fatal(e)
	}
	msg := leaseMessage{"persist", "alice-next", []byte("opaque generated application")}
	saved := call("owner", "POST", enrolledPath, msg, "alice-next", 201)
	time.Sleep(time.Until(time.Unix(c.Successors.Intents[0].ExpiresAt, 0)))
	if !bytes.Equal(saved, call("owner", "POST", enrolledPath, msg, "alice-next", 200)) {
		t.Fatal("expired-intent persistent retry")
	}
	call("family", "POST", enrolledPath, leaseMessage{"reply", "bob-first", []byte("persistent reply")}, "bob-first", 201)
	call("owner", "POST", enrollmentPath, qs[0], "alice-next", 403)
	call("owner", "GET", channelPath, nil, "alice-next", 403)
	c.Activations[0].Status = "revoked"
	if e = a.Replace(c); e != nil {
		t.Fatal(e)
	}
	call("owner", "GET", enrolledPath, nil, "alice-next", 403)
	call("owner", "GET", enrollmentPath, nil, "alice-next", 403)
	events, e := s.enrolledHistory(p)
	if e != nil || len(events) != 2 {
		t.Fatal("retained after revocation", e)
	}
}
func TestEnrollmentUsedRetiredMissingAndWrongPolicyDeny(t *testing.T) {
	for _, kind := range []string{"used", "retired", "missing", "wrong-policy"} {
		t.Run(kind, func(t *testing.T) {
			s, a, c, p, qs, call := enrollmentReady(t, 0)
			switch kind {
			case "used":
				call("owner", "POST", channelPath, leaseMessage{"used", "alice-next", []byte("x")}, "alice-next", 201)
			case "retired":
				v, _, _ := s.successorLease(p)
				call("owner", "POST", retirementPath, leaseApproval{"candidate", ed25519.Sign(leaseKey(9), retirementFrame(v, "candidate"))}, "alice-next", 201)
			case "missing":
				if _, e := s.db.Exec("DELETE FROM mls_successor_enrollments"); e != nil {
					t.Fatal(e)
				}
			case "wrong-policy":
				call("owner", "POST", enrollmentPath, qs[0], "alice-next", 201)
				call("family", "POST", enrollmentPath, qs[1], "bob-first", 201)
				c.Activations = []access.Activation{{Intent: "replace-one", ApprovalSHA256: digestMLS([]byte("wrong")), Status: "active"}}
				if e := a.Replace(c); e != nil {
					t.Fatal(e)
				}
				call("owner", "GET", enrolledPath, nil, "alice-next", 403)
				return
			}
			want := 403
			if kind == "missing" {
				want = 422
			}
			call("owner", "POST", enrollmentPath, qs[0], "alice-next", want)
		})
	}
}

func TestEnrollmentConcurrentPairCapacityAndCorruption(t *testing.T) {
	s, a, c, p, qs, call := enrollmentReady(t, 0)
	var wg sync.WaitGroup
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			s.mu.Lock()
			defer s.mu.Unlock()
			role := i % 2
			actor, device := "alice", "alice-next"
			if role == 1 {
				actor, device = "bob", "bob-first"
			}
			if _, _, e := s.approveEnrollment(p, actor, device, qs[role]); e != nil {
				t.Error(e)
			}
		}(i)
	}
	wg.Wait()
	st, e := s.enrollmentStatus(p)
	if e != nil || len(st.Enrollment.Approvals) != 2 {
		t.Fatal(e)
	}
	raw, _ := json.Marshal(st.Enrollment)
	c.Activations = []access.Activation{{Intent: p.Context.Intent, ApprovalSHA256: digestMLS(raw), Status: "active"}}
	if e = a.Replace(c); e != nil {
		t.Fatal(e)
	}
	for i := 0; i < 63; i++ {
		s.mu.Lock()
		_, _, e = s.appendEnrolledMessage(p, leaseMessage{fmt.Sprint("generated-", i), "alice-next", []byte("opaque")})
		s.mu.Unlock()
		if e != nil {
			t.Fatal(e)
		}
	}
	wins := 0
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			s.mu.Lock()
			defer s.mu.Unlock()
			_, created, e := s.appendEnrolledMessage(p, leaseMessage{fmt.Sprint("race-", i), "bob-first", []byte("opaque")})
			if created {
				wins++
			} else if e != ErrLimit {
				t.Error(e)
			}
		}(i)
	}
	wg.Wait()
	if wins != 1 {
		t.Fatal(wins)
	}
	events, e := s.enrolledHistory(p)
	if e != nil || len(events) != 64 {
		t.Fatal(e)
	}
	last := events[63]
	saved := call("family", "POST", enrolledPath, last.Message, "bob-first", 200)
	var got leaseEvent
	if json.Unmarshal(saved, &got) != nil || got.SHA != last.SHA {
		t.Fatal("full exact retry")
	}
	call("owner", "POST", enrolledPath, leaseMessage{"overflow", "alice-next", []byte("opaque")}, "alice-next", 507)
	for _, bad := range [][]byte{[]byte("null"), []byte("{}"), []byte("[] "), []byte(`[ {"role":"candidate","signature":"AA=="} ]`)} {
		if _, e = s.db.Exec("UPDATE mls_successor_enrollments SET approvals=?", bad); e != nil {
			t.Fatal(e)
		}
		call("owner", "GET", enrolledPath, nil, "alice-next", 422)
	}
}

func TestSchema10EnrollmentMigrationRetainsAllFormerRows(t *testing.T) {
	s, _, _, p, _, _ := enrollmentReady(t, 0)
	// Freeze a retired lease in the previous schema; migration must not revive it.
	s.mu.Lock()
	v, _, _ := s.successorLease(p)
	_, _, e := s.retireSuccessor(p, "alice", "alice-next", leaseApproval{"candidate", ed25519.Sign(leaseKey(9), retirementFrame(v, "candidate"))})
	s.mu.Unlock()
	if e != nil {
		t.Fatal(e)
	}
	before, _ := s.retirementRequest(p)
	retained, _ := json.Marshal(before)
	if _, e = s.db.Exec("DROP TABLE mls_successor_enrolled_events; DROP TABLE mls_successor_enrollments; PRAGMA user_version=10;"); e != nil {
		t.Fatal(e)
	}
	var dbSeq int
	var dbName, dbPath string
	if e = s.db.QueryRow("PRAGMA database_list").Scan(&dbSeq, &dbName, &dbPath); e != nil {
		t.Fatal(e)
	}
	dir := filepath.Dir(dbPath)
	s.Close()
	next, e := Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	defer next.Close()
	after, e := next.retirementRequest(p)
	b, _ := json.Marshal(after)
	if e != nil || !bytes.Equal(retained, b) {
		t.Fatal("retirement changed", e)
	}
	if _, e = next.enrollmentStatus(p); e != ErrForbidden {
		t.Fatal("revived retired target", e)
	}
	snapshots, e := filepath.Glob(filepath.Join(dir, "snapshots", "v10-before-successor-enrollment-*.sqlite"))
	if e != nil || len(snapshots) != 1 {
		t.Fatal(snapshots, e)
	}
	file, e := os.Stat(snapshots[0])
	if e != nil || file.Mode().Perm() != 0600 {
		t.Fatal(e)
	}
	db, e := sql.Open("sqlite3", sqliteURI(snapshots[0]))
	if e != nil {
		t.Fatal(e)
	}
	defer db.Close()
	var version int
	if e = db.QueryRow("PRAGMA user_version").Scan(&version); e != nil || version != 10 {
		t.Fatal(version, e)
	}
}
