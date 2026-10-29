package main

import (
	"crypto/ed25519"
	"encoding/hex"
	"path/filepath"
	"strings"
	"testing"

	"github.com/jinwon-int/family-messenger/archive/native-mls/server/internal/devicepolicy"
)

func signRolesFor(t *testing.T, k cliKey, payload devicepolicy.RolesPayloadWire) string {
	t.Helper()
	msg, e := devicepolicy.RolesMessage(payload)
	if e != nil {
		t.Fatal(e)
	}
	return hex.EncodeToString(ed25519.Sign(k.priv, msg))
}

func rolesOfView(v stateView, id string) []string {
	for _, d := range v.Devices {
		if d.DeviceID == id {
			return d.Roles
		}
	}
	return nil
}

// TestCLISetRoles drives E5 through run(): E1 makes the first device a
// registrar; a non-registrar's E2 signature is refused once one exists; the
// registrar hands the role over with signed evidence; the operator restores a
// registrar out-of-band after every registrar is revoked.
func TestCLISetRoles(t *testing.T) {
	dir := cliDir(t)
	state := filepath.Join(dir, "policy")
	cand := cliDir(t)
	runOK(t, "-device-state", state, "-init")
	ka, kb, kc := newCLIKey(t), newCLIKey(t), newCLIKey(t)

	v := runOK(t, "-device-state", state, "-enroll-first", "-expected-revision", "1",
		"-input", cliCandidate(t, cand, "a1.json", enrollCandidate{DeviceID: "dev-a1", Actor: "alice", Subject: "person-alice", SigningKey: ka.hexKey}))
	if r := rolesOfView(v, "dev-a1"); len(r) != 1 || r[0] != devicepolicy.RoleRegistrar {
		t.Fatalf("E1 roles = %v, want registrar", r)
	}
	// a1 (registrar) enrolls a2.
	a2 := addDeviceCandidate{DeviceID: "dev-a2", Actor: "alice", Subject: "person-alice", SigningKey: kb.hexKey, BaseRevision: 2,
		Signature: signFor(t, ka, devicepolicy.ApprovalPayloadWire{Action: devicepolicy.ApprovalActionAdd, DeviceID: "dev-a2", Actor: "alice", Subject: "person-alice", SigningKey: kb.hexKey, Fingerprint: kb.fp, Acceptance: devicepolicy.AcceptanceTrusted, BaseRevision: 2})}
	v = runOK(t, "-device-state", state, "-add-device", "-expected-revision", "2", "-input", cliCandidate(t, cand, "a2.json", a2))
	if v.Revision != 3 || rolesOfView(v, "dev-a2") != nil {
		t.Fatalf("E2 view: %+v", v)
	}
	// a2 (not a registrar) cannot enroll a3.
	a3bad := addDeviceCandidate{DeviceID: "dev-a3", Actor: "alice", Subject: "person-alice", SigningKey: kc.hexKey, BaseRevision: 3,
		Signature: signFor(t, kb, devicepolicy.ApprovalPayloadWire{Action: devicepolicy.ApprovalActionAdd, DeviceID: "dev-a3", Actor: "alice", Subject: "person-alice", SigningKey: kc.hexKey, Fingerprint: kc.fp, Acceptance: devicepolicy.AcceptanceTrusted, BaseRevision: 3})}
	if msg := runErr(t, "-device-state", state, "-add-device", "-expected-revision", "3", "-input", cliCandidate(t, cand, "a3bad.json", a3bad)); !strings.Contains(msg, "registrar") {
		t.Fatalf("non-registrar E2 error = %q", msg)
	}

	// Flag hygiene.
	if msg := runErr(t, "-device-state", state, "-set-roles", "dev-a2", "-expected-revision", "3"); !strings.Contains(msg, "-roles and -set-roles") {
		t.Fatalf("missing -roles: %q", msg)
	}
	if msg := runErr(t, "-device-state", state, "-set-roles", "dev-a2", "-roles", "owner", "-expected-revision", "3"); !strings.Contains(msg, "-roles must be") {
		t.Fatalf("bad -roles: %q", msg)
	}
	// Signed hand-over: a1 grants a2 (evidence names a2 + registrar).
	grant := rolesCandidate{DeviceID: "dev-a2", Actor: "alice", Roles: []string{devicepolicy.RoleRegistrar}, BaseRevision: 3,
		Signature: signRolesFor(t, ka, devicepolicy.RolesPayloadWire{Action: devicepolicy.ApprovalActionRoles, DeviceID: "dev-a2", Actor: "alice", Roles: []string{devicepolicy.RoleRegistrar}, BaseRevision: 3})}
	// Evidence/flag mismatch is refused before any signature check.
	if msg := runErr(t, "-device-state", state, "-set-roles", "dev-a1", "-roles", "registrar", "-expected-revision", "3", "-input", cliCandidate(t, cand, "grant.json", grant)); !strings.Contains(msg, "binds device") {
		t.Fatalf("mismatched device: %q", msg)
	}
	if msg := runErr(t, "-device-state", state, "-set-roles", "dev-a2", "-roles", "none", "-expected-revision", "3", "-input", cliCandidate(t, cand, "grant2.json", grant)); !strings.Contains(msg, "do not match -roles") {
		t.Fatalf("mismatched roles: %q", msg)
	}
	v = runOK(t, "-device-state", state, "-set-roles", "dev-a2", "-roles", "registrar", "-expected-revision", "3", "-input", cliCandidate(t, cand, "grant3.json", grant))
	if v.Revision != 4 || len(rolesOfView(v, "dev-a2")) != 1 {
		t.Fatalf("grant view: %+v", v)
	}
	// a1 steps down (signed by itself, a2 remains).
	down := rolesCandidate{DeviceID: "dev-a1", Actor: "alice", Roles: []string{}, BaseRevision: 4,
		Signature: signRolesFor(t, ka, devicepolicy.RolesPayloadWire{Action: devicepolicy.ApprovalActionRoles, DeviceID: "dev-a1", Actor: "alice", Roles: []string{}, BaseRevision: 4})}
	v = runOK(t, "-device-state", state, "-set-roles", "dev-a1", "-roles", "none", "-expected-revision", "4", "-input", cliCandidate(t, cand, "down.json", down))
	if v.Revision != 5 || rolesOfView(v, "dev-a1") != nil || len(rolesOfView(v, "dev-a2")) != 1 {
		t.Fatalf("step-down view: %+v", v)
	}
	// Now a1's E2 signature is refused, a2's enrolls a3.
	if msg := runErr(t, "-device-state", state, "-add-device", "-expected-revision", "5", "-input", cliCandidate(t, cand, "a3byA1.json", addDeviceCandidate{DeviceID: "dev-a3", Actor: "alice", Subject: "person-alice", SigningKey: kc.hexKey, BaseRevision: 5,
		Signature: signFor(t, ka, devicepolicy.ApprovalPayloadWire{Action: devicepolicy.ApprovalActionAdd, DeviceID: "dev-a3", Actor: "alice", Subject: "person-alice", SigningKey: kc.hexKey, Fingerprint: kc.fp, Acceptance: devicepolicy.AcceptanceTrusted, BaseRevision: 5})})); !strings.Contains(msg, "registrar") {
		t.Fatalf("former registrar E2 error = %q", msg)
	}
	v = runOK(t, "-device-state", state, "-add-device", "-expected-revision", "5", "-input", cliCandidate(t, cand, "a3.json", addDeviceCandidate{DeviceID: "dev-a3", Actor: "alice", Subject: "person-alice", SigningKey: kc.hexKey, BaseRevision: 5,
		Signature: signFor(t, kb, devicepolicy.ApprovalPayloadWire{Action: devicepolicy.ApprovalActionAdd, DeviceID: "dev-a3", Actor: "alice", Subject: "person-alice", SigningKey: kc.hexKey, Fingerprint: kc.fp, Acceptance: devicepolicy.AcceptanceTrusted, BaseRevision: 5})}))
	if v.Revision != 6 {
		t.Fatalf("E2 by a2: %+v", v)
	}
	// Revoke the only registrar: roles vanish from the tombstone; the actor
	// is registrar-less and the operator restores one out-of-band.
	v = runOK(t, "-device-state", state, "-revoke", "dev-a2", "-expected-revision", "6")
	if r := rolesOfView(v, "dev-a2"); r != nil {
		t.Fatalf("tombstone roles = %v", r)
	}
	if msg := runErr(t, "-device-state", state, "-set-roles", "dev-a2", "-roles", "registrar", "-expected-revision", "7"); !strings.Contains(msg, "revoked") {
		t.Fatalf("roles on tombstone: %q", msg)
	}
	v = runOK(t, "-device-state", state, "-set-roles", "dev-a3", "-roles", "registrar", "-expected-revision", "7")
	if v.Revision != 8 || len(rolesOfView(v, "dev-a3")) != 1 {
		t.Fatalf("operator recovery view: %+v", v)
	}
	// -inspect shows roles and still no keys.
	v = runOK(t, "-device-state", state, "-inspect")
	if v.Revision != 8 || len(rolesOfView(v, "dev-a3")) != 1 {
		t.Fatalf("inspect: %+v", v)
	}
}
