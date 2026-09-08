package access

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func policyDir(t *testing.T) string {
	t.Helper()
	d := t.TempDir()
	if e := os.Chmod(d, 0700); e != nil {
		t.Fatal(e)
	}
	return d
}
func storePolicy(t *testing.T) (*PolicyStore, Config) {
	t.Helper()
	c, _ := fixture(t)
	s, e := OpenPolicyStore(policyDir(t))
	if e != nil {
		t.Fatal(e)
	}
	return s, c
}
func TestPolicyEncodingAndStrictFields(t *testing.T) {
	c, _ := fixture(t)
	b, e := EncodePolicy(c)
	if e != nil {
		t.Fatal(e)
	}
	got, e := ParsePolicy(b)
	if e != nil || got.Issuer != c.Issuer || len(got.People) != 2 {
		t.Fatal(e)
	}
	for _, bad := range [][]byte{bytes.Replace(b, []byte(`"owner":true`), []byte(`"Owner":true`), 1), bytes.Replace(b, []byte(`"owner":true`), []byte(`"owner":true,"owner":false`), 1), bytes.Replace(b, []byte(`"owner":true`), []byte(`"owner":null`), 1), append(b, b...), []byte(strings.Repeat("x", MaxPolicyBytes+1))} {
		if _, e = ParsePolicy(bad); e == nil {
			t.Fatal("bad policy parsed")
		}
	}
	for _, suffix := range []string{"?", "#", "/"} {
		bad := c
		bad.Issuer += suffix
		if _, e = EncodePolicy(bad); e == nil {
			t.Fatal("non-origin issuer accepted")
		}
	}
	c.People = nil
	b, e = EncodePolicy(c)
	if e != nil {
		t.Fatal(e)
	}
	if _, e = ParsePolicy(b); e != nil {
		t.Fatal("empty denial policy rejected")
	}
}
func TestPolicyCommitRestartAndNoOverwrite(t *testing.T) {
	s, c := storePolicy(t)
	if _, _, e := s.Read(); e == nil {
		t.Fatal("missing policy accepted")
	}
	first, e := s.Commit(0, c)
	if e != nil || first.Revision != 1 {
		t.Fatal(e)
	}
	old, e := os.ReadFile(filepath.Join(s.dir, revisionName(1)))
	if e != nil {
		t.Fatal(e)
	}
	c.People = c.People[1:]
	second, e := s.Commit(1, c)
	if e != nil || second.Revision != 2 {
		t.Fatal(e)
	}
	again, e := OpenPolicyStore(s.dir)
	if e != nil {
		t.Fatal(e)
	}
	info, got, e := again.Read()
	if e != nil || info != second || len(got.People) != 1 || got.People[0].Actor != "bob" {
		t.Fatal("restart did not retain policy", e)
	}
	unchanged, _ := os.ReadFile(filepath.Join(s.dir, revisionName(1)))
	if !bytes.Equal(old, unchanged) {
		t.Fatal("old revision overwritten")
	}
	if _, e = s.Commit(1, c); e != ErrPolicyConflict {
		t.Fatal("stale writer accepted")
	}
	entries, _ := os.ReadDir(s.dir)
	if len(entries) != 3 {
		t.Fatal("unexpected revision files")
	}
	for _, ent := range entries {
		st, _ := os.Lstat(filepath.Join(s.dir, ent.Name()))
		if st.Mode().Perm() != 0600 {
			t.Fatal("wrong mode")
		}
	}
}
func TestPolicyConcurrentCompareAndSwap(t *testing.T) {
	s, c := storePolicy(t)
	s.Commit(0, c)
	s2, _ := OpenPolicyStore(s.dir)
	var wg sync.WaitGroup
	results := make(chan error, 2)
	for _, store := range []*PolicyStore{s, s2} {
		wg.Add(1)
		go func(s *PolicyStore) { defer wg.Done(); _, e := s.Commit(1, c); results <- e }(store)
	}
	wg.Wait()
	close(results)
	success, conflict := 0, 0
	for e := range results {
		if e == nil {
			success++
		} else if e == ErrPolicyConflict {
			conflict++
		} else {
			t.Fatal(e)
		}
	}
	if success != 1 || conflict != 1 {
		t.Fatal("lost update")
	}
}
func TestPolicyRetainsInterruptedWrites(t *testing.T) {
	for _, phase := range []string{"file-synced", "renamed"} {
		t.Run(phase, func(t *testing.T) {
			s, c := storePolicy(t)
			s.Commit(0, c)
			c.People = nil
			s.fault = func(at string) error {
				if at == phase {
					return errors.New("synthetic failure")
				}
				return nil
			}
			if _, e := s.Commit(1, c); e != ErrPolicyUncertain {
				t.Fatal(e)
			}
			s.fault = nil
			info, got, e := s.Read()
			if phase == "file-synced" {
				if e == nil {
					t.Fatal("pending revision fell back to old access")
				}
				entries, _ := os.ReadDir(s.dir)
				if len(entries) != 3 {
					t.Fatal("interrupted evidence deleted")
				}
			} else {
				if e != nil || info.Revision != 2 || len(got.People) != 0 {
					t.Fatal("renamed revision disappeared", e)
				}
			}
		})
	}
}
func TestManagedSuspensionAndHigherRevisionRecovery(t *testing.T) {
	s, c := storePolicy(t)
	s.Commit(0, c)
	m, e := OpenManaged(s.dir)
	if e != nil {
		t.Fatal(e)
	}
	defer m.Close()
	_, k := fixture(t)
	raw := sign(t, values(c), k)
	grant, e := verify(m.Authority, raw)
	if e != nil {
		t.Fatal(e)
	}
	// A permission error immediately retires access on refresh, and merely undoing
	// the error cannot silently revive the same revision/grants.
	p := filepath.Join(s.dir, revisionName(1))
	os.Chmod(p, 0644)
	if m.Refresh() == nil {
		t.Fatal("unsafe mode accepted")
	}
	if _, e = verify(m.Authority, raw); e != ErrDenied {
		t.Fatal("suspension failed")
	}
	os.Chmod(p, 0600)
	if m.Refresh() == nil {
		t.Fatal("same revision silently reactivated")
	}
	c.People = nil
	if _, e = s.Commit(1, c); e != nil {
		t.Fatal(e)
	}
	if e = m.Refresh(); e != nil {
		t.Fatal(e)
	}
	if grant.Run(func() error { return nil }) != ErrDenied {
		t.Fatal("old grant revived")
	}
	if _, e = verify(m.Authority, raw); e != ErrDenied {
		t.Fatal("revoked user restored")
	}
	m2, e := OpenManaged(s.dir)
	if e != nil {
		t.Fatal(e)
	}
	defer m2.Close()
	if _, e = verify(m2.Authority, raw); e != ErrDenied {
		t.Fatal("restart restored revoked user")
	}
	m.Close()
	if m.Refresh() == nil {
		t.Fatal("closed manager reloaded")
	}
}
func TestManagedRejectsRollbackAndChangedHistory(t *testing.T) {
	s, c := storePolicy(t)
	s.Commit(0, c)
	s.Commit(1, c)
	m, e := OpenManaged(s.dir)
	if e != nil {
		t.Fatal(e)
	}
	defer m.Close()
	// Simulate external replacement while preserving the displaced file outside
	// the auth directory. No automatic recovery from an older prefix is allowed.
	saved := filepath.Join(policyDir(t), "saved.json")
	os.Rename(filepath.Join(s.dir, revisionName(2)), saved)
	if m.Refresh() == nil {
		t.Fatal("rollback accepted")
	}
	os.Rename(saved, filepath.Join(s.dir, revisionName(2)))
	if m.Refresh() == nil {
		t.Fatal("old policy silently resumed")
	}
	if _, e = s.Commit(2, c); e != nil {
		t.Fatal(e)
	}
	if e = m.Refresh(); e != nil {
		t.Fatal(e)
	}
	b, _ := os.ReadFile(filepath.Join(s.dir, revisionName(1)))
	b = bytes.Replace(b, []byte(`"owner":true`), []byte(`"owner":false`), 1)
	os.WriteFile(filepath.Join(s.dir, revisionName(1)), b, 0600)
	if m.Refresh() == nil {
		t.Fatal("changed history accepted")
	}
}
func TestPolicyUnsafeStatePreserved(t *testing.T) {
	for _, kind := range []string{"symlink", "hardlink", "mode", "unknown", "pending", "gap", "lock-data"} {
		t.Run(kind, func(t *testing.T) {
			s, c := storePolicy(t)
			s.Commit(0, c)
			p := filepath.Join(s.dir, revisionName(1))
			saved := filepath.Join(policyDir(t), "saved")
			switch kind {
			case "symlink":
				os.Rename(p, saved)
				os.Symlink(saved, p)
			case "hardlink":
				os.Link(p, saved)
			case "mode":
				os.Chmod(p, 0640)
			case "unknown":
				os.WriteFile(filepath.Join(s.dir, "unrelated"), []byte("preserve"), 0600)
			case "pending":
				os.WriteFile(filepath.Join(s.dir, "pending-test"), []byte("preserve"), 0600)
			case "gap":
				os.Rename(p, filepath.Join(s.dir, revisionName(2)))
			case "lock-data":
				os.WriteFile(filepath.Join(s.dir, "lock"), []byte("preserve"), 0600)
			}
			before, _ := os.ReadDir(s.dir)
			if _, _, e := s.Read(); e == nil {
				t.Fatal("unsafe state accepted")
			}
			if _, e := s.Commit(1, c); e == nil {
				t.Fatal("unsafe state changed")
			}
			after, _ := os.ReadDir(s.dir)
			if len(before) != len(after) {
				t.Fatal("evidence changed")
			}
		})
	}
	d := policyDir(t)
	alias := filepath.Join(policyDir(t), "alias")
	os.Symlink(d, alias)
	if _, e := OpenPolicyStore(alias); e == nil {
		t.Fatal("symlinked directory accepted")
	}
	os.Chmod(d, 0755)
	if _, e := OpenPolicyStore(d); e == nil {
		t.Fatal("nonprivate directory accepted")
	}
}
func TestPolicyRevisionCapacity(t *testing.T) {
	s, c := storePolicy(t)
	for n := uint64(0); n < MaxPolicyRevisions; n++ {
		if _, e := s.Commit(n, c); e != nil {
			t.Fatal(n, e)
		}
	}
	if _, e := s.Commit(MaxPolicyRevisions, c); e == nil {
		t.Fatal("unbounded history")
	}
	info, _, e := s.Read()
	if e != nil || info.Revision != MaxPolicyRevisions {
		t.Fatal("capacity lost history", e)
	}
}
func TestManagedRefreshSerializesWithCommit(t *testing.T) {
	s, c := storePolicy(t)
	s.Commit(0, c)
	m, e := OpenManaged(s.dir)
	if e != nil {
		t.Fatal(e)
	}
	defer m.Close()
	_, k := fixture(t)
	g, _ := verify(m.Authority, sign(t, values(c), k))
	entered, release := make(chan struct{}), make(chan struct{})
	go g.Run(func() error { close(entered); <-release; return nil })
	<-entered
	c.People = nil
	s.Commit(1, c)
	refreshed := make(chan error, 1)
	go func() { refreshed <- m.Refresh() }()
	time.Sleep(20 * time.Millisecond)
	close(release)
	select {
	case e = <-refreshed:
		if e != nil {
			t.Fatal(e)
		}
	case <-time.After(time.Second):
		t.Fatal("refresh deadlocked")
	}
	if g.Run(func() error { return nil }) != ErrDenied {
		t.Fatal("old grant retained")
	}
}

