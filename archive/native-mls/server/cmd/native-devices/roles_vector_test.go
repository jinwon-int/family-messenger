package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/jinwon-int/family-messenger/archive/native-mls/server/internal/devicepolicy"
)

// rolesVector is archive/native-mls/tests/fixtures/ios-ffi-roles-vector.json,
// written by the iOS FFI host test (ios-ffi/tests/policy_wire.rs,
// FM_REGEN_ROLES_VECTOR=1). That test proves the Rust facade `sign_roles`
// (#574 PR 2a, #579) still emits these exact bytes; this one proves the Go
// side (devicepolicy.RolesMessage / ApplySetRoles and the owner CLI
// -set-roles) accepts them — the E5 counterpart of approval_vector_test.go.
type rolesVector struct {
	ApproverIdentity    string   `json:"approver_identity"`
	ApproverPublicHex   string   `json:"approver_public_hex"`
	ApproverFingerprint string   `json:"approver_fingerprint"`
	Actor               string   `json:"actor"`
	DeviceID            string   `json:"device_id"`
	Roles               []string `json:"roles"`
	BaseRevision        uint64   `json:"base_revision"`
	CanonicalHex        string   `json:"canonical_hex"`
	SignatureHex        string   `json:"signature_hex"`
	FramedHex           string   `json:"framed_hex"`
}

func loadRolesVector(t *testing.T) rolesVector {
	t.Helper()
	raw, e := os.ReadFile(filepath.Join("..", "..", "..", "tests", "fixtures", "ios-ffi-roles-vector.json"))
	if e != nil {
		t.Fatal(e)
	}
	var v rolesVector
	if e := json.Unmarshal(raw, &v); e != nil {
		t.Fatal(e)
	}
	return v
}

func unhex(t *testing.T, s string) []byte {
	t.Helper()
	b, e := hex.DecodeString(s)
	if e != nil {
		t.Fatalf("hex %q: %v", s, e)
	}
	return b
}

// rolesVectorDevices is the pre-transition state the vector's base_revision
// describes (policy_wire.rs: -init → rev 1, approver -enroll-first → rev 2,
// target -add-device → rev 3, -set-roles on top). The approver carries the
// vector's public key; the target gets a fresh key — only the approver signs.
func rolesVectorDevices(t *testing.T, v rolesVector, approverRoles []string) []devicepolicy.DeviceV4 {
	t.Helper()
	const subject = "person-owner"
	target := newCLIKey(t)
	return []devicepolicy.DeviceV4{
		{
			ID: v.ApproverIdentity, Actor: v.Actor, Subject: subject,
			SigningKey: v.ApproverPublicHex, Fingerprint: v.ApproverFingerprint,
			Status: devicepolicy.StatusActive, Revision: 1, Acceptance: devicepolicy.AcceptanceOutOfBand,
			Roles: approverRoles,
		},
		{
			ID: v.DeviceID, Actor: v.Actor, Subject: subject,
			SigningKey: target.hexKey, Fingerprint: target.fp,
			Status: devicepolicy.StatusActive, Revision: 1, Acceptance: devicepolicy.AcceptanceTrusted,
			ApprovedBy: &devicepolicy.DeviceApproval{DeviceID: v.ApproverIdentity, Revision: v.BaseRevision},
		},
	}
}

func TestIOSFFIRolesVectorMatchesGoRolesMessage(t *testing.T) {
	v := loadRolesVector(t)
	if fp, e := fingerprintOf(v.ApproverPublicHex); e != nil || fp != v.ApproverFingerprint {
		t.Fatalf("approver fingerprint = %q, %v; vector %q", fp, e, v.ApproverFingerprint)
	}

	// (1) The facade's canonical bytes are exactly Go's RolesPayloadWire encoding.
	wire := devicepolicy.RolesPayloadWire{
		Action: devicepolicy.ApprovalActionRoles, DeviceID: v.DeviceID, Actor: v.Actor,
		Roles: v.Roles, BaseRevision: v.BaseRevision,
	}
	want, e := json.Marshal(wire)
	if e != nil {
		t.Fatal(e)
	}
	canonical := unhex(t, v.CanonicalHex)
	if !bytes.Equal(canonical, want) {
		t.Fatalf("canonical bytes diverge:\n facade %s\n go     %s", canonical, want)
	}

	// (2) The signature verifies over Go's domain-separated message with the
	// approver's public key — so RolesMessage and the facade agree on prefix,
	// action and digest, not just on the payload.
	msg, e := devicepolicy.RolesMessage(wire)
	if e != nil {
		t.Fatal(e)
	}
	pub := unhex(t, v.ApproverPublicHex)
	sig := unhex(t, v.SignatureHex)
	if len(pub) != ed25519.PublicKeySize || len(sig) != ed25519.SignatureSize {
		t.Fatalf("key %d / signature %d bytes", len(pub), len(sig))
	}
	if !ed25519.Verify(ed25519.PublicKey(pub), msg, sig) {
		t.Fatal("vector signature does not verify over devicepolicy.RolesMessage")
	}

	// (4) framed = u32le len(canonical) ‖ canonical ‖ signature — the bytes
	// relay-app / hande-web / iOS split before posting `signature` as hex.
	framed := make([]byte, 4, 4+len(canonical)+len(sig))
	binary.LittleEndian.PutUint32(framed, uint32(len(canonical)))
	framed = append(framed, canonical...)
	framed = append(framed, sig...)
	if got := unhex(t, v.FramedHex); !bytes.Equal(got, framed) {
		t.Fatalf("framed bytes diverge:\n facade %x\n go     %x", got, framed)
	}
}

