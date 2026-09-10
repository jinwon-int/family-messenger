package access

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func successorFixture(t *testing.T) (*PolicyStore, Config) {
	t.Helper()
	s, c := storePolicy(t)
	c.Devices = []Device{deviceFixture()}
	if _, e := s.Commit(0, c); e != nil {
		t.Fatal(e)
	}
	c.Successors = &SuccessorPolicy{Administrators: []DeviceAdministrator{{"person-2", "bob"}}, Intents: []SuccessorIntent{}}
	if _, e := s.Commit(1, c); e == nil {
		t.Fatal("implicit successor mode")
	}
	if _, e := s.CommitSuccessor(1, c); e != nil {
		t.Fatal(e)
	}
	return s, c
}
func successorCopy(t *testing.T, c Config) Config {
	t.Helper()
	v, _, e := clone(c)
	if e != nil {
		t.Fatal(e)
	}
	return v
}
func proposed(c Config) Config {
	d := c.Devices[0]
	key := bytes.Repeat([]byte{17}, 32)
	hash := sha256.Sum256(key)
	now := time.Now().Unix()
	c.Successors.Intents = []SuccessorIntent{{ID: "intent-one", Action: "replace", Actor: d.Actor, Subject: d.Subject, Predecessor: d.ID, PredecessorKey: d.SigningKey, PredecessorRevision: 1, Candidate: "alice-next", SigningKey: hex.EncodeToString(key), Fingerprint: hex.EncodeToString(hash[:]), PackageSHA256: hex.EncodeToString(hash[:]), PreviousRoom: "old-room", PreviousGroup: hex.EncodeToString(bytes.Repeat([]byte{1}, 16)), NextRoom: "new-room", Administrator: c.Successors.Administrators[0], Acceptance: "out-of-band-fingerprint", BaseRevision: 2, CreatedAt: now - 1, ExpiresAt: now + 120, Status: "candidate"}}
	return c
}
func accepted(c Config) Config {
	c.Successors.Intents[0].Status = "accepted"
	c.Successors.Intents[0].DecidedAt = time.Now().Unix()
	c.Successors.Intents[0].DecisionRevision = 4
	c.Devices[0].Status = "revoked"
	c.Devices[0].Revision = 2
	return c
}
func TestSuccessorAtomicRetirementReplayAndRestart(t *testing.T) {
	s, c := successorFixture(t)
	legacy, _ := os.ReadFile(filepath.Join(s.dir, revisionName(1)))
	c = proposed(c)
	if _, e := s.CommitSuccessor(2, c); e != nil {
		t.Fatal(e)
	}
	m, e := OpenManaged(s.dir)
	if e != nil {
		t.Fatal(e)
	}
	defer m.Close()
	_, key := fixture(t)
	claims := values(c)
	claims["sub"] = "person-2"
	g, e := verify(m.Authority, sign(t, claims, key))
	if e != nil {
		t.Fatal(e)
	}
	if g.Principal().Owner || g.RunOwner(func() error { return nil }) != ErrDenied {
		t.Fatal("administrator became owner")
	}
	c = accepted(c)
	info, e := s.CommitSuccessor(3, c)
	if e != nil {
		t.Fatal(e)
	}
	again, e := s.CommitSuccessor(3, c)
	if e != nil || again != info {
		t.Fatal("exact accepted retry", e)
	}
	if e = m.Refresh(); e != nil {
		t.Fatal(e)
	}
	if g.Run(func() error { return nil }) != ErrDenied {
		t.Fatal("old grant survived reload")
	}
	m.Close()
	m, e = OpenManaged(s.dir)
	if e != nil {
		t.Fatal(e)
	}
	defer m.Close()
	g, e = verify(m.Authority, sign(t, claims, key))
	if e != nil {
		t.Fatal(e)
	}
	d := g.DeviceBindings()
	if e = g.Run(func() error {
		i, err := g.AcceptedSuccessor("intent-one")
		if err != nil || i != c.Successors.Intents[0] {
			t.Fatal("accepted context snapshot", err)
		}
		i.SigningKey = "caller-mutation"
		if original, _ := g.AcceptedSuccessor("intent-one"); original.SigningKey == i.SigningKey {
			t.Fatal("mutable successor alias")
		}
		if _, err = g.AcceptedSuccessor("missing"); err != ErrDenied {
			t.Fatal("unknown successor")
		}
		// Deterministic expiry after Verify, without wall-clock scheduling sleeps.
		g.successors[0].ExpiresAt = time.Now().Unix()
		if _, err = g.AcceptedSuccessor("intent-one"); err != ErrDenied {
			t.Fatal("expired successor snapshot")
		}
		return nil
	}); e != nil {
		t.Fatal(e)
	}
	if len(d) != 1 || d[0].Status != "revoked" {
		t.Fatal("candidate leaked into admitted devices")
	}
	d[0].Status = "active"
	if g.DeviceBindings()[0].Status != "revoked" {
		t.Fatal("mutable grant alias")
	}
	old, _ := os.ReadFile(filepath.Join(s.dir, revisionName(1)))
	if !bytes.Equal(legacy, old) {
		t.Fatal("legacy changed")
	}
	bad := successorCopy(t, c)
	bad.Successors.Intents = nil
	if _, e = s.CommitSuccessor(4, bad); e == nil {
		t.Fatal("tombstone intent deletion")
	}
	bad = successorCopy(t, c)
	bad.Devices[0].Status = "active"
	bad.Devices[0].Revision = 1
	if _, e = s.CommitSuccessor(4, bad); e == nil {
		t.Fatal("reactivated")
	}
	bad = successorCopy(t, c)
	bad.Successors = nil
	if _, e = s.Commit(4, bad); e == nil {
		t.Fatal("version downgrade")
	}
}
func TestSuccessorCandidateAndDecisionValidation(t *testing.T) {
	s, c := successorFixture(t)
	base := proposed(successorCopy(t, c))
	for name, change := range map[string]func(*Config){
		"actor":           func(c *Config) { c.Successors.Intents[0].Actor = "bob" },
		"subject":         func(c *Config) { c.Successors.Intents[0].Subject = "person-2" },
		"predecessor key": func(c *Config) { c.Successors.Intents[0].PredecessorKey = c.Successors.Intents[0].SigningKey },
		"reused key": func(c *Config) {
			c.Successors.Intents[0].SigningKey = c.Devices[0].SigningKey
			c.Successors.Intents[0].Fingerprint = c.Devices[0].Fingerprint
		},
		"reused id":               func(c *Config) { c.Successors.Intents[0].Candidate = c.Devices[0].ID },
		"owner not administrator": func(c *Config) { c.Successors.Intents[0].Administrator = DeviceAdministrator{"person-1", "alice"} },
		"self designated administrator": func(c *Config) {
			a := DeviceAdministrator{"person-1", "alice"}
			c.Successors.Administrators = []DeviceAdministrator{a}
			c.Successors.Intents[0].Administrator = a
		},
		"wrong base":       func(c *Config) { c.Successors.Intents[0].BaseRevision = 1 },
		"expired":          func(c *Config) { c.Successors.Intents[0].CreatedAt -= 300; c.Successors.Intents[0].ExpiresAt -= 300 },
		"future":           func(c *Config) { c.Successors.Intents[0].CreatedAt += 100 },
		"fingerprint":      func(c *Config) { c.Successors.Intents[0].Fingerprint = "bad" },
		"active candidate": func(c *Config) { c.Successors.Intents[0].Status = "active" },
	} {
		t.Run(name, func(t *testing.T) {
			n := successorCopy(t, base)
			change(&n)
			if _, e := s.CommitSuccessor(2, n); e == nil {
				t.Fatal("invalid intent accepted")
			}
		})
	}
	if _, e := s.CommitSuccessor(2, base); e != nil {
		t.Fatal(e)
	}
	for name, change := range map[string]func(*Config){
		"missing retirement": func(c *Config) { c.Devices[0].Status = "active"; c.Devices[0].Revision = 1 },
		"changed candidate":  func(c *Config) { c.Successors.Intents[0].Candidate = "other-candidate" },
		"new room":           func(c *Config) { c.Successors.Intents[0].NextRoom = "substituted-room" },
		"new owner":          func(c *Config) { c.People[0].Owner = false; c.People[1].Owner = true },
		"new device": func(c *Config) {
			k := bytes.Repeat([]byte{24}, 32)
			h := sha256.Sum256(k)
			c.Devices = append(c.Devices, Device{"bob-first", "bob", "person-2", hex.EncodeToString(k), hex.EncodeToString(h[:]), "active", 1, "out-of-band-fingerprint"})
		},
		"revoked administrator": func(c *Config) { c.Successors.Administrators = []DeviceAdministrator{{"person-1", "alice"}} },
		"decision revision":     func(c *Config) { c.Successors.Intents[0].DecisionRevision = 5 },
		"future decision":       func(c *Config) { c.Successors.Intents[0].DecidedAt += 100 },
	} {
		t.Run(name, func(t *testing.T) {
			n := accepted(successorCopy(t, base))
			change(&n)
			if _, e := s.CommitSuccessor(3, n); e == nil {
				t.Fatal("invalid acceptance")
			}
		})
	}
	// The lock-time clock, not an intent's historical signed-looking timestamp,
	// controls fresh acceptance. History itself remains readable after expiry.
	n := accepted(successorCopy(t, base))
	if successorTransition(base, n, 3, base.Successors.Intents[0].ExpiresAt) == nil {
		t.Fatal("expired accepted with old timestamp")
	}
	if successorTransition(base, n, 3, 0) != nil {
		t.Fatal("historical acceptance expired")
	}
}
func TestSuccessorConcurrentDecisionsAndCancellation(t *testing.T) {
	s, c := successorFixture(t)
	c = proposed(c)
	if _, e := s.CommitSuccessor(2, c); e != nil {
		t.Fatal(e)
	}
	a := accepted(successorCopy(t, c))
	b := successorCopy(t, c)
	b.Successors.Intents[0].Status = "cancelled"
	b.Successors.Intents[0].DecidedAt = time.Now().Unix()
	b.Successors.Intents[0].DecisionRevision = 4
	var wg sync.WaitGroup
	out := make(chan error, 2)
	for _, n := range []Config{a, b} {
		wg.Add(1)
		go func(n Config) {
			defer wg.Done()
			other, e := OpenPolicyStore(s.dir)
			if e == nil {
				_, e = other.CommitSuccessor(3, n)
			}
			out <- e
		}(n)
	}
	wg.Wait()
	close(out)
	ok, conflicts := 0, 0
	for e := range out {
		if e == nil {
			ok++
		} else if errors.Is(e, ErrPolicyConflict) {
			conflicts++
		} else {
			t.Fatal(e)
		}
	}
	if ok != 1 || conflicts != 1 {
		t.Fatal(ok, conflicts)
	}
	info, n, e := s.Read()
	if e != nil || info.Revision != 4 {
		t.Fatal(e)
	}
	if _, e = s.CommitSuccessor(2, c); !errors.Is(e, ErrPolicyConflict) {
		t.Fatal("old outcome resumed across decision", e)
	}
	if n.Successors.Intents[0].Status == "accepted" && n.Devices[0].Status != "revoked" {
		t.Fatal("partial acceptance")
	}
}
func TestSuccessorUncertainWritesAndSkippedReload(t *testing.T) {
	for _, stage := range []string{"file-synced", "renamed"} {
		t.Run(stage, func(t *testing.T) {
			s, c := successorFixture(t)
			m, e := OpenManaged(s.dir)
			if e != nil {
				t.Fatal(e)
			}
			defer m.Close()
			c = proposed(c)
			if _, e = s.CommitSuccessor(2, c); e != nil {
				t.Fatal(e)
			}
			c = accepted(c)
			s.fault = func(at string) error {
				if at == stage {
					return errors.New("synthetic crash")
				}
				return nil
			}
			if _, e = s.CommitSuccessor(3, c); e != ErrPolicyUncertain {
				t.Fatal(e)
			}
			s.fault = nil
			if stage == "file-synced" {
				if _, _, e = s.Read(); e == nil {
					t.Fatal("pending not retained and denied")
				}
				if e = m.Refresh(); e == nil {
					t.Fatal("live error not suspended")
				}
			} else {
				if e = m.Refresh(); e != nil {
					t.Fatal("skipped candidate reload", e)
				}
				if _, e = s.CommitSuccessor(3, c); e != nil {
					t.Fatal("exact renamed outcome", e)
				}
				if m.Authority.config.Devices[0].Status != "revoked" {
					t.Fatal("revocation lost")
				}
			}
		})
	}
}
func TestSuccessorVersionStrictFieldsAndHistory(t *testing.T) {
	s, c := successorFixture(t)
	c = proposed(c)
	raw, e := EncodePolicy(c)
	if e != nil {
		t.Fatal(e)
	}
	for _, bad := range [][]byte{bytes.Replace(raw, []byte(`"version":2`), []byte(`"version":1`), 1), bytes.Replace(raw, []byte(`"intents":[`), []byte(`"Intents":[`), 1), bytes.Replace(raw, []byte(`"intent_id":`), []byte(`"intent_id":"duplicate","intent_id":`), 1), bytes.Replace(raw, []byte(`"decided_at":0`), []byte(`"decided_at":null`), 1)} {
		if _, e := ParsePolicy(bad); e == nil {
			t.Fatal("ambiguous v2 accepted")
		}
	}
	if _, e = s.CommitSuccessor(2, c); e != nil {
		t.Fatal(e)
	}
	if _, e = s.CommitSuccessor(3, accepted(c)); e != nil {
		t.Fatal(e)
	}
	// Replace a middle intent with a different immutable ID and recompute its
	// checksum and following raw hash chain: semantic history must still reject.
	path := filepath.Join(s.dir, revisionName(3))
	b, e := os.ReadFile(path)
	if e != nil {
		t.Fatal(e)
	}
	b = bytes.Replace(b, []byte(`"intent_id":"intent-one"`), []byte(`"intent_id":"substituted"`), 1)
	var r policyRecord
	if e = json.Unmarshal(b, &r); e != nil {
		t.Fatal(e)
	}
	encoded, _ := json.Marshal(r.Policy)
	hash := sha256.Sum256(encoded)
	r.PolicySHA256 = hex.EncodeToString(hash[:])
	b, _ = json.Marshal(r)
	b = append(b, '\n')
	if e = os.WriteFile(path, b, 0600); e != nil {
		t.Fatal(e)
	}
	previous := sha256.Sum256(b)
	path = filepath.Join(s.dir, revisionName(4))
	b, e = os.ReadFile(path)
	if e != nil {
		t.Fatal(e)
	}
	if e = json.Unmarshal(b, &r); e != nil {
		t.Fatal(e)
	}
	r.Previous = hex.EncodeToString(previous[:])
	b, _ = json.Marshal(r)
	b = append(b, '\n')
	if e = os.WriteFile(path, b, 0600); e != nil {
		t.Fatal(e)
	}
	if _, _, e = s.Read(); e == nil {
		t.Fatal("changed historical intent accepted")
	}
}

