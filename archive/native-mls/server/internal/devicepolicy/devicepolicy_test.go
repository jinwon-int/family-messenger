package devicepolicy

import (
	"bytes"
	"crypto/ed25519"
	crand "crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

func testDir(t *testing.T) string {
	t.Helper()
	d := t.TempDir()
	if e := os.Chmod(d, 0700); e != nil {
		t.Fatal(e)
	}
	return d
}

type deviceKey struct {
	priv   ed25519.PrivateKey
	hexKey string
	fp     string
}

func newKey(t *testing.T) deviceKey {
	t.Helper()
	pub, priv, e := ed25519.GenerateKey(crand.Reader)
	if e != nil {
		t.Fatal(e)
	}
	sum := sha256.Sum256(pub)
	return deviceKey{priv: priv, hexKey: hex.EncodeToString(pub), fp: hex.EncodeToString(sum[:])}
}

// device builds a record whose fingerprint matches the key, as required by
// validateDeviceSet.
func (k deviceKey) device(id, actor, subject, acceptance, status string, revision uint64, approvedBy *DeviceApproval) DeviceV4 {
	return DeviceV4{
		ID:          id,
		Actor:       actor,
		Subject:     subject,
		SigningKey:  k.hexKey,
		Fingerprint: k.fp,
		Status:      status,
		Revision:    revision,
		Acceptance:  acceptance,
		ApprovedBy:  approvedBy,
	}
}

func (k deviceKey) sign(t *testing.T, payload ApprovalPayloadWire) string {
	t.Helper()
	msg, e := ApprovalMessage(payload)
	if e != nil {
		t.Fatal(e)
	}
	return hex.EncodeToString(ed25519.Sign(k.priv, msg))
}

func set(devices ...DeviceV4) PolicyWire4 {
	return PolicyWire4{Version: DevicePolicyVersion, Devices: devices}
}

func mustOpen(t *testing.T, dir string) *DevicePolicyStore {
	t.Helper()
	s, e := OpenDevicePolicyStore(dir)
	if e != nil {
		t.Fatal(e)
	}
	return s
}

func mustRead(t *testing.T, s *DevicePolicyStore) (DevicePolicyInfo, PolicyWire4) {
	t.Helper()
	info, policy, e := s.Read()
	if e != nil {
		t.Fatal(e)
	}
	return info, policy
}

// baseWithAlice creates a store at revision 2 with alice's out-of-band first
// device dev-a1 active.
func baseWithAlice(t *testing.T) (*DevicePolicyStore, DeviceV4, deviceKey) {
	t.Helper()
	s := mustOpen(t, testDir(t))
	if _, e := s.Init(); e != nil {
		t.Fatal(e)
	}
	k := newKey(t)
	d := k.device("dev-a1", "alice", "person-alice", AcceptanceOutOfBand, StatusActive, 1, nil)
	if _, e := s.Commit(1, set(d)); e != nil {
		t.Fatal(e)
	}
	return s, d, k
}

// enrollApproved performs one E2 commit: dev approved by approverKey, bound to
// the revision the commit creates.
func enrollApproved(t *testing.T, s *DevicePolicyStore, expected uint64, current []DeviceV4, id, actor, subject string, approverKey deviceKey) (deviceKey, DevicePolicyInfo) {
	t.Helper()
	k := newKey(t)
	payload := ApprovalPayloadWire{
		Action:       ApprovalActionAdd,
		DeviceID:     id,
		Actor:        actor,
		Subject:      subject,
		SigningKey:   k.hexKey,
		Fingerprint:  k.fp,
		Acceptance:   AcceptanceTrusted,
		BaseRevision: expected,
	}
	sig := approverKey.sign(t, payload)
	approver, e := VerifyApproval(current, ApprovalActionAdd, payload, approverKey.hexKey, sig, expected)
	if e != nil {
		t.Fatal(e)
	}
	next := append(append([]DeviceV4(nil), current...), k.device(id, actor, subject, AcceptanceTrusted, StatusActive, 1, &DeviceApproval{DeviceID: approver, Revision: expected + 1}))
	info, e := s.Commit(expected, set(next...))
	if e != nil {
		t.Fatal(e)
	}
	return k, info
}

func revisionCount(t *testing.T, dir string) int {
	t.Helper()
	entries, e := os.ReadDir(dir)
	if e != nil {
		t.Fatal(e)
	}
	n := 0
	for _, ent := range entries {
		if strings.HasPrefix(ent.Name(), "policy-") {
			n++
		}
	}
	return n
}

func TestV4ChainHappyPath(t *testing.T) {
	s, a1, ka := baseWithAlice(t)
	// E2: alice's second device approved by dev-a1 (revision 2 → 3).
	_, info := enrollApproved(t, s, 2, []DeviceV4{a1}, "dev-a2", "alice", "person-alice", ka)
	if info.Revision != 3 {
		t.Fatalf("revision = %d, want 3", info.Revision)
	}
	// E1 for bob (out-of-band, first active device of the actor).
	b1key := newKey(t)
	b1 := b1key.device("dev-b1", "bob", "person-bob", AcceptanceOutOfBand, StatusActive, 1, nil)
	if _, e := s.Commit(3, set(a1, mustDevice(t, s, "dev-a2"), b1)); e != nil {
		t.Fatal(e)
	}
	// E2 for bob's second device approved by dev-b1.
	b2key, info := enrollApproved(t, s, 4, readCurrent(t, s), "dev-b2", "bob", "person-bob", b1key)
	if info.Revision != 5 {
		t.Fatalf("revision = %d, want 5", info.Revision)
	}
	// E3 with device-signed revocation evidence: dev-b1 is out-of-band (no
	// approved_by yet), so the tombstone may carry evidence written once.
	current := readCurrent(t, s)
	var b1rec DeviceV4
	for _, d := range current {
		if d.ID == "dev-b1" {
			b1rec = d
		}
	}
	payload := ApprovalPayloadWire{
		Action:       ApprovalActionRevoke,
		DeviceID:     "dev-b1",
		Actor:        "bob",
		Subject:      "person-bob",
		SigningKey:   b1rec.SigningKey,
		Fingerprint:  b1rec.Fingerprint,
		Acceptance:   b1rec.Acceptance,
		BaseRevision: 5,
	}
	sig := b2key.sign(t, payload)
	approver, e := VerifyApproval(current, ApprovalActionRevoke, payload, b2key.hexKey, sig, 5)
	if e != nil || approver != "dev-b2" {
		t.Fatalf("revocation evidence: approver=%q err=%v", approver, e)
	}
	var next []DeviceV4
	for _, d := range current {
		if d.ID == "dev-b1" {
			d.Status = StatusRevoked
			d.Revision = 2
			d.ApprovedBy = &DeviceApproval{DeviceID: approver, Revision: 6}
		}
		next = append(next, d)
	}
	info, e = s.Commit(5, set(next...))
	if e != nil || info.Revision != 6 {
		t.Fatalf("revoke commit: info=%+v err=%v", info, e)
	}
	// Full-chain replay validates every transition and binding.
	final, policy := mustRead(t, s)
	if final.Revision != 6 {
		t.Fatalf("final revision = %d, want 6", final.Revision)
	}
	byID := map[string]DeviceV4{}
	for _, d := range policy.Devices {
		byID[d.ID] = d
	}
	if len(policy.Devices) != 4 {
		t.Fatalf("devices = %d, want 4", len(policy.Devices))
	}
	if d := byID["dev-a2"]; d.Status != StatusActive || d.ApprovedBy == nil || d.ApprovedBy.DeviceID != "dev-a1" || d.ApprovedBy.Revision != 3 {
		t.Fatalf("dev-a2 = %+v", d)
	}
	if d := byID["dev-b1"]; d.Status != StatusRevoked || d.Revision != 2 || d.ApprovedBy == nil || d.ApprovedBy.DeviceID != "dev-b2" || d.ApprovedBy.Revision != 6 {
		t.Fatalf("dev-b1 = %+v", d)
	}
	if d := byID["dev-b2"]; d.Status != StatusActive || d.ApprovedBy == nil || d.ApprovedBy.DeviceID != "dev-b1" || d.ApprovedBy.Revision != 5 {
		t.Fatalf("dev-b2 = %+v", d)
	}
	if n := revisionCount(t, s.dir); n != 6 {
		t.Fatalf("revision files = %d, want 6", n)
	}
}

func readCurrent(t *testing.T, s *DevicePolicyStore) []DeviceV4 {
	t.Helper()
	_, policy := mustRead(t, s)
	return policy.Devices
}

// mustDevice fetches a device record from the store's committed state.
func mustDevice(t *testing.T, s *DevicePolicyStore, id string) DeviceV4 {
	t.Helper()
	for _, d := range readCurrent(t, s) {
		if d.ID == id {
			return d
		}
	}
	t.Fatalf("device %q not found", id)
	return DeviceV4{}
}

func TestGenesisShapeAndReinitRejected(t *testing.T) {
	s := mustOpen(t, testDir(t))
	info, e := s.Init()
	if e != nil || info.Revision != 1 || info.SHA256 == "" {
		t.Fatalf("init: info=%+v err=%v", info, e)
	}
	raw, e := os.ReadFile(filepath.Join(s.dir, "policy-000001.json"))
	if e != nil {
		t.Fatal(e)
	}
	if !bytes.HasSuffix(raw, []byte{'\n'}) {
		t.Fatal("genesis record missing trailing newline")
	}
	var rec PolicyRecord4
	if e := json.Unmarshal(raw, &rec); e != nil {
		t.Fatal(e)
	}
	if rec.Revision != 1 || rec.Previous != "" || rec.Policy.Version != DevicePolicyVersion || len(rec.Policy.Devices) != 0 {
		t.Fatalf("genesis record = %+v", rec)
	}
	if _, e = s.Init(); !errors.Is(e, ErrDevicePolicyConflict) {
		t.Fatalf("second init err = %v, want ErrDevicePolicyConflict", e)
	}
	// A foreign file makes the directory ambiguous: refuse to initialize.
	s2 := mustOpen(t, testDir(t))
	if e := os.WriteFile(filepath.Join(s2.dir, "keepme"), []byte("x"), 0600); e != nil {
		t.Fatal(e)
	}
	if _, e = s2.Init(); !errors.Is(e, ErrDevicePolicyConflict) {
		t.Fatalf("init with foreign file err = %v, want ErrDevicePolicyConflict", e)
	}
}

func TestCommitCASAndExactReplay(t *testing.T) {
	s, a1, _ := baseWithAlice(t)
	out1, e := s.Commit(1, set(a1))
	if e != nil || out1.Revision != 2 {
		t.Fatalf("first commit: info=%+v err=%v", out1, e)
	}
	// CAS: a stale expected revision is a conflict, and nothing is written.
	kx := newKey(t)
	if _, e = s.Commit(1, set(kx.device("dev-x", "xavier", "person-xavier", AcceptanceOutOfBand, StatusActive, 1, nil))); !errors.Is(e, ErrDevicePolicyConflict) {
		t.Fatalf("stale commit err = %v, want ErrDevicePolicyConflict", e)
	}
	if n := revisionCount(t, s.dir); n != 2 {
		t.Fatalf("revision files after conflict = %d, want 2", n)
	}
	// K4: an exact byte-equal replay of the immediately preceding outcome
	// returns the existing revision without writing.
	out2, e := s.Commit(1, set(a1))
	if e != nil || out2.Revision != 2 || out2.SHA256 != out1.SHA256 {
		t.Fatalf("replay: info=%+v err=%v", out2, e)
	}
	if n := revisionCount(t, s.dir); n != 2 {
		t.Fatalf("revision files after replay = %d, want 2", n)
	}
	// Once the chain advanced, replaying the older outcome is a conflict.
	if _, e = s.Commit(2, set(a1)); e != nil {
		t.Fatalf("advance to revision 3: %v", e)
	}
	if _, e = s.Commit(1, set(a1)); !errors.Is(e, ErrDevicePolicyConflict) {
		t.Fatalf("stale replay err = %v, want ErrDevicePolicyConflict", e)
	}
}

func TestTransitionViolationsRejected(t *testing.T) {
	cases := []struct {
		name string
		// next builds the candidate wire for the next commit and returns the
		// revision the commit should be attempted at (setup commits allowed).
		next func(t *testing.T, s *DevicePolicyStore, a1 DeviceV4, ka deviceKey) (PolicyWire4, uint64)
	}{
		{"immutable-subject", func(t *testing.T, s *DevicePolicyStore, a1 DeviceV4, ka deviceKey) (PolicyWire4, uint64) {
			a1.Subject = "person-other"
			return set(a1), 2
		}},
		{"immutable-key", func(t *testing.T, s *DevicePolicyStore, a1 DeviceV4, ka deviceKey) (PolicyWire4, uint64) {
			a1.SigningKey = newKey(t).hexKey
			return set(a1), 2
		}},
		{"deletion", func(t *testing.T, s *DevicePolicyStore, a1 DeviceV4, ka deviceKey) (PolicyWire4, uint64) {
			return set(), 2
		}},
		{"duplicate-id", func(t *testing.T, s *DevicePolicyStore, a1 DeviceV4, ka deviceKey) (PolicyWire4, uint64) {
			twin := newKey(t).device("dev-a1", "alice", "person-alice", AcceptanceOutOfBand, StatusActive, 1, nil)
			return set(a1, twin), 2
		}},
		{"duplicate-key", func(t *testing.T, s *DevicePolicyStore, a1 DeviceV4, ka deviceKey) (PolicyWire4, uint64) {
			twin := a1
			twin.ID = "dev-a1b"
			return set(a1, twin), 2
		}},
		{"fingerprint-mismatch", func(t *testing.T, s *DevicePolicyStore, a1 DeviceV4, ka deviceKey) (PolicyWire4, uint64) {
			a1.Fingerprint = strings.Repeat("0", 64)
			return set(a1), 2
		}},
		{"status-revision-pair", func(t *testing.T, s *DevicePolicyStore, a1 DeviceV4, ka deviceKey) (PolicyWire4, uint64) {
			a1.Revision = 2
			return set(a1), 2
		}},
		{"self-approval", func(t *testing.T, s *DevicePolicyStore, a1 DeviceV4, ka deviceKey) (PolicyWire4, uint64) {
			k2 := newKey(t)
			d := k2.device("dev-a2", "alice", "person-alice", AcceptanceTrusted, StatusActive, 1, &DeviceApproval{DeviceID: "dev-a2", Revision: 3})
			return set(a1, d), 2
		}},
		{"cross-actor-approver", func(t *testing.T, s *DevicePolicyStore, a1 DeviceV4, ka deviceKey) (PolicyWire4, uint64) {
			k2 := newKey(t)
			d := k2.device("dev-b1", "bob", "person-bob", AcceptanceTrusted, StatusActive, 1, &DeviceApproval{DeviceID: "dev-a1", Revision: 3})
			return set(a1, d), 2
		}},
		{"approver-revision-mismatch", func(t *testing.T, s *DevicePolicyStore, a1 DeviceV4, ka deviceKey) (PolicyWire4, uint64) {
			k2 := newKey(t)
			d := k2.device("dev-a2", "alice", "person-alice", AcceptanceTrusted, StatusActive, 1, &DeviceApproval{DeviceID: "dev-a1", Revision: 99})
			return set(a1, d), 2
		}},
		{"out-of-band-with-approved-by", func(t *testing.T, s *DevicePolicyStore, a1 DeviceV4, ka deviceKey) (PolicyWire4, uint64) {
			k2 := newKey(t)
			d := k2.device("dev-b1", "bob", "person-bob", AcceptanceOutOfBand, StatusActive, 1, &DeviceApproval{DeviceID: "dev-x", Revision: 3})
			return set(a1, d), 2
		}},
		{"enroll-first-with-active-device", func(t *testing.T, s *DevicePolicyStore, a1 DeviceV4, ka deviceKey) (PolicyWire4, uint64) {
			k2 := newKey(t)
			d := k2.device("dev-a2", "alice", "person-alice", AcceptanceOutOfBand, StatusActive, 1, nil)
			return set(a1, d), 2
		}},
		{"five-active-per-actor", func(t *testing.T, s *DevicePolicyStore, a1 DeviceV4, ka deviceKey) (PolicyWire4, uint64) {
			devices := []DeviceV4{a1}
			for i := 2; i <= 5; i++ {
				devices = append(devices, newKey(t).device(fmt.Sprintf("dev-a%d", i), "alice", "person-alice", AcceptanceOutOfBand, StatusActive, 1, nil))
			}
			return set(devices...), 2
		}},
		{"thirty-three-devices", func(t *testing.T, s *DevicePolicyStore, a1 DeviceV4, ka deviceKey) (PolicyWire4, uint64) {
			devices := []DeviceV4{a1}
			for i := 0; len(devices) < 33; i++ {
				actor := fmt.Sprintf("actor-%02d", i/4)
				devices = append(devices, newKey(t).device(fmt.Sprintf("dev-%02d", i), actor, "person-"+actor, AcceptanceOutOfBand, StatusActive, 1, nil))
			}
			return set(devices...), 2
		}},
		{"approved-by-tamper", func(t *testing.T, s *DevicePolicyStore, a1 DeviceV4, ka deviceKey) (PolicyWire4, uint64) {
			_, info := enrollApproved(t, s, 2, []DeviceV4{a1}, "dev-a2", "alice", "person-alice", ka)
			if info.Revision != 3 {
				t.Fatalf("setup revision = %d", info.Revision)
			}
			var next []DeviceV4
			for _, d := range readCurrent(t, s) {
				if d.ID == "dev-a2" {
					d.ApprovedBy = &DeviceApproval{DeviceID: "dev-a1", Revision: 4}
				}
				next = append(next, d)
			}
			return set(next...), 3
		}},
		{"reactivation", func(t *testing.T, s *DevicePolicyStore, a1 DeviceV4, ka deviceKey) (PolicyWire4, uint64) {
			tomb := a1
			tomb.Status = StatusRevoked
			tomb.Revision = 2
			if _, e := s.Commit(2, set(tomb)); e != nil {
				t.Fatal(e)
			}
			return set(a1), 3
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s, a1, ka := baseWithAlice(t)
			wire, expected := tc.next(t, s, a1, ka)
			before := revisionCount(t, s.dir)
			if _, e := s.Commit(expected, wire); e == nil {
				t.Fatal("invalid transition accepted")
			}
			if n := revisionCount(t, s.dir); n != before {
				t.Fatalf("revision files = %d, want %d (nothing written)", n, before)
			}
			if info := mustReadCurrent(t, s); info != expected {
				t.Fatalf("current revision = %d, want %d", info, expected)
			}
		})
	}
}

func mustReadCurrent(t *testing.T, s *DevicePolicyStore) uint64 {
	t.Helper()
	info, _ := mustRead(t, s)
	return info.Revision
}

func TestVerifyApprovalCases(t *testing.T) {
	_, a1, ka := baseWithAlice(t)
	kb := newKey(t)
	payload := ApprovalPayloadWire{
		Action:       ApprovalActionAdd,
		DeviceID:     "dev-a2",
		Actor:        "alice",
		Subject:      "person-alice",
		SigningKey:   kb.hexKey,
		Fingerprint:  kb.fp,
		Acceptance:   AcceptanceTrusted,
		BaseRevision: 2,
	}
	good := ka.sign(t, payload)
	if approver, e := VerifyApproval([]DeviceV4{a1}, ApprovalActionAdd, payload, ka.hexKey, good, 2); e != nil || approver != "dev-a1" {
		t.Fatalf("good approval: approver=%q err=%v", approver, e)
	}
	bad := []byte(good[:2]) // invalid hex (odd length)
	if _, e := VerifyApproval([]DeviceV4{a1}, ApprovalActionAdd, payload, ka.hexKey, string(bad), 2); e == nil {
		t.Fatal("malformed signature accepted")
	}
	tampered := good
	if tampered[len(tampered)-1] == 'a' {
		tampered = tampered[:len(tampered)-1] + "b"
	} else {
		tampered = tampered[:len(tampered)-1] + "a"
	}
	if _, e := VerifyApproval([]DeviceV4{a1}, ApprovalActionAdd, payload, ka.hexKey, tampered, 2); !errors.Is(e, ErrDevicePolicyApproval) {
		t.Fatalf("tampered signature err = %v", e)
	}
	if _, e := VerifyApproval([]DeviceV4{a1}, ApprovalActionAdd, payload, ka.hexKey, good, 999); e == nil {
		t.Fatal("wrong base revision accepted")
	}
	if _, e := VerifyApproval([]DeviceV4{a1}, ApprovalActionRevoke, payload, ka.hexKey, good, 2); e == nil {
		t.Fatal("action mismatch accepted")
	}
	if _, e := VerifyApproval([]DeviceV4{a1}, "audit", payload, ka.hexKey, good, 2); e == nil {
		t.Fatal("unknown action accepted")
	}
	// A key that is not an active device can never approve.
	kx := newKey(t)
	if _, e := VerifyApproval([]DeviceV4{a1}, ApprovalActionAdd, payload, kx.hexKey, kx.sign(t, payload), 2); e == nil {
		t.Fatal("unknown approver accepted")
	}
	// Self-approval: the approver's own device id is the payload target.
	candidate := kb.device("dev-a2", "alice", "person-alice", AcceptanceOutOfBand, StatusActive, 1, nil)
	if _, e := VerifyApproval([]DeviceV4{a1, candidate}, ApprovalActionAdd, payload, kb.hexKey, kb.sign(t, payload), 2); e == nil {
		t.Fatal("self-approval accepted")
	}
	// Cross-actor: alice's key signs, but the payload claims actor bob.
	cross := payload
	cross.Actor = "bob"
	if _, e := VerifyApproval([]DeviceV4{a1, kb.device("dev-b9", "bob", "person-bob", AcceptanceOutOfBand, StatusActive, 1, nil)}, ApprovalActionAdd, cross, ka.hexKey, ka.sign(t, cross), 2); e == nil {
		t.Fatal("cross-actor approval accepted")
	}
	// A revoked approver is not an approver.
	tomb := a1
	tomb.Status = StatusRevoked
	tomb.Revision = 2
	if _, e := VerifyApproval([]DeviceV4{tomb}, ApprovalActionAdd, payload, ka.hexKey, ka.sign(t, payload), 2); e == nil {
		t.Fatal("revoked approver accepted")
	}
}

func TestStrictDecodeRejections(t *testing.T) {
	s := mustOpen(t, testDir(t))
	if _, e := s.Init(); e != nil {
		t.Fatal(e)
	}
	raw, e := os.ReadFile(filepath.Join(s.dir, "policy-000001.json"))
	if e != nil {
		t.Fatal(e)
	}
	base := string(raw)
	if rec, e := parseDevicePolicyRecord(raw); e != nil || rec.Revision != 1 {
		t.Fatalf("genesis record rejected: rec=%+v err=%v", rec, e)
	}
	cases := map[string]string{
		"unknown-field":   strings.Replace(base, `{"revision":1,`, `{"revision":1,"extra":1,`, 1),
		"duplicate-field": strings.Replace(base, `{"revision":1,`, `{"revision":1,"revision":1,`, 1),
		"null-devices":    strings.Replace(base, `"devices":[]`, `"devices":null`, 1),
		"version-3":       strings.Replace(base, `"version":4`, `"version":3`, 1),
		"version-5":       strings.Replace(base, `"version":4`, `"version":5`, 1),
		"trailing-data":   base + "x",
		"empty":           "",
	}
	for name, doc := range cases {
		t.Run(name, func(t *testing.T) {
			if _, e := parseDevicePolicyRecord([]byte(doc)); e == nil {
				t.Fatal("malformed record accepted")
			}
		})
	}
}

func TestCorruptedChainFailClosed(t *testing.T) {
	s, a1, _ := baseWithAlice(t)
	rev2 := filepath.Join(s.dir, "policy-000002.json")
	raw, e := os.ReadFile(rev2)
	if e != nil {
		t.Fatal(e)
	}
	// Mutate the committed policy payload: the record's policy_sha256 no
	// longer matches, so every later reader must refuse the chain.
	tampered := bytes.Replace(raw, []byte(`"person-alice"`), []byte(`"person-mallory"`), 1)
	if bytes.Equal(tampered, raw) {
		t.Fatal("tamper had no effect")
	}
	if e := os.WriteFile(rev2, tampered, 0600); e != nil {
		t.Fatal(e)
	}
	if _, _, e := s.Read(); e == nil {
		t.Fatal("tampered chain accepted")
	}
	kx := newKey(t)
	if _, e = s.Commit(2, set(a1, kx.device("dev-x", "xavier", "person-xavier", AcceptanceOutOfBand, StatusActive, 1, nil))); e == nil {
		t.Fatal("commit on corrupted chain accepted")
	}
	if n := revisionCount(t, s.dir); n != 2 {
		t.Fatalf("revision files = %d, want 2 (fail-closed, nothing written)", n)
	}
	// Restoring the exact bytes restores a valid chain (state preserved).
	if e := os.WriteFile(rev2, raw, 0600); e != nil {
		t.Fatal(e)
	}
	if info := mustReadCurrent(t, s); info != 2 {
		t.Fatalf("current revision = %d, want 2", info)
	}
	// A forged next revision with a broken back-link is refused.
	forged, e := json.Marshal(PolicyRecord4{Revision: 3, Previous: strings.Repeat("0", 64), PolicySHA256: "", Policy: set()})
	if e != nil {
		t.Fatal(e)
	}
	if e := os.WriteFile(filepath.Join(s.dir, "policy-000003.json"), append(forged, '\n'), 0600); e != nil {
		t.Fatal(e)
	}
	if _, _, e := s.Read(); e == nil {
		t.Fatal("forged revision accepted")
	}
	if e := os.Remove(filepath.Join(s.dir, "policy-000003.json")); e != nil {
		t.Fatal(e)
	}
	// A revision file with nlink > 1 is refused. The link is created outside
	// the chain directory so the directory listing itself stays canonical.
	external := filepath.Join(t.TempDir(), "hardlink")
	if e := os.Link(rev2, external); e != nil {
		t.Fatal(e)
	}
	if _, _, e := s.Read(); e == nil {
		t.Fatal("hard-linked revision accepted")
	}
	if e := os.Remove(external); e != nil {
		t.Fatal(e)
	}
	if info := mustReadCurrent(t, s); info != 2 {
		t.Fatalf("current revision = %d, want 2", info)
	}
	// A symlinked revision name is refused (O_NOFOLLOW).
	if e := os.Symlink("policy-000002.json", filepath.Join(s.dir, "policy-000003.json")); e != nil {
		t.Fatal(e)
	}
	if _, _, e := s.Read(); e == nil {
		t.Fatal("symlinked revision accepted")
	}
	// A leftover pending file is a staging artifact of an interrupted
	// write, not chain corruption (G-M7): the committed chain reads as-is
	// and the file is retained for inspection.
	if e := os.Remove(filepath.Join(s.dir, "policy-000003.json")); e != nil {
		t.Fatal(e)
	}
	if info := mustReadCurrent(t, s); info != 2 {
		t.Fatalf("current revision = %d, want 2", info)
	}
	if e := os.WriteFile(filepath.Join(s.dir, "pending-abcd"), []byte("{}"), 0600); e != nil {
		t.Fatal(e)
	}
	if info := mustReadCurrent(t, s); info != 2 {
		t.Fatalf("current revision = %d with leftover pending file, want 2", info)
	}
	if _, e := os.Lstat(filepath.Join(s.dir, "pending-abcd")); e != nil {
		t.Fatal("read must retain the pending file for inspection:", e)
	}
	// The next commit must still land: the pending name cannot collide with
	// a revision name, and the tolerated staging file does not block writes.
	ky := newKey(t)
	if _, e := s.Commit(2, set(a1, ky.device("dev-y", "yuri", "person-yuri", AcceptanceOutOfBand, StatusActive, 1, nil))); e != nil {
		t.Fatal("commit with leftover pending file refused:", e)
	}
	if e := os.Remove(filepath.Join(s.dir, "pending-abcd")); e != nil {
		t.Fatal(e)
	}
	if info := mustReadCurrent(t, s); info != 3 {
		t.Fatalf("current revision = %d, want 3", info)
	}
}

func TestConcurrentCommitExactlyOneWins(t *testing.T) {
	s, a1, _ := baseWithAlice(t)
	const n = 8
	keys := make([]deviceKey, n)
	for i := range keys {
		keys[i] = newKey(t)
	}
	candidates := make([]DeviceV4, n)
	for i := range keys {
		candidates[i] = keys[i].device(fmt.Sprintf("dev-%02d", i), fmt.Sprintf("actor-%02d", i), fmt.Sprintf("person-%02d", i), AcceptanceOutOfBand, StatusActive, 1, nil)
	}
	results := make([]error, n)
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, results[i] = s.Commit(2, set(a1, candidates[i]))
		}(i)
	}
	wg.Wait()
	wins := 0
	for _, e := range results {
		if e == nil {
			wins++
			continue
		}
		if !errors.Is(e, ErrDevicePolicyConflict) {
			t.Fatalf("unexpected error: %v", e)
		}
	}
	if wins != 1 {
		t.Fatalf("wins = %d, want exactly 1", wins)
	}
	info, policy := mustRead(t, s)
	if info.Revision != 3 || len(policy.Devices) != 2 {
		t.Fatalf("final = revision %d with %d devices, want revision 3 with 2", info.Revision, len(policy.Devices))
	}
}

