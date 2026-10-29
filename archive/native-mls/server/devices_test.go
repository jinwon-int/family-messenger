// Device self-service tests (#574 D1, devices.go). Pinned here: a person's
// new device posts itself into the mailbox and an existing device of the
// same subject lists it with the base_revision to sign against; the signed
// E2 evidence enrolls the device through the chain's own validator (same
// actor, registrar once one exists, exact base_revision CAS) and is bound to
// the caller's subject on both ends; E5 moves the registrar role; /v2/me
// shows the subject's devices and the chain revision; a Welcome names the
// device that sent it; and the routes exist only with both a verifier and a
// device store.
package main

import (
	"crypto/ed25519"
	crand "crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/jinwon-int/family-messenger/archive/native-mls/server/internal/devicepolicy"
)

type realKey struct {
	priv   ed25519.PrivateKey
	hexKey string
	fp     string
}

func newRealKey(t *testing.T) realKey {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(crand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(pub)
	return realKey{priv: priv, hexKey: hex.EncodeToString(pub), fp: hex.EncodeToString(sum[:])}
}

// enrollFirstKeyed commits an actor's E1 device with a real key (and the
// registrar role unless legacy), so tests can sign evidence with it.
func enrollFirstKeyed(t *testing.T, st *devicepolicy.DevicePolicyStore, id, actor, subject string, legacy bool) realKey {
	t.Helper()
	k := newRealKey(t)
	info, wire, err := st.Read()
	if err != nil {
		t.Fatal(err)
	}
	d := devicepolicy.DeviceV4{ID: id, Actor: actor, Subject: subject, SigningKey: k.hexKey, Fingerprint: k.fp,
		Status: devicepolicy.StatusActive, Revision: 1, Acceptance: devicepolicy.AcceptanceOutOfBand}
	if !legacy {
		d.Roles = []string{devicepolicy.RoleRegistrar}
	}
	wire.Devices = append(wire.Devices, d)
	if _, err := st.Commit(info.Revision, wire); err != nil {
		t.Fatalf("enroll %s: %v", id, err)
	}
	return k
}

func signAddEvidence(t *testing.T, signer realKey, candidate realKey, id, actor, subject string, base uint64) devicepolicy.AddDeviceEvidence {
	t.Helper()
	payload := devicepolicy.ApprovalPayloadWire{Action: devicepolicy.ApprovalActionAdd, DeviceID: id, Actor: actor, Subject: subject,
		SigningKey: candidate.hexKey, Fingerprint: candidate.fp, Acceptance: devicepolicy.AcceptanceTrusted, BaseRevision: base}
	msg, err := devicepolicy.ApprovalMessage(payload)
	if err != nil {
		t.Fatal(err)
	}
	return devicepolicy.AddDeviceEvidence{DeviceID: id, Actor: actor, Subject: subject, SigningKey: candidate.hexKey, BaseRevision: base,
		Signature: hex.EncodeToString(ed25519.Sign(signer.priv, msg)), Fingerprint: candidate.fp}
}

func signRolesEvidence(t *testing.T, signer realKey, id, actor string, roles []string, base uint64) devicepolicy.RolesEvidence {
	t.Helper()
	msg, err := devicepolicy.RolesMessage(devicepolicy.RolesPayloadWire{Action: devicepolicy.ApprovalActionRoles, DeviceID: id, Actor: actor, Roles: roles, BaseRevision: base})
	if err != nil {
		t.Fatal(err)
	}
	return devicepolicy.RolesEvidence{DeviceID: id, Actor: actor, Roles: roles, BaseRevision: base, Signature: hex.EncodeToString(ed25519.Sign(signer.priv, msg))}
}

func mustJSON(t *testing.T, v any) []byte {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func decodeInto(t *testing.T, raw []byte, v any) {
	t.Helper()
	if err := json.Unmarshal(raw, v); err != nil {
		t.Fatalf("decode %s: %v", raw, err)
	}
}

func selfServiceRelay(t *testing.T) (*relay, *httptest.Server, *devicepolicy.DevicePolicyStore, *testIssuer) {
	t.Helper()
	r, srv, st, _, iss := newAuthedRelay(t, testPolicy())
	srv.Config.Handler = r.routes() // the device routes need r.access, set after construction
	return r, srv, st, iss
}

func TestDeviceSelfServiceEnrollsAndMovesRegistrar(t *testing.T) {
	r, srv, st, iss := selfServiceRelay(t)
	ka := enrollFirstKeyed(t, st, "alice-iphone", "alice", "subject-alice", false) // revision 2, registrar
	enrollFirstKeyed(t, st, "bob-phone", "bob", "subject-bob", false)              // revision 3
	alice := iss.mint("subject-alice", nil)
	bob := iss.mint("subject-bob", nil)
	kb := newRealKey(t) // alice's new android

	// 1. The new device posts itself (JWT only; it is not in the chain).
	st201, raw := doAuth(t, srv, "POST", "/v2/devices/candidates", mustJSON(t, candidatePost{DeviceID: "alice-android", Actor: "alice", SigningKey: kb.hexKey, Fingerprint: kb.fp}), alice)
	if st201 != http.StatusCreated {
		t.Fatalf("post candidate: %d %s", st201, raw)
	}
	var posted candidatePosted
	decodeInto(t, raw, &posted)
	if posted.DeviceID != "alice-android" || posted.Fingerprint != kb.fp || posted.PolicyRevision != 3 || posted.ExpiresAt == 0 {
		t.Fatalf("posted = %+v", posted)
	}
	// Re-posting refreshes rather than duplicating; a wrong fingerprint is 400.
	if code, raw := doAuth(t, srv, "POST", "/v2/devices/candidates", mustJSON(t, candidatePost{DeviceID: "alice-android", Actor: "alice", SigningKey: kb.hexKey}), alice); code != http.StatusCreated {
		t.Fatalf("re-post: %d %s", code, raw)
	}
	if code, raw := doAuth(t, srv, "POST", "/v2/devices/candidates", mustJSON(t, candidatePost{DeviceID: "alice-x", Actor: "alice", SigningKey: kb.hexKey, Fingerprint: ka.fp}), alice); code != http.StatusBadRequest || errField(t, raw) != "bad_candidate" {
		t.Fatalf("bad fingerprint: %d %s", code, raw)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM device_candidates`); n != 1 {
		t.Fatalf("candidate rows = %d", n)
	}

	// 2. Alice's iPhone lists the mailbox; Bob's phone sees nothing of hers.
	code, raw := doAuth(t, srv, "GET", "/v2/devices/candidates?device=alice-iphone", nil, alice)
	if code != http.StatusOK {
		t.Fatalf("list: %d %s", code, raw)
	}
	var listed candidatesResponse
	decodeInto(t, raw, &listed)
	if listed.PolicyRevision != 3 || len(listed.Candidates) != 1 || listed.Candidates[0].DeviceID != "alice-android" || listed.Candidates[0].Subject != "subject-alice" || listed.Candidates[0].SigningKey != kb.hexKey {
		t.Fatalf("listed = %+v", listed)
	}
	if code, raw := doAuth(t, srv, "GET", "/v2/devices/candidates?device=bob-phone", nil, bob); code != http.StatusOK || !strings.Contains(string(raw), `"candidates":[]`) {
		t.Fatalf("bob's list: %d %s", code, raw)
	}
	// Listing as a device the token does not own is the usual 403.
	if code, raw := doAuth(t, srv, "GET", "/v2/devices/candidates?device=alice-iphone", nil, bob); code != http.StatusForbidden || errField(t, raw) != "device_subject_mismatch" {
		t.Fatalf("foreign list: %d %s", code, raw)
	}

	// 3. The iPhone approves: signed against policy_revision 3.
	ev := signAddEvidence(t, ka, kb, "alice-android", "alice", "subject-alice", 3)
	// …but Bob cannot submit Alice's evidence, even though it verifies.
	if code, raw := doAuth(t, srv, "POST", "/v2/devices/approvals", mustJSON(t, ev), bob); code != http.StatusForbidden || errField(t, raw) != "subject_mismatch" {
		t.Fatalf("bob submits alice's evidence: %d %s", code, raw)
	}
	// A stale base_revision is 409 and names the current revision.
	stale := signAddEvidence(t, ka, kb, "alice-android", "alice", "subject-alice", 2)
	if code, raw := doAuth(t, srv, "POST", "/v2/devices/approvals", mustJSON(t, stale), alice); code != http.StatusConflict || errField(t, raw) != "stale_revision" || !strings.Contains(string(raw), `"revision":3`) {
		t.Fatalf("stale: %d %s", code, raw)
	}
	// A broken signature is 403 approval_rejected.
	broken := ev
	broken.Signature = strings.Repeat("00", ed25519.SignatureSize)
	if code, raw := doAuth(t, srv, "POST", "/v2/devices/approvals", mustJSON(t, broken), alice); code != http.StatusForbidden || errField(t, raw) != "approval_rejected" {
		t.Fatalf("broken signature: %d %s", code, raw)
	}
	code, raw = doAuth(t, srv, "POST", "/v2/devices/approvals", mustJSON(t, ev), alice)
	if code != http.StatusCreated {
		t.Fatalf("approve: %d %s", code, raw)
	}
	var approved approvalResponse
	decodeInto(t, raw, &approved)
	if approved.DeviceID != "alice-android" || approved.ApprovedBy != "alice-iphone" || approved.Revision != 4 {
		t.Fatalf("approved = %+v", approved)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM device_candidates`); n != 0 {
		t.Fatalf("candidate not dropped: %d", n)
	}
	// The android is now an active chain device bound to alice's subject.
	if code, raw := doAuth(t, srv, "GET", "/v2/rooms?device=alice-android", nil, alice); code != http.StatusOK {
		t.Fatalf("android acts: %d %s", code, raw)
	}
	// Replaying the same evidence is a 409 (base_revision 3 is gone).
	if code, raw := doAuth(t, srv, "POST", "/v2/devices/approvals", mustJSON(t, ev), alice); code != http.StatusConflict {
		t.Fatalf("replay: %d %s", code, raw)
	}

	// 4. /v2/me: both devices, roles, policy_revision.
	code, raw = doAuth(t, srv, "GET", mePath, nil, alice)
	if code != http.StatusOK {
		t.Fatalf("me: %d %s", code, raw)
	}
	var me meResponse
	decodeInto(t, raw, &me)
	if me.Subject != "subject-alice" || me.PolicyRevision == nil || *me.PolicyRevision != 4 || len(me.Devices) != 2 {
		t.Fatalf("me = %s", raw)
	}
	if me.Devices[0].DeviceID != "alice-iphone" || len(me.Devices[0].Roles) != 1 || me.Devices[1].DeviceID != "alice-android" || len(me.Devices[1].Roles) != 0 || strings.Contains(string(raw), "signing_key") {
		t.Fatalf("me devices = %s", raw)
	}

	// 5. The android (no role) cannot enroll a third device: registrar only.
	kc := newRealKey(t)
	if code, raw := doAuth(t, srv, "POST", "/v2/devices/approvals", mustJSON(t, signAddEvidence(t, kb, kc, "alice-pc", "alice", "subject-alice", 4)), alice); code != http.StatusForbidden || errField(t, raw) != "approval_rejected" || !strings.Contains(string(raw), "registrar") {
		t.Fatalf("non-registrar approval: %d %s", code, raw)
	}
	// 6. E5: the android cannot grant itself; the iPhone grants it, then steps down.
	if code, raw := doAuth(t, srv, "POST", "/v2/devices/roles", mustJSON(t, signRolesEvidence(t, kb, "alice-android", "alice", []string{devicepolicy.RoleRegistrar}, 4)), alice); code != http.StatusForbidden || !strings.Contains(string(raw), "registrar") {
		t.Fatalf("self-grant: %d %s", code, raw)
	}
	// Bob's token cannot touch alice's device even with a valid alice signature.
	if code, raw := doAuth(t, srv, "POST", "/v2/devices/roles", mustJSON(t, signRolesEvidence(t, ka, "alice-android", "alice", []string{devicepolicy.RoleRegistrar}, 4)), bob); code != http.StatusForbidden || errField(t, raw) != "device_subject_mismatch" {
		t.Fatalf("bob sets alice's roles: %d %s", code, raw)
	}
	if code, raw := doAuth(t, srv, "POST", "/v2/devices/roles", []byte(`{"device_id":"alice-android","actor":"alice","base_revision":4,"signature":"00"}`), alice); code != http.StatusBadRequest {
		t.Fatalf("roles missing: %d %s", code, raw)
	}
	code, raw = doAuth(t, srv, "POST", "/v2/devices/roles", mustJSON(t, signRolesEvidence(t, ka, "alice-android", "alice", []string{devicepolicy.RoleRegistrar}, 4)), alice)
	if code != http.StatusCreated {
		t.Fatalf("grant: %d %s", code, raw)
	}
	decodeInto(t, raw, &approved)
	if approved.Revision != 5 || approved.ApprovedBy != "alice-iphone" || len(approved.Roles) != 1 {
		t.Fatalf("grant = %+v", approved)
	}
	// The last-registrar guard: with two registrars the iPhone may step down…
	if code, raw := doAuth(t, srv, "POST", "/v2/devices/roles", mustJSON(t, signRolesEvidence(t, ka, "alice-iphone", "alice", []string{}, 5)), alice); code != http.StatusCreated {
		t.Fatalf("step down: %d %s", code, raw)
	}
	// …and the android, now alone, may not.
	if code, raw := doAuth(t, srv, "POST", "/v2/devices/roles", mustJSON(t, signRolesEvidence(t, kb, "alice-android", "alice", []string{}, 6)), alice); code != http.StatusForbidden || !strings.Contains(string(raw), "without a registrar") {
		t.Fatalf("last registrar: %d %s", code, raw)
	}
	// Now only the android enrolls: the pc comes in signed by it.
	if code, raw := doAuth(t, srv, "POST", "/v2/devices/approvals", mustJSON(t, signAddEvidence(t, kb, kc, "alice-pc", "alice", "subject-alice", 6)), alice); code != http.StatusCreated {
		t.Fatalf("android enrolls pc: %d %s", code, raw)
	}
	// The chain itself agrees (replayed from disk).
	info, wire, err := st.Read()
	if err != nil || info.Revision != 7 || len(wire.Devices) != 4 || !devicepolicy.IsRegistrar(wire.Devices[2]) || devicepolicy.IsRegistrar(wire.Devices[0]) {
		t.Fatalf("chain: rev=%d err=%v devices=%+v", info.Revision, err, wire.Devices)
	}

	// 7. A Welcome lists the device that sent it (auto-accept from a sibling).
	if code, raw := doAuth(t, srv, "POST", "/v2/rooms/r/events", postEventBody(t, "alice-iphone", "m1", "application", 0, nil, nil, []byte("hi")), alice); code != http.StatusCreated {
		t.Fatalf("found room: %d %s", code, raw)
	}
	if code, raw := doAuth(t, srv, "POST", "/v2/rooms/r/events", postEventBody(t, "alice-iphone", "w1", "welcome", 0, nil, []string{"alice-pc"}, []byte("welcome")), alice); code != http.StatusCreated {
		t.Fatalf("welcome: %d %s", code, raw)
	}
	code, raw = doAuth(t, srv, "GET", "/v2/lobby/welcomes?device=alice-pc", nil, alice)
	if code != http.StatusOK {
		t.Fatalf("welcomes: %d %s", code, raw)
	}
	var welcomes welcomesResponse
	decodeInto(t, raw, &welcomes)
	if len(welcomes.Welcomes) != 1 || welcomes.Welcomes[0].From != "alice-iphone" || welcomes.Welcomes[0].Room != "r" {
		t.Fatalf("welcomes = %s", raw)
	}
}

func TestDeviceSelfServiceGates(t *testing.T) {
	_, srv, st, iss := selfServiceRelay(t)
	ka := enrollFirstKeyed(t, st, "alice-iphone", "alice", "subject-alice", true) // legacy: no registrar
	alice := iss.mint("subject-alice", nil)
	carol := iss.mint("subject-carol", nil)
	kb := newRealKey(t)

	// Without a token every route is 401; cross-site is refused.
	for _, c := range []struct{ method, path string }{{"POST", "/v2/devices/candidates"}, {"GET", "/v2/devices/candidates?device=alice-iphone"}, {"POST", "/v2/devices/approvals"}, {"POST", "/v2/devices/roles"}} {
		if code, _ := doJSON(t, srv, c.method, c.path, []byte(`{}`)); code != http.StatusUnauthorized {
			t.Fatalf("%s %s without token: %d", c.method, c.path, code)
		}
	}
	// A person with no device yet cannot post a candidate (E1 stays out-of-band).
	if code, raw := doAuth(t, srv, "POST", "/v2/devices/candidates", mustJSON(t, candidatePost{DeviceID: "carol-phone", Actor: "carol", SigningKey: kb.hexKey}), carol); code != http.StatusForbidden || errField(t, raw) != "first_device_out_of_band" {
		t.Fatalf("carol: %d %s", code, raw)
	}
	// A candidate naming someone else's subject, an existing id, a bad key.
	for name, c := range map[string]struct {
		body   any
		status int
		code   string
	}{
		"foreign subject": {candidatePost{DeviceID: "alice-x", Actor: "alice", Subject: "subject-bob", SigningKey: kb.hexKey}, http.StatusForbidden, "subject_mismatch"},
		"existing id":     {candidatePost{DeviceID: "alice-iphone", Actor: "alice", SigningKey: kb.hexKey}, http.StatusConflict, "device_exists"},
		"bad key":         {candidatePost{DeviceID: "alice-x", Actor: "alice", SigningKey: "zz"}, http.StatusBadRequest, "bad_candidate"},
		"bad id":          {candidatePost{DeviceID: "alice x", Actor: "alice", SigningKey: kb.hexKey}, http.StatusBadRequest, "bad_identifier"},
		"unknown field":   {map[string]any{"device_id": "alice-x", "actor": "alice", "signing_key": kb.hexKey, "roles": []string{"registrar"}}, http.StatusBadRequest, "bad_request"},
	} {
		if code, raw := doAuth(t, srv, "POST", "/v2/devices/candidates", mustJSON(t, c.body), alice); code != c.status || errField(t, raw) != c.code {
			t.Fatalf("%s: %d %s, want %d %s", name, code, raw, c.status, c.code)
		}
	}
	// Legacy actor: the only device (no role) still approves — the pre-#574
	// rule holds until someone bootstraps a registrar.
	if code, raw := doAuth(t, srv, "POST", "/v2/devices/approvals", mustJSON(t, signAddEvidence(t, ka, kb, "alice-android", "alice", "subject-alice", 2)), alice); code != http.StatusCreated {
		t.Fatalf("legacy approval: %d %s", code, raw)
	}
	// Bootstrap from the new device itself (any active device of a
	// registrar-less actor may), then the iPhone's E2 signature is refused.
	if code, raw := doAuth(t, srv, "POST", "/v2/devices/roles", mustJSON(t, signRolesEvidence(t, kb, "alice-android", "alice", []string{devicepolicy.RoleRegistrar}, 3)), alice); code != http.StatusCreated {
		t.Fatalf("bootstrap: %d %s", code, raw)
	}
	kc := newRealKey(t)
	if code, raw := doAuth(t, srv, "POST", "/v2/devices/approvals", mustJSON(t, signAddEvidence(t, ka, kc, "alice-pc", "alice", "subject-alice", 4)), alice); code != http.StatusForbidden || !strings.Contains(string(raw), "registrar") {
		t.Fatalf("iphone after bootstrap: %d %s", code, raw)
	}
	// Approving someone else's candidate under my token: subject mismatch
	// even when the actor matches (the evidence names subject-bob).
	if code, raw := doAuth(t, srv, "POST", "/v2/devices/approvals", mustJSON(t, signAddEvidence(t, kb, kc, "alice-pc", "alice", "subject-bob", 4)), alice); code != http.StatusForbidden || errField(t, raw) != "subject_mismatch" {
		t.Fatalf("evidence for another subject: %d %s", code, raw)
	}
}

// The routes exist only with a verifier AND a device store.
func TestDeviceSelfServiceAbsentWithoutVerifierOrStore(t *testing.T) {
	// Store but no verifier.
	_, srv, _, _, _ := newEnforcedRelay(t, testPolicy())
	if code, _ := doJSON(t, srv, "POST", "/v2/devices/candidates", []byte(`{}`)); code != http.StatusNotFound {
		t.Fatalf("without verifier: %d", code)
	}
	// Verifier but no store.
	r, srv2 := newTestRelay(t, testPolicy())
	iss := newTestIssuer(t)
	r.access = iss.verifier()
	srv2.Config.Handler = r.routes()
	if code, _ := doAuth(t, srv2, "POST", "/v2/devices/candidates", []byte(`{}`), iss.mint("s", nil)); code != http.StatusNotFound {
		t.Fatalf("without store: %d", code)
	}
	// /v2/me without a store keeps its one-key body.
	if code, raw := doAuth(t, srv2, "GET", mePath, nil, iss.mint("s", nil)); code != http.StatusOK || string(raw) != `{"subject":"s"}` {
		t.Fatalf("me without store: %d %s", code, raw)
	}
}