func TestSuccessorEmergencyDenyAllSurvivesRestart(t *testing.T) {
	s, c := successorFixture(t)
	c = proposed(c)
	if _, e := s.CommitSuccessor(2, c); e != nil {
		t.Fatal(e)
	}
	m, e := OpenManaged(s.dir)
	if e != nil {
		t.Fatal(e)
	}
	defer m.Close()
	_, key := fixture(t)
	token := sign(t, values(c), key)
	g, e := verify(m.Authority, token)
	if e != nil {
		t.Fatal(e)
	}
	c.People = nil
	c.Successors.Administrators = nil
	c.Devices[0].Status = "revoked"
	c.Devices[0].Revision = 2
	if _, e = s.CommitSuccessor(3, c); e != nil {
		t.Fatal("emergency deny-all rejected", e)
	}
	if e = m.Refresh(); e != nil {
		t.Fatal(e)
	}
	if g.Run(func() error { return nil }) != ErrDenied {
		t.Fatal("old grant survived deny-all")
	}
	m.Close()
	m, e = OpenManaged(s.dir)
	if e != nil {
		t.Fatal(e)
	}
	defer m.Close()
	if _, e = verify(m.Authority, token); e != ErrDenied {
		t.Fatal("account restored on restart")
	}
	_, saved, e := s.Read()
	if e != nil || len(saved.People) != 0 || len(saved.Successors.Administrators) != 0 || len(saved.Successors.Intents) != 1 || saved.Devices[0].Status != "revoked" {
		t.Fatal("deny-all history lost", e)
	}
	// An explicit first v2 configuration still establishes a real administrator.
	other, initial := storePolicy(t)
	initial.Successors = &SuccessorPolicy{}
	if _, e = other.CommitSuccessor(0, initial); e == nil {
		t.Fatal("empty initial v2 administration")
	}
}