func TestIOSFFIRolesVectorIsAcceptedByApplySetRoles(t *testing.T) {
	v := loadRolesVector(t)
	evidence := devicepolicy.RolesEvidence{
		DeviceID: v.DeviceID, Actor: v.Actor, Roles: v.Roles, BaseRevision: v.BaseRevision, Signature: v.SignatureHex,
	}
	// (3) Both signer situations VerifyRoles allows: the approver is the actor's
	// registrar (post-#574 chain), or nobody is yet (pre-#574 chain, legacy
	// "any active device" bootstrap).
	for name, approverRoles := range map[string][]string{"registrar": {devicepolicy.RoleRegistrar}, "legacy": nil} {
		t.Run(name, func(t *testing.T) {
			devices := rolesVectorDevices(t, v, approverRoles)
			next, approver, e := devicepolicy.ApplySetRoles(devices, evidence, v.BaseRevision)
			if e != nil || approver != v.ApproverIdentity {
				t.Fatalf("ApplySetRoles: approver=%q err=%v", approver, e)
			}
			i, ok := devicepolicy.FindByID(next, v.DeviceID)
			if !ok || len(next[i].Roles) != len(v.Roles) || !devicepolicy.IsRegistrar(next[i]) {
				t.Fatalf("target after set-roles = %+v", next[i])
			}
			if len(devices[1].Roles) != 0 {
				t.Fatal("input set was mutated")
			}
		})
	}
	// Stale base_revision is a conflict (re-sign), never an approval verdict.
	if _, _, e := devicepolicy.ApplySetRoles(rolesVectorDevices(t, v, nil), evidence, v.BaseRevision+1); !errors.Is(e, devicepolicy.ErrDevicePolicyConflict) {
		t.Fatalf("stale revision: %v", e)
	}
	// One flipped signature bit is refused: the bytes really were verified.
	sig := unhex(t, v.SignatureHex)
	sig[0] ^= 1
	bad := evidence
	bad.Signature = hex.EncodeToString(sig)
	if _, _, e := devicepolicy.ApplySetRoles(rolesVectorDevices(t, v, nil), bad, v.BaseRevision); !errors.Is(e, devicepolicy.ErrDevicePolicyApproval) {
		t.Fatalf("tampered signature: %v", e)
	}
}

// TestIOSFFIRolesVectorIsAcceptedBySetRolesCLI drives the same evidence through
// run() against a real chain at the vector's base_revision — the path the
// operator takes with `-set-roles <id> -roles registrar -input <evidence>`.
func TestIOSFFIRolesVectorIsAcceptedBySetRolesCLI(t *testing.T) {
	v := loadRolesVector(t)
	state := filepath.Join(cliDir(t), "policy")
	if e := run([]string{"-device-state", state, "-init"}, &bytes.Buffer{}); e != nil {
		t.Fatal(e)
	}
	store, e := devicepolicy.OpenDevicePolicyStore(state)
	if e != nil {
		t.Fatal(e)
	}
	devices := rolesVectorDevices(t, v, []string{devicepolicy.RoleRegistrar})
	for rev, set := range [][]devicepolicy.DeviceV4{devices[:1], devices} {
		info, e := store.Commit(uint64(rev+1), devicepolicy.PolicyWire4{Version: 4, Devices: set})
		if e != nil || info.Revision != uint64(rev+2) {
			t.Fatalf("commit %d: rev=%d err=%v", rev+1, info.Revision, e)
		}
	}
	// Chain is now at the vector's base_revision with approver (registrar) and target.
	evidence := cliCandidate(t, cliDir(t), "roles.json", rolesCandidate{
		DeviceID: v.DeviceID, Actor: v.Actor, Roles: v.Roles, BaseRevision: v.BaseRevision, Signature: v.SignatureHex,
	})
	var out bytes.Buffer
	if e := run([]string{"-device-state", state, "-set-roles", v.DeviceID, "-roles", "registrar", "-expected-revision", "3", "-input", evidence}, &out); e != nil {
		t.Fatalf("-set-roles with ios-ffi evidence: %v", e)
	}
	var sv stateView
	if e := json.Unmarshal(out.Bytes(), &sv); e != nil {
		t.Fatalf("output %q: %v", out.String(), e)
	}
	if sv.Revision != v.BaseRevision+1 || len(rolesOfView(sv, v.DeviceID)) != 1 || rolesOfView(sv, v.DeviceID)[0] != devicepolicy.RoleRegistrar {
		t.Fatalf("view after -set-roles: %+v", sv)
	}
	if bytes.Contains(out.Bytes(), []byte(v.ApproverPublicHex)) {
		t.Fatal("CLI output leaked a signing key")
	}
}
