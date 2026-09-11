package access

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"sync"
	"testing"
)

func activationFixture(t *testing.T) (*PolicyStore, Config) {
	s, c := successorFixture(t)
	c = proposed(c)
	if _, e := s.CommitSuccessor(2, c); e != nil {
		t.Fatal(e)
	}
	c = accepted(c)
	if _, e := s.CommitSuccessor(3, c); e != nil {
		t.Fatal(e)
	}
	return s, c
}
func TestExplicitActivationJournalRetainsLegacyAndRevocation(t *testing.T) {
	s, c := activationFixture(t)
	old := map[string][]byte{}
	for i := uint64(1); i <= 4; i++ {
		p := filepath.Join(s.dir, revisionName(i))
		old[p], _ = os.ReadFile(p)
	}
	c.Activations = []Activation{{"intent-one", string(bytes.Repeat([]byte("a"), 64)), "active"}}
	if _, e := s.Commit(4, c); e == nil {
		t.Fatal("implicit activation")
	}
	if _, e := s.CommitSuccessor(4, c); e == nil {
		t.Fatal("old lifecycle mode admitted activation")
	}
	info, e := s.CommitActivation(4, c)
	if e != nil {
		t.Fatal(e)
	}
	again, e := s.CommitActivation(4, c)
	if e != nil || again != info {
		t.Fatal("exact replay", e)
	}
	fresh, e := OpenPolicyStore(s.dir)
	if e != nil {
		t.Fatal(e)
	}
	_, saved, e := fresh.Read()
	if e != nil || !reflect.DeepEqual(saved.Activations, c.Activations) {
		t.Fatal(e)
	}
	for p, b := range old {
		now, _ := os.ReadFile(p)
		if !bytes.Equal(now, b) {
			t.Fatal("old revision modified")
		}
	}
	bad := successorCopy(t, c)
	bad.Activations[0].ApprovalSHA256 = string(bytes.Repeat([]byte("b"), 64))
	if _, e = s.CommitActivation(5, bad); e == nil {
		t.Fatal("rebound digest")
	}
	bad = successorCopy(t, c)
	bad.Activations = nil
	if _, e = s.Commit(5, bad); e == nil {
		t.Fatal("removed activation tombstone")
	}
	c.Activations[0].Status = "revoked"
	if _, e = s.CommitActivation(5, c); e != nil {
		t.Fatal(e)
	}
	c.Activations[0].Status = "active"
	if _, e = s.CommitActivation(6, c); e == nil {
		t.Fatal("reactivation")
	}
}
func TestActivationCurrentExpiryAndNoBundledAuthorityChange(t *testing.T) {
	s, c := activationFixture(t)
	next := successorCopy(t, c)
	next.Activations = []Activation{{"intent-one", string(bytes.Repeat([]byte("a"), 64)), "active"}}
	if activationTransition(c, next, c.Successors.Intents[0].ExpiresAt) == nil {
		t.Fatal("expired activation")
	}
	if activationTransition(c, next, 0) != nil {
		t.Fatal("historical expiry")
	}
	for _, mutate := range []func(*Config){func(x *Config) { x.People = nil }, func(x *Config) { x.Successors.Administrators = nil }, func(x *Config) { x.Devices[0].Status = "active"; x.Devices[0].Revision = 1 }} {
		b := successorCopy(t, next)
		mutate(&b)
		if _, e := s.CommitActivation(4, b); e == nil {
			t.Fatal("bundled mutation")
		}
	}
}
func TestActivationConcurrentAndUnknownCommit(t *testing.T) {
	s, c := activationFixture(t)
	c.Activations = []Activation{{"intent-one", string(bytes.Repeat([]byte("a"), 64)), "active"}}
	var wg sync.WaitGroup
	for j := 0; j < 6; j++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if info, e := s.CommitActivation(4, c); e != nil || info.Revision != 5 {
				t.Error(info, e)
			}
		}()
	}
	wg.Wait()
	for _, stage := range []string{"file-synced", "renamed"} {
		t.Run(stage, func(t *testing.T) {
			s, c := activationFixture(t)
			c.Activations = []Activation{{"intent-one", string(bytes.Repeat([]byte("b"), 64)), "active"}}
			s.fault = func(at string) error {
				if at == stage {
					return errors.New("generated interruption")
				}
				return nil
			}
			if _, e := s.CommitActivation(4, c); !errors.Is(e, ErrPolicyUncertain) {
				t.Fatal(e)
			}
			s.fault = nil
			info, _, e := s.Read()
			if stage == "renamed" {
				if e != nil || info.Revision != 5 {
					t.Fatal(info, e)
				}
				if _, e = s.CommitActivation(4, c); e != nil {
					t.Fatal(e)
				}
			} else if e == nil {
				t.Fatal("unresolved pending must deny")
			}
		})
	}
}
func TestActivationGrantRetiresWithCurrentPolicy(t *testing.T) {
	_, c := activationFixture(t)
	c.Activations = []Activation{{"intent-one", string(bytes.Repeat([]byte("a"), 64)), "active"}}
	a, e := New(c)
	if e != nil {
		t.Fatal(e)
	}
	_, key := fixture(t)
	g, e := verify(a, sign(t, values(c), key))
	if e != nil {
		t.Fatal(e)
	}
	if e = g.Run(func() error { _, _, e := g.ActivatedSuccessor("intent-one"); return e }); e != nil {
		t.Fatal(e)
	}
	c.Activations[0].Status = "revoked"
	if e = a.Replace(c); e != nil {
		t.Fatal(e)
	}
	if g.Run(func() error { return nil }) != ErrDenied {
		t.Fatal("stale grant")
	}
	// Expired new transitions are independently checked with immutable historical
	// timestamps above; no production clock override is needed.
}