func TestReadCandidateKernel(t *testing.T) {
	dir := testDir(t)
	path := filepath.Join(dir, "candidate.json")
	if e := os.WriteFile(path, []byte("payload"), 0600); e != nil {
		t.Fatal(e)
	}
	if b, e := ReadCandidate(path); e != nil || string(b) != "payload" {
		t.Fatalf("read = %q err=%v", b, e)
	}
	if _, e := ReadCandidate("relative/candidate.json"); e == nil {
		t.Fatal("relative path accepted")
	}
	if _, e := ReadCandidate(filepath.Join(dir, "missing.json")); e == nil {
		t.Fatal("missing file accepted")
	}
	// Group-readable files are not private candidates.
	if e := os.Chmod(path, 0640); e != nil {
		t.Fatal(e)
	}
	if _, e := ReadCandidate(path); e == nil {
		t.Fatal("group-readable candidate accepted")
	}
	if e := os.Chmod(path, 0600); e != nil {
		t.Fatal(e)
	}
	// Symlinked candidates are refused.
	link := filepath.Join(dir, "link.json")
	if e := os.Symlink(path, link); e != nil {
		t.Fatal(e)
	}
	if _, e := ReadCandidate(link); e == nil {
		t.Fatal("symlinked candidate accepted")
	}
	// Hard links (nlink > 1) are refused.
	hard := filepath.Join(dir, "hard.json")
	if e := os.Link(path, hard); e != nil {
		t.Fatal(e)
	}
	if _, e := ReadCandidate(hard); e == nil {
		t.Fatal("hard-linked candidate accepted")
	}
}

