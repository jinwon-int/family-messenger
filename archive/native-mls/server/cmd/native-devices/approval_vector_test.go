package main

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/jinwon-int/family-messenger/archive/native-mls/server/internal/devicepolicy"
)

// approvalVector is archive/native-mls/tests/fixtures/ios-ffi-approval-vector.json,
// written by the iOS FFI host test (ios-ffi/tests/policy_wire.rs). That test proves
// ios-ffi `sign_approval` still emits these exact bytes; this one proves the
// owner CLI accepts them (#275 L2 (a) acceptance: cross-language verification).
type approvalVector struct {
	ApproverIdentity     string `json:"approver_identity"`
	ApproverPublicHex    string `json:"approver_public_hex"`
	ApproverFingerprint  string `json:"approver_fingerprint"`
	Actor                string `json:"actor"`
	Subject              string `json:"subject"`
	CandidateDeviceID    string `json:"candidate_device_id"`
	CandidatePublicHex   string `json:"candidate_public_hex"`
	CandidateFingerprint string `json:"candidate_fingerprint"`
	BaseRevision         uint64 `json:"base_revision"`
	CanonicalHex         string `json:"canonical_hex"`
	SignatureHex         string `json:"signature_hex"`
}

func loadApprovalVector(t *testing.T) approvalVector {
	t.Helper()
	raw, e := os.ReadFile(filepath.Join("..", "..", "..", "tests", "fixtures", "ios-ffi-approval-vector.json"))
	if e != nil {
		t.Fatal(e)
	}
	var v approvalVector
	if e := json.Unmarshal(raw, &v); e != nil {
		t.Fatal(e)
	}
	return v
}

func TestIOSFFIApprovalVectorIsAcceptedByAddDevice(t *testing.T) {
	v := loadApprovalVector(t)

	// The facade's canonical bytes are exactly Go's ApprovalPayloadWire encoding,
	// so the CLI's reconstruction signs-checks the same message.
	wire := devicepolicy.ApprovalPayloadWire{
		Action: devicepolicy.ApprovalActionAdd, DeviceID: v.CandidateDeviceID, Actor: v.Actor,
		Subject: v.Subject, SigningKey: v.CandidatePublicHex, Fingerprint: v.CandidateFingerprint,
		Acceptance: devicepolicy.AcceptanceTrusted, BaseRevision: v.BaseRevision,
	}
	want, e := json.Marshal(wire)
	if e != nil {
		t.Fatal(e)
	}
	got, e := hex.DecodeString(v.CanonicalHex)
	if e != nil {
		t.Fatal(e)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("canonical bytes diverge:\n facade %s\n go     %s", got, want)
	}
	if fp, e := fingerprintOf(v.CandidatePublicHex); e != nil || fp != v.CandidateFingerprint {
		t.Fatalf("candidate fingerprint = %q, %v; vector %q", fp, e, v.CandidateFingerprint)
	}

	state := filepath.Join(cliDir(t), "policy")
	cand := cliDir(t)
	capture := func(args ...string) stateView {
		t.Helper()
		var out bytes.Buffer
		if e := run(append([]string{"-device-state", state}, args...), &out); e != nil {
			t.Fatalf("run(%v): %v", args, e)
		}
		var sv stateView
		if e := json.Unmarshal(out.Bytes(), &sv); e != nil {
			t.Fatalf("output %q: %v", out.String(), e)
		}
		return sv
	}

	if sv := capture("-init"); sv.Revision != 1 {
		t.Fatalf("init revision = %d", sv.Revision)
	}
	write := cliCandidate(t, cand, "approver.json", enrollCandidate{
		DeviceID: v.ApproverIdentity, Actor: v.Actor, Subject: v.Subject, SigningKey: v.ApproverPublicHex,
	})
	sv := capture("-enroll-first", "-input", write, "-expected-revision", "1")
	if sv.Revision != v.BaseRevision || len(sv.Devices) != 1 || sv.Devices[0].Fingerprint != v.ApproverFingerprint {
		t.Fatalf("approver enrollment = %+v", sv)
	}

	// The evidence exactly as relay-app hands it over: signature = lowercase hex of
	// the trailing 64 bytes of the ios-ffi framed output.
	write = cliCandidate(t, cand, "candidate.json", addDeviceCandidate{
		DeviceID: v.CandidateDeviceID, Actor: v.Actor, Subject: v.Subject,
		SigningKey: v.CandidatePublicHex, BaseRevision: v.BaseRevision, Signature: v.SignatureHex,
	})
	sv = capture("-add-device", "-input", write, "-expected-revision", "2")
	if sv.Revision != 3 {
		t.Fatalf("add-device revision = %d", sv.Revision)
	}
	var added *deviceSummary
	for i := range sv.Devices {
		if sv.Devices[i].DeviceID == v.CandidateDeviceID {
			added = &sv.Devices[i]
		}
	}
	if added == nil || added.Status != devicepolicy.StatusActive || added.Fingerprint != v.CandidateFingerprint ||
		added.ApprovedBy == nil || added.ApprovedBy.DeviceID != v.ApproverIdentity {
		t.Fatalf("candidate after add-device = %+v", added)
	}

	// One flipped signature bit is refused: the CLI really verified these bytes.
	sig, e := hex.DecodeString(v.SignatureHex)
	if e != nil || len(sig) != 64 {
		t.Fatalf("signature hex: %v len %d", e, len(sig))
	}
	sig[0] ^= 1
	state2 := filepath.Join(cliDir(t), "policy")
	for _, args := range [][]string{{"-init"}, {"-enroll-first", "-input", cliCandidate(t, cand, "approver2.json", enrollCandidate{
		DeviceID: v.ApproverIdentity, Actor: v.Actor, Subject: v.Subject, SigningKey: v.ApproverPublicHex,
	}), "-expected-revision", "1"}} {
		if e := run(append([]string{"-device-state", state2}, args...), &bytes.Buffer{}); e != nil {
			t.Fatalf("run(%v): %v", args, e)
		}
	}
	bad := cliCandidate(t, cand, "bad.json", addDeviceCandidate{
		DeviceID: v.CandidateDeviceID, Actor: v.Actor, Subject: v.Subject,
		SigningKey: v.CandidatePublicHex, BaseRevision: v.BaseRevision, Signature: hex.EncodeToString(sig),
	})
	if e := run([]string{"-device-state", state2, "-add-device", "-input", bad, "-expected-revision", "2"}, &bytes.Buffer{}); e == nil {
		t.Fatal("tampered signature was accepted")
	}
}