func TestManagedRemembersObservedHigherRevision(t *testing.T) {
	s, c := storePolicy(t)
	s.Commit(0, c)
	m, e := OpenManaged(s.dir)
	if e != nil {
		t.Fatal(e)
	}
	defer m.Close()
	p := filepath.Join(s.dir, revisionName(3))
	os.WriteFile(p, []byte("incomplete synthetic record"), 0600)
	if m.Refresh() == nil {
		t.Fatal("gap accepted")
	}
	os.Rename(p, filepath.Join(policyDir(t), "preserved"))
	if _, e = s.Commit(1, c); e != nil {
		t.Fatal(e)
	}
	if m.Refresh() == nil {
		t.Fatal("lower than observed revision reactivated")
	}
}
func TestCandidateFileSafety(t *testing.T) {
	c, _ := fixture(t)
	b, _ := EncodePolicy(c)
	dir := policyDir(t)
	p := filepath.Join(dir, "candidate.json")
	os.WriteFile(p, b, 0600)
	if _, e := ReadCandidate(p); e != nil {
		t.Fatal(e)
	}
	os.Chmod(p, 0644)
	if _, e := ReadCandidate(p); e == nil {
		t.Fatal("public candidate accepted")
	}
	os.Chmod(p, 0600)
	alias := filepath.Join(dir, "alias")
	os.Symlink(p, alias)
	if _, e := ReadCandidate(alias); e == nil {
		t.Fatal("symlink candidate accepted")
	}
	os.Link(p, filepath.Join(dir, "hardlink"))
	if _, e := ReadCandidate(p); e == nil {
		t.Fatal("hardlinked candidate accepted")
	}
}
func TestPolicyLatestSemanticCorruptionRejected(t *testing.T) {
	s, c := storePolicy(t)
	s.Commit(0, c)
	p := filepath.Join(s.dir, revisionName(1))
	b, _ := os.ReadFile(p)
	changed := bytes.Replace(b, []byte(`"owner":true`), []byte(`"owner":false`), 1)
	if bytes.Equal(b, changed) {
		t.Fatal("fixture not changed")
	}
	os.WriteFile(p, changed, 0600)
	if _, _, e := s.Read(); e == nil {
		t.Fatal("latest valid JSON corruption accepted")
	}
}