func TestSuccessorCancelledIntentAllowsFreshCandidateButNeverKeyReuse(t *testing.T) {
	s, c := successorFixture(t)
	c = proposed(c)
	if _, e := s.CommitSuccessor(2, c); e != nil {
		t.Fatal(e)
	}
	c.Successors.Intents[0].Status = "cancelled"
	c.Successors.Intents[0].DecidedAt = time.Now().Unix()
	c.Successors.Intents[0].DecisionRevision = 4
	if _, e := s.CommitSuccessor(3, c); e != nil {
		t.Fatal(e)
	}
	n := c.Successors.Intents[0]
	n.ID = "fresh-intent"
	n.Candidate = "fresh-candidate"
	n.BaseRevision = 4
	n.Status = "candidate"
	n.DecidedAt = 0
	n.DecisionRevision = 0
	c.Successors.Intents = append(c.Successors.Intents, n)
	if _, e := s.CommitSuccessor(4, c); e == nil {
		t.Fatal("cancelled public key reused")
	}
	k := bytes.Repeat([]byte{51}, 32)
	h := sha256.Sum256(k)
	c.Successors.Intents[1].SigningKey = hex.EncodeToString(k)
	c.Successors.Intents[1].Fingerprint = hex.EncodeToString(h[:])
	if _, e := s.CommitSuccessor(4, c); e != nil {
		t.Fatal("fresh replacement after cancellation denied", e)
	}
	_, saved, e := s.Read()
	if e != nil || len(saved.Successors.Intents) != 2 || saved.Successors.Intents[0].Status != "cancelled" {
		t.Fatal("lost cancellation tombstone", e)
	}
}