func TestOpenStoreKernelGuards(t *testing.T) {
	dir := testDir(t)
	if _, e := OpenDevicePolicyStore("relative/dir"); e == nil {
		t.Fatal("relative store directory accepted")
	}
	if _, e := OpenDevicePolicyStore(filepath.Join(dir, "missing")); e == nil {
		t.Fatal("missing store directory accepted")
	}
	file := filepath.Join(dir, "notadir")
	if e := os.WriteFile(file, []byte("x"), 0600); e != nil {
		t.Fatal(e)
	}
	if _, e := OpenDevicePolicyStore(file); e == nil {
		t.Fatal("file as store directory accepted")
	}
	// A writable-parent directory (0775) is refused even though it exists.
	loose := filepath.Join(dir, "loose")
	if e := os.Mkdir(loose, 0775); e != nil {
		t.Fatal(e)
	}
	if e := os.Chmod(loose, 0775); e != nil {
		t.Fatal(e)
	}
	if _, e := OpenDevicePolicyStore(loose); e == nil {
		t.Fatal("loose store directory accepted")
	}
}

// G-M7 separation, pinned by test: a leftover pending- file is staging
// debris on top of a committed chain (reads ignore it), while a chain that
// never got its first revision (interrupted genesis write) still fails
// closed, and a flood of staging files is corruption, not patience.
func TestLeftoverPendingVersusUnchainedDirectory(t *testing.T) {
	// Established chain + one leftover pending file: read succeeds.
	s, _, _ := baseWithAlice(t)
	if e := os.WriteFile(filepath.Join(s.dir, "pending-deadbeef"), []byte("{}"), 0600); e != nil {
		t.Fatal(e)
	}
	if info := mustReadCurrent(t, s); info != 2 {
		t.Fatalf("current revision = %d with leftover pending file, want 2", info)
	}
	// Never-initialized directory: an interrupted very first write leaves
	// pending debris but no committed revision — still fail closed (the
	// read refuses the revision-0 chain).
	empty := mustOpen(t, testDir(t))
	if e := os.WriteFile(filepath.Join(empty.dir, "pending-deadbeef"), []byte("{}"), 0600); e != nil {
		t.Fatal(e)
	}
	if _, _, e := empty.Read(); e == nil {
		t.Fatal("unchained directory with pending file accepted")
	}
	// More than MaxPendingPolicyFiles staging files is the corruption signal.
	flooded := testDir(t)
	for i := 0; i <= MaxPendingPolicyFiles; i++ {
		name := filepath.Join(flooded, fmt.Sprintf("pending-%02d", i))
		if e := os.WriteFile(name, []byte("{}"), 0600); e != nil {
			t.Fatal(e)
		}
	}
	fs, e := OpenDevicePolicyStore(flooded)
	if e != nil {
		t.Fatal(e)
	}
	if _, _, e := fs.Read(); e == nil {
		t.Fatal("pending flood accepted")
	}
}

