package main

import (
	"bytes"
	"crypto/ed25519"
	crand "crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/jinwon-int/family-messenger/archive/native-mls/server/internal/devicepolicy"
)

type cliKey struct {
	priv   ed25519.PrivateKey
	hexKey string
	fp     string
}

func newCLIKey(t *testing.T) cliKey {
	t.Helper()
	pub, priv, e := ed25519.GenerateKey(crand.Reader)
	if e != nil {
		t.Fatal(e)
	}
	sum := sha256.Sum256(pub)
	return cliKey{priv: priv, hexKey: hex.EncodeToString(pub), fp: hex.EncodeToString(sum[:])}
}

func cliDir(t *testing.T) string {
	t.Helper()
	d := t.TempDir()
	if e := os.Chmod(d, 0700); e != nil {
		t.Fatal(e)
	}
	return d
}

func cliCandidate(t *testing.T, dir, name string, payload any) string {
	t.Helper()
	b, e := json.Marshal(payload)
	if e != nil {
		t.Fatal(e)
	}
	p := filepath.Join(dir, name)
	if e := os.WriteFile(p, b, 0600); e != nil {
		t.Fatal(e)
	}
	return p
}

// runOK executes the CLI expecting success and returns the printed state view.
func runOK(t *testing.T, args ...string) stateView {
	t.Helper()
	var out bytes.Buffer
	if e := run(args, &out); e != nil {
		t.Fatalf("run(%v): %v", args, e)
	}
	var v stateView
	if e := json.Unmarshal(out.Bytes(), &v); e != nil {
		t.Fatalf("output %q: %v", out.String(), e)
	}
	return v
}

func runErr(t *testing.T, args ...string) string {
	t.Helper()
	var out bytes.Buffer
	e := run(args, &out)
	if e == nil {
		t.Fatalf("run(%v) unexpectedly succeeded", args)
	}
	return e.Error()
}

func signFor(t *testing.T, k cliKey, payload devicepolicy.ApprovalPayloadWire) string {
	t.Helper()
	msg, e := devicepolicy.ApprovalMessage(payload)
	if e != nil {
		t.Fatal(e)
	}
	return hex.EncodeToString(ed25519.Sign(k.priv, msg))
}

