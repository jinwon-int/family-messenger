package devicepolicy

import (
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

func (k deviceKey) signRoles(t *testing.T, payload RolesPayloadWire) string {
	t.Helper()
	msg, e := RolesMessage(payload)
	if e != nil {
		t.Fatal(e)
	}
	return hex.EncodeToString(ed25519.Sign(k.priv, msg))
}

func rolesEvidence(t *testing.T, signer deviceKey, id, actor string, roles []string, base uint64) RolesEvidence {
	t.Helper()
	canonical, e := CanonicalRoles(roles)
	if e != nil {
		t.Fatal(e)
	}
	return RolesEvidence{DeviceID: id, Actor: actor, Roles: roles, BaseRevision: base,
		Signature: signer.signRoles(t, RolesPayloadWire{Action: ApprovalActionRoles, DeviceID: id, Actor: actor, Roles: canonical, BaseRevision: base})}
}

func addEvidence(t *testing.T, signer, candidate deviceKey, id, actor, subject string, base uint64) AddDeviceEvidence {
	t.Helper()
	payload := ApprovalPayloadWire{Action: ApprovalActionAdd, DeviceID: id, Actor: actor, Subject: subject,
		SigningKey: candidate.hexKey, Fingerprint: candidate.fp, Acceptance: AcceptanceTrusted, BaseRevision: base}
	return AddDeviceEvidence{DeviceID: id, Actor: actor, Subject: subject, SigningKey: candidate.hexKey, BaseRevision: base, Signature: signer.sign(t, payload)}
}

func rolesOf(t *testing.T, devices []DeviceV4, id string) []string {
	t.Helper()
	i, ok := FindByID(devices, id)
	if !ok {
		t.Fatalf("device %q missing", id)
	}
	return devices[i].Roles
}

// TestRegistrarLifecycle walks #574 D2 end to end on a pre-#574 actor:
// legacy approval while nobody is a registrar, bootstrap with one E5, the
// registrar-only E2 rule, handing the role over, and the last-registrar guard.
func TestRegistrarLifecycle(t *testing.T) {
	s, a1, ka := baseWithAlice(t) // revision 2: dev-a1 active, no roles (legacy)
	devices := []DeviceV4{a1}
	if HasRegistrar(devices, "alice") {
		t.Fatal("legacy actor must have no registrar")
	}

	// Legacy rule: any active device (a1) enrolls a2 while alice has no registrar.
	kb := newKey(t)
	next, approver, e := ApplyAddDevice(devices, addEvidence(t, ka, kb, "dev-a2", "alice", "person-alice", 2), 2)
	if e != nil || approver != "dev-a1" {
		t.Fatalf("legacy add: approver=%q err=%v", approver, e)
	}
	if _, e := s.Commit(2, set(next...)); e != nil {
		t.Fatal(e)
	}
	devices = next // revision 3

	// Bootstrap: a2 (not a registrar — nobody is) makes itself the registrar.
	next, approver, e = ApplySetRoles(devices, rolesEvidence(t, kb, "dev-a2", "alice", []string{RoleRegistrar}, 3), 3)
	if e != nil || approver != "dev-a2" {
		t.Fatalf("bootstrap: approver=%q err=%v", approver, e)
	}
	if _, e := s.Commit(3, set(next...)); e != nil {
		t.Fatal(e)
	}
	devices = next // revision 4
	if !HasRegistrar(devices, "alice") || !IsRegistrar(devices[1]) {
		t.Fatalf("after bootstrap roles = %v", rolesOf(t, devices, "dev-a2"))
	}

	// Registrar-only E2: a1 (no role) can no longer enroll; a2 can.
	kc := newKey(t)
	if _, _, e := ApplyAddDevice(devices, addEvidence(t, ka, kc, "dev-a3", "alice", "person-alice", 4), 4); !errors.Is(e, ErrDevicePolicyApproval) || !strings.Contains(e.Error(), "registrar") {
		t.Fatalf("non-registrar E2 accepted or wrong error: %v", e)
	}
	next, approver, e = ApplyAddDevice(devices, addEvidence(t, kb, kc, "dev-a3", "alice", "person-alice", 4), 4)
	if e != nil || approver != "dev-a2" {
		t.Fatalf("registrar E2: approver=%q err=%v", approver, e)
	}
	if _, e := s.Commit(4, set(next...)); e != nil {
		t.Fatal(e)
	}
	devices = next // revision 5; a3 has no roles

	// Only a registrar moves the role: a1 cannot grant itself, a3 cannot grant a1.
	for _, bad := range []RolesEvidence{
		rolesEvidence(t, ka, "dev-a1", "alice", []string{RoleRegistrar}, 5),
		rolesEvidence(t, kc, "dev-a1", "alice", []string{RoleRegistrar}, 5),
	} {
		if _, _, e := ApplySetRoles(devices, bad, 5); !errors.Is(e, ErrDevicePolicyApproval) || !strings.Contains(e.Error(), "registrar") {
			t.Fatalf("non-registrar E5 accepted or wrong error: %v", e)
		}
	}
	// The last registrar cannot release itself.
	if _, _, e := ApplySetRoles(devices, rolesEvidence(t, kb, "dev-a2", "alice", nil, 5), 5); !errors.Is(e, ErrDevicePolicyApproval) || !strings.Contains(e.Error(), "without a registrar") {
		t.Fatalf("last registrar released itself: %v", e)
	}
	// Hand-over: a2 grants a3, then a2 steps down.
	next, _, e = ApplySetRoles(devices, rolesEvidence(t, kb, "dev-a3", "alice", []string{RoleRegistrar}, 5), 5)
	if e != nil {
		t.Fatal(e)
	}
	if _, e := s.Commit(5, set(next...)); e != nil {
		t.Fatal(e)
	}
	devices = next // revision 6
	next, approver, e = ApplySetRoles(devices, rolesEvidence(t, kb, "dev-a2", "alice", []string{}, 6), 6)
	if e != nil || approver != "dev-a2" {
		t.Fatalf("step down: approver=%q err=%v", approver, e)
	}
	if _, e := s.Commit(6, set(next...)); e != nil {
		t.Fatal(e)
	}
	devices = next // revision 7
	if IsRegistrar(devices[1]) || !IsRegistrar(devices[2]) {
		t.Fatalf("hand-over roles: a2=%v a3=%v", devices[1].Roles, devices[2].Roles)
	}
	// Now a2's E2 signature is refused and a3's accepted.
	kd := newKey(t)
	if _, _, e := ApplyAddDevice(devices, addEvidence(t, kb, kd, "dev-a4", "alice", "person-alice", 7), 7); e == nil {
		t.Fatal("former registrar still enrolls devices")
	}
	if _, _, e := ApplyAddDevice(devices, addEvidence(t, kc, kd, "dev-a4", "alice", "person-alice", 7), 7); e != nil {
		t.Fatalf("new registrar E2: %v", e)
	}

	// Stale base_revision is a conflict (re-sign), not an approval failure.
	if _, _, e := ApplySetRoles(devices, rolesEvidence(t, kc, "dev-a1", "alice", []string{RoleRegistrar}, 6), 7); !errors.Is(e, ErrDevicePolicyConflict) {
		t.Fatalf("stale roles evidence: %v", e)
	}
	// Revoking the registrar clears its role on the tombstone and the chain
	// accepts it (the actor is then registrar-less: operator recovery).
	rev := cloneDevices(devices)
	Tombstone(&rev[2])
	info, e := s.Commit(7, set(rev...))
	if e != nil || info.Revision != 8 {
		t.Fatalf("revoke registrar: %v", e)
	}
	if HasRegistrar(rev, "alice") {
		t.Fatal("revoked registrar still counts")
	}
	// Operator recovery restores one without evidence.
	rec, e := SetRoles(rev, "dev-a1", []string{RoleRegistrar, RoleRegistrar})
	if e != nil || !IsRegistrar(rec[0]) {
		t.Fatalf("operator set-roles: %v", e)
	}
	if _, e := s.Commit(8, set(rec...)); e != nil {
		t.Fatal(e)
	}
	// Replaying the whole chain (9 revisions, roles written and cleared)
	// validates.
	finfo, fpol := mustRead(t, s)
	if finfo.Revision != 9 || !IsRegistrar(fpol.Devices[0]) || fpol.Devices[2].Status != StatusRevoked || len(fpol.Devices[2].Roles) != 0 {
		t.Fatalf("replayed state: rev=%d devices=%+v", finfo.Revision, fpol.Devices)
	}
}

// The Rust facade (archive/experiments/openmls-browser/src/tests_v2.rs,
// roles_message_bytes_match_go_roles_message, #574 PR 2a) pins these two Go
// message values — "family-mls-v2/set-roles\0" ‖ sha256(canonical) for
// dev-a2 / alice / base 3 with roles ["registrar"] and []. Pinning them here
// too means a change on EITHER side breaks a test instead of silently
// producing evidence the other side refuses. Never regenerate one side from
// the other; fix whichever drifted.
const (
	rustPinnedRolesRegistrarMessageHex = "66616d696c792d6d6c732d76322f7365742d726f6c657300cc099fb39499943ec2e0690697fbdab93ce51d7f0b32718c63206dfb3f666d02"
	rustPinnedRolesEmptyMessageHex     = "66616d696c792d6d6c732d76322f7365742d726f6c657300e6d5fc9714d0729ce2ae1d8646cbe72ce1997e8c31faf139ce4ba3ac5d948d18"
)

func TestRolesMessagePinnedByRustFacade(t *testing.T) {
	for _, c := range []struct {
		roles []string
		want  string
	}{
		{[]string{RoleRegistrar}, rustPinnedRolesRegistrarMessageHex},
		{[]string{}, rustPinnedRolesEmptyMessageHex},
	} {
		msg, e := RolesMessage(RolesPayloadWire{Action: ApprovalActionRoles, DeviceID: "dev-a2", Actor: "alice", Roles: c.roles, BaseRevision: 3})
		if e != nil {
			t.Fatal(e)
		}
		if got := hex.EncodeToString(msg); got != c.want {
			t.Fatalf("RolesMessage(roles=%v) = %s, Rust facade pins %s", c.roles, got, c.want)
		}
	}
}

func TestRolesShapeRules(t *testing.T) {
	_, a1, ka := baseWithAlice(t)
	// A record without roles encodes exactly as before #574 (hash stability).
	raw, _ := json.Marshal(a1)
	if strings.Contains(string(raw), "roles") {
		t.Fatalf("empty roles must be omitted: %s", raw)
	}
	// Chain validator: unknown role, duplicate, revoked-with-roles.
	bad := a1
	bad.Roles = []string{"admin"}
	if e := validateDeviceSet([]DeviceV4{bad}); !errors.Is(e, ErrDevicePolicyConfig) {
		t.Fatalf("unknown role accepted: %v", e)
	}
	bad.Roles = []string{RoleRegistrar, RoleRegistrar}
	if e := validateDeviceSet([]DeviceV4{bad}); !errors.Is(e, ErrDevicePolicyConfig) {
		t.Fatalf("duplicate role accepted: %v", e)
	}
	bad = ka.device("dev-a1", "alice", "person-alice", AcceptanceOutOfBand, StatusRevoked, 2, nil)
	bad.Roles = []string{RoleRegistrar}
	if e := validateDeviceSet([]DeviceV4{bad}); !errors.Is(e, ErrDevicePolicyConfig) {
		t.Fatalf("revoked device with roles accepted: %v", e)
	}
	// Transition: roles may change only while the device stays active.
	active := a1
	active.Roles = []string{RoleRegistrar}
	if e := deviceTransitionV4([]DeviceV4{a1}, []DeviceV4{active}, 3); e != nil {
		t.Fatalf("grant on active device refused: %v", e)
	}
	revoked := ka.device("dev-a1", "alice", "person-alice", AcceptanceOutOfBand, StatusRevoked, 2, nil)
	withRoles := revoked
	withRoles.Roles = []string{RoleRegistrar}
	if e := deviceTransitionV4([]DeviceV4{revoked}, []DeviceV4{withRoles}, 3); !errors.Is(e, ErrDevicePolicyConfig) {
		t.Fatalf("roles change on a tombstone accepted: %v", e)
	}
	// Strict decoder: "roles" is an allowed key, other new keys are not.
	rec := PolicyRecord4{Revision: 1, Policy: PolicyWire4{Version: 4, Devices: []DeviceV4{active}}}
	raw, _ = json.Marshal(rec)
	var back PolicyRecord4
	if e := strictDevicePolicy(raw, &back); e != nil || !IsRegistrar(back.Policy.Devices[0]) {
		t.Fatalf("roles not decoded: %v", e)
	}
	if e := strictDevicePolicy([]byte(strings.Replace(string(raw), `"roles"`, `"role"`, 1)), &back); !errors.Is(e, ErrDevicePolicyConfig) {
		t.Fatalf("unknown key accepted: %v", e)
	}
	// RolesMessage: wrong action, nil roles, non-canonical list.
	for _, p := range []RolesPayloadWire{
		{Action: ApprovalActionAdd, DeviceID: "d", Actor: "a", Roles: []string{}, BaseRevision: 1},
		{Action: ApprovalActionRoles, DeviceID: "d", Actor: "a", Roles: nil, BaseRevision: 1},
		{Action: ApprovalActionRoles, DeviceID: "d", Actor: "a", Roles: []string{"zzz"}, BaseRevision: 1},
	} {
		if _, e := RolesMessage(p); !errors.Is(e, ErrDevicePolicyApproval) {
			t.Fatalf("RolesMessage(%+v) = %v", p, e)
		}
	}
	// CanonicalRoles de-duplicates and refuses unknowns.
	if r, e := CanonicalRoles([]string{RoleRegistrar, RoleRegistrar}); e != nil || len(r) != 1 {
		t.Fatalf("canonical: %v %v", r, e)
	}
	if _, e := CanonicalRoles([]string{"owner"}); !errors.Is(e, ErrDevicePolicyConfig) {
		t.Fatalf("unknown role canonicalised: %v", e)
	}
	// E1 makes the first device a registrar.
	kb := newKey(t)
	next, e := ApplyEnrollFirst(nil, EnrollCandidate{DeviceID: "dev-b1", Actor: "bob", Subject: "person-bob", SigningKey: kb.hexKey})
	if e != nil || !IsRegistrar(next[0]) {
		t.Fatalf("E1 registrar: %v %v", next, e)
	}
	// Cross-actor E5 is refused even with a valid registrar signature.
	bobs := append([]DeviceV4{active}, next[0])
	if _, _, e := ApplySetRoles(bobs, rolesEvidence(t, ka, "dev-b1", "bob", nil, 9), 9); !errors.Is(e, ErrDevicePolicyApproval) {
		t.Fatalf("cross-actor E5: %v", e)
	}
}