// G-M7: the ≤2s flock wait must not pin the in-process mutex — a manager
// holding the lock delays reads, but must not serialize every other caller
// of the store behind the waiter.
func TestLockedWaitDoesNotHoldMutex(t *testing.T) {
	s, _, _ := baseWithAlice(t)
	lock, e := os.OpenFile(filepath.Join(s.dir, "lock"), os.O_RDWR, 0600)
	if e != nil {
		t.Fatal(e)
	}
	defer lock.Close()
	if e := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); e != nil {
		t.Fatal(e)
	}
	done := make(chan error, 1)
	go func() {
		_, _, e := s.Read()
		done <- e
	}()
	// Give the reader time to enter locked() and start polling for the
	// flock (10ms poll): with the mutex held across the wait (the old
	// behaviour) this TryLock cannot succeed for the whole 2s window.
	time.Sleep(100 * time.Millisecond)
	acquired := false
	if s.mu.TryLock() {
		acquired = true
		s.mu.Unlock()
	}
	if !acquired {
		t.Fatal("s.mu held across the flock wait")
	}
	if e := syscall.Flock(int(lock.Fd()), syscall.LOCK_UN); e != nil {
		t.Fatal(e)
	}
	if e := <-done; e != nil {
		t.Fatalf("read after the lock freed: %v", e)
	}
}