// TestCLIEndToEnd drives the five owner operations through run() exactly as an
// operator would, including the negative space in between.
func TestCLIEndToEnd(t *testing.T) {
	dir := cliDir(t)
	state := filepath.Join(dir, "policy")
	var output bytes.Buffer
	capture := func(args ...string) stateView {
		var out bytes.Buffer
		if e := run(append([]string{"-device-state", state}, args...), &out); e != nil {
			t.Fatalf("run(%v): %v", args, e)
		}
		output.Write(out.Bytes())
		var v stateView
		if e := json.Unmarshal(out.Bytes(), &v); e != nil {
			t.Fatalf("output %q: %v", out.String(), e)
		}
		return v
	}
	mustFail := func(want string, args ...string) {
		t.Helper()
		e := run(append([]string{"-device-state", state}, args...), &bytes.Buffer{})
		if e == nil || !strings.Contains(e.Error(), want) {
			t.Fatalf("run(%v) err = %v, want containing %q", args, e, want)
		}
	}

	ka := newCLIKey(t) // dev-a1
	kb := newCLIKey(t) // dev-a2
	kc := newCLIKey(t) // dev-b2
	kd := newCLIKey(t) // dev-b1
	ke := newCLIKey(t) // dev-a3
	cand := cliDir(t)
	var write string

	// Genesis.
	v := capture("-init")
	if v.Revision != 1 {
		t.Fatalf("init revision = %d", v.Revision)
	}
	// E1: alice's first device, out of band.
	write = cliCandidate(t, cand, "a1.json", enrollCandidate{DeviceID: "dev-a1", Actor: "alice", Subject: "person-alice", SigningKey: ka.hexKey})
	v = capture("-enroll-first", "-input", write, "-expected-revision", "1")
	if v.Revision != 2 || len(v.Devices) != 1 || v.Devices[0].Fingerprint != ka.fp {
		t.Fatalf("E1 view = %+v", v)
	}
	// E2 with a stale base revision is refused before anything is written.
	write = cliCandidate(t, cand, "stale.json", addDeviceCandidate{DeviceID: "dev-a2", Actor: "alice", Subject: "person-alice", SigningKey: kb.hexKey, BaseRevision: 99})
	mustFail("does not bind the current revision", "-add-device", "-input", write, "-expected-revision", "2")
	// E2 self-signed is refused: no active same-actor device verifies it.
	write = cliCandidate(t, cand, "self.json", addDeviceCandidate{DeviceID: "dev-a2", Actor: "alice", Subject: "person-alice", SigningKey: kb.hexKey, BaseRevision: 2, Signature: signFor(t, kb, devicepolicy.ApprovalPayloadWire{Action: devicepolicy.ApprovalActionAdd, DeviceID: "dev-a2", Actor: "alice", Subject: "person-alice", SigningKey: kb.hexKey, Fingerprint: kb.fp, Acceptance: devicepolicy.AcceptanceTrusted, BaseRevision: 2})})
	mustFail("no active", "-add-device", "-input", write, "-expected-revision", "2")
	// E2 properly approved by dev-a1.
	write = cliCandidate(t, cand, "a2.json", addDeviceCandidate{DeviceID: "dev-a2", Actor: "alice", Subject: "person-alice", SigningKey: kb.hexKey, BaseRevision: 2, Signature: signFor(t, ka, devicepolicy.ApprovalPayloadWire{Action: devicepolicy.ApprovalActionAdd, DeviceID: "dev-a2", Actor: "alice", Subject: "person-alice", SigningKey: kb.hexKey, Fingerprint: kb.fp, Acceptance: devicepolicy.AcceptanceTrusted, BaseRevision: 2})})
	v = capture("-add-device", "-input", write, "-expected-revision", "2")
	if v.Revision != 3 {
		t.Fatalf("E2 revision = %d", v.Revision)
	}
	// E3 with device-signed evidence: dev-a1 is out-of-band, so its tombstone
	// carries the revocation approval of dev-a2 (written once).
	write = cliCandidate(t, cand, "revoke-a1.json", revokeEvidence{Action: devicepolicy.ApprovalActionRevoke, DeviceID: "dev-a1", BaseRevision: 3, Signature: signFor(t, kb, devicepolicy.ApprovalPayloadWire{Action: devicepolicy.ApprovalActionRevoke, DeviceID: "dev-a1", Actor: "alice", Subject: "person-alice", SigningKey: ka.hexKey, Fingerprint: ka.fp, Acceptance: devicepolicy.AcceptanceOutOfBand, BaseRevision: 3})})
	v = capture("-revoke", "dev-a1", "-input", write, "-expected-revision", "3")
	if v.Revision != 4 {
		t.Fatalf("E3 revision = %d", v.Revision)
	}
	for _, d := range v.Devices {
		if d.DeviceID != "dev-a1" {
			continue
		}
		if d.Status != devicepolicy.StatusRevoked || d.ApprovedBy == nil || d.ApprovedBy.DeviceID != "dev-a2" || d.ApprovedBy.Revision != 4 {
			t.Fatalf("dev-a1 tombstone = %+v", d)
		}
	}
	// E3 without evidence on a trusted-enrolled device keeps its enrollment
	// evidence and revokes plainly.
	v = capture("-revoke", "dev-a2", "-expected-revision", "4")
	if v.Revision != 5 {
		t.Fatalf("plain revoke revision = %d", v.Revision)
	}
	// E1 again for bob, E2 for bob's second device.
	write = cliCandidate(t, cand, "b1.json", enrollCandidate{DeviceID: "dev-b1", Actor: "bob", Subject: "person-bob", SigningKey: kd.hexKey})
	if v = capture("-enroll-first", "-input", write, "-expected-revision", "5"); v.Revision != 6 {
		t.Fatalf("bob E1 revision = %d", v.Revision)
	}
	write = cliCandidate(t, cand, "b2.json", addDeviceCandidate{DeviceID: "dev-b2", Actor: "bob", Subject: "person-bob", SigningKey: kc.hexKey, BaseRevision: 6, Signature: signFor(t, kd, devicepolicy.ApprovalPayloadWire{Action: devicepolicy.ApprovalActionAdd, DeviceID: "dev-b2", Actor: "bob", Subject: "person-bob", SigningKey: kc.hexKey, Fingerprint: kc.fp, Acceptance: devicepolicy.AcceptanceTrusted, BaseRevision: 6})})
	if v = capture("-add-device", "-input", write, "-expected-revision", "6"); v.Revision != 7 {
		t.Fatalf("bob E2 revision = %d", v.Revision)
	}
	// E4: total device loss for bob.
	if v = capture("-revoke-all", "bob", "-expected-revision", "7"); v.Revision != 8 {
		t.Fatalf("bob E4 revision = %d", v.Revision)
	}
	for _, d := range v.Devices {
		if d.Actor == "bob" && d.Status != devicepolicy.StatusRevoked {
			t.Fatalf("bob device not revoked: %+v", d)
		}
	}
	// After total loss the actor re-enrolls through E1 (out of band again).
	write = cliCandidate(t, cand, "a3.json", enrollCandidate{DeviceID: "dev-a3", Actor: "alice", Subject: "person-alice", SigningKey: ke.hexKey})
	if v = capture("-enroll-first", "-input", write, "-expected-revision", "8"); v.Revision != 9 {
		t.Fatalf("re-enroll revision = %d", v.Revision)
	}
	// A stale CAS revision is refused with the current revision named.
	mustFail("current revision is 9", "-revoke-all", "alice", "-expected-revision", "3")
	// E4 for alice.
	if v = capture("-revoke-all", "alice", "-expected-revision", "9"); v.Revision != 10 {
		t.Fatalf("alice E4 revision = %d", v.Revision)
	}
	// Inspect reports the full tombstone set; signing keys never leave the
	// policy file through this CLI.
	v = capture("-inspect")
	if v.Revision != 10 || len(v.Devices) != 5 {
		t.Fatalf("inspect = revision %d with %d devices", v.Revision, len(v.Devices))
	}
	if strings.Contains(output.String(), ka.hexKey) || strings.Contains(output.String(), kb.hexKey) || strings.Contains(output.String(), kd.hexKey) || strings.Contains(output.String(), ke.hexKey) {
		t.Fatal("signing key material printed")
	}

	// Argument surface.
	mustFail("exactly one", "-device-state", state)
	mustFail("absolute", "-device-state", "relative/path", "-inspect")
	mustFail("-input applies only", "-device-state", state, "-inspect", "-input", cand)
	mustFail("mutations require", "-device-state", state, "-revoke-all", "alice")
	mustFail("-expected-revision applies only", "-device-state", state, "-inspect", "-expected-revision", "1")
	mustFail("unexpected positional", "-device-state", state, "-init", "extra")
	// Wrong-mode inputs.
	mustFail("requires -input", "-device-state", state, "-enroll-first", "-expected-revision", "10")
	mustFail("already revoked", "-device-state", state, "-revoke", "dev-a1", "-expected-revision", "10")
	mustFail("not in the policy", "-device-state", state, "-revoke", "dev-zzz", "-expected-revision", "10")
	mustFail("no active devices", "-device-state", state, "-revoke-all", "carol", "-expected-revision", "10")
	// Malformed candidate JSON (unknown field) is refused.
	write = cliCandidate(t, cand, "bad.json", map[string]any{"device_id": "dev-x", "actor": "carol", "subject": "person-carol", "signing_key": kc.hexKey, "surprise": 1})
	mustFail("candidate JSON", "-device-state", state, "-enroll-first", "-input", write, "-expected-revision", "10")
}