// IsSubject is deliberately wider than the identifier charset — it must carry
// the CF Access `sub` and the service-token `common_name` (`<id>.access`,
// email-shaped subs) — but the review-2 hygiene classes stay out. Pinned here
// so the chain validator's widening can never silently become a free-form
// string field.
func TestIsSubjectCharset(t *testing.T) {
	good := []string{
		"subject-alice",           // the classic sub shape
		"97f3e1c2ab5548f0.access", // service-token common_name (the Client-Id)
		"family-bot@chat.example", // an email-shaped sub
		"a",                       // a single character
		strings.Repeat("x", 128),  // at the cap
	}
	for _, s := range good {
		if !IsSubject(s, 128) {
			t.Errorf("IsSubject(%q) = false, want true", s)
		}
	}
	bad := []string{
		"",                       // empty
		strings.Repeat("x", 129), // over the cap
		"subject alice",          // whitespace
		"subject\talice",         // tab
		"subject\nalice",         // newline
		"sub=alice",              // '=' — a log-injection metacharacter
		"sub/alice",              // a path metacharacter
		"sub:alice",              // ':' — header-shaped
		"サブジェクト",                 // non-ASCII
	}
	for _, s := range bad {
		if IsSubject(s, 128) {
			t.Errorf("IsSubject(%q) = true, want false", s)
		}
	}
	if IsSubject("subject-alice", 12) {
		t.Error("IsSubject must honor the caller's cap")
	}
}
