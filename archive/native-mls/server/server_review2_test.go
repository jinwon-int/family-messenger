// Review 2 (#231, main 18f8888) relay fixes, pinned by test: non-member
// application/welcome posts are refused and create no pruning gate (G-H1),
// commits are exempt from the room byte cap so a pinned room can still be
// repaired (G-H2), a replicated member's actor must match the device policy
// (G-H3), every stored column outside `bytes` is shape-bounded (G-H4), the
// {room} path value is an identifier (G-M2), consuming a key package needs
// membership and policy activity inside the transaction (G-M3), and the JWKS
// reload is throttled from the last attempt with the fetch outside the lock
// and an empty key set never replacing a working cache (G-M5/L1).
package main

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/json"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"
)

func TestNonMemberPostIsRefusedAndCreatesNoCursor(t *testing.T) {
	r, srv, st, _, first := newEnforcedRelay(t, testPolicy())
	enrollDevice(t, st, first, "a1", "alice")
	enrollDevice(t, st, first, "b1", "bob")
	enrollDevice(t, st, first, "c1", "carol")

	// Before the founding commit the legacy behaviour stays: any active device
	// may post (the smoke's key-package-first bootstrap relies on it).
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "c1", "pre", "application", 0, nil, nil, []byte("pre-bootstrap"))); code != http.StatusCreated {
		t.Fatalf("pre-bootstrap app: status=%d body=%s", code, raw)
	}
	boot := postCommitBody(t, "a1", "c1", 0, nil, membersOf([2]string{"a1", "alice"}, [2]string{"b1", "bob"}), []byte("bootstrap"))
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", boot); code != http.StatusCreated {
		t.Fatalf("bootstrap: status=%d body=%s", code, raw)
	}
	// The pre-bootstrap poster's cursor was legitimate then; the founding
	// commit drops the cursors of every device it does not seat, so an
	// active non-member cannot stay a permanent pruning gate.
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_cursors WHERE room = 'r' AND device = 'c1'`); n != 0 {
		t.Fatalf("pre-bootstrap poster c1 kept a cursor past the founding commit: %d", n)
	}
	events := tableCount(t, r, `SELECT COUNT(*) FROM mls_events WHERE room = 'r'`)

	// c1 is policy-active but not a member: application and welcome are 403
	// not_a_member, nothing is stored, and no cursor appears.
	for _, body := range [][]byte{
		postEventBody(t, "c1", "x1", "application", 1, nil, nil, []byte("outsider")),
		postEventBody(t, "c1", "x2", "welcome", 1, nil, []string{"b1"}, []byte("outsider-welcome")),
	} {
		code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", body)
		if code != http.StatusForbidden || errField(t, raw) != "not_a_member" {
			t.Fatalf("outsider post: status=%d body=%s", code, raw)
		}
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_events WHERE room = 'r'`); n != events {
		t.Fatalf("outsider posts landed: %d events, want %d", n, events)
	}
	// Members still post, and the outsider's 403 did not leak an epoch (the
	// membership verdict runs before the CAS read: a wrong epoch is still 403).
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "c1", "x3", "application", 42, nil, nil, []byte("wrong-epoch-outsider"))); code != http.StatusForbidden || errField(t, raw) != "not_a_member" {
		t.Fatalf("outsider with wrong epoch must not get a 409 oracle: status=%d body=%s", code, raw)
	}
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "b1", "m1", "application", 1, nil, nil, []byte("member"))); code != http.StatusCreated {
		t.Fatalf("member app: status=%d body=%s", code, raw)
	}
	// Without a device store nothing changes (legacy contract).
	_, legacy := newTestRelay(t, testPolicy())
	if code, raw := doJSON(t, legacy, "POST", "/v2/rooms/r/events",
		postEventBody(t, "a1", "l1", "application", 0, nil, nil, []byte("legacy"))); code != http.StatusCreated {
		t.Fatalf("legacy relay app: status=%d body=%s", code, raw)
	}
}

func TestCommitIsExemptFromRoomByteCap(t *testing.T) {
	pol := testPolicy()
	pol.RoomBytesCap = 1 << 10 // 1 KiB
	_, srv := newTestRelay(t, pol)
	// a1 fills the room with unread (fresh, not TTL-stale) traffic: nothing
	// is prunable, so an application post over the cap is 413 …
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "a1", "c1", "application", 0, nil, nil, bytes.Repeat([]byte("a"), 900))); code != http.StatusCreated {
		t.Fatalf("seed: status=%d body=%s", code, raw)
	}
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "a1", "c2", "application", 0, nil, nil, bytes.Repeat([]byte("b"), 300))); code != http.StatusRequestEntityTooLarge || errField(t, raw) != "room_bytes_cap" {
		t.Fatalf("app over cap: status=%d body=%s", code, raw)
	}
	// … but the commit that would evict the non-acking reader goes through.
	code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "a1", "c3", "commit", 0, nil, nil, bytes.Repeat([]byte("c"), 300)))
	if code != http.StatusCreated {
		t.Fatalf("commit over cap must be exempt: status=%d body=%s", code, raw)
	}
	if resp := decodeEventResponse(t, raw); resp.Epoch != 1 || resp.Seq != 2 {
		t.Fatalf("commit response = %+v, want epoch 1 seq 2", resp)
	}
	// Welcomes are not exempt: they do not advance the epoch, so nothing
	// bounds their number.
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "a1", "c4", "welcome", 1, nil, []string{"b1"}, bytes.Repeat([]byte("w"), 300))); code != http.StatusRequestEntityTooLarge {
		t.Fatalf("welcome over cap: status=%d body=%s", code, raw)
	}
}

func TestCommitActorMustMatchDevicePolicy(t *testing.T) {
	r, srv, st, _, first := newEnforcedRelay(t, testPolicy())
	enrollDevice(t, st, first, "a1", "alice")
	enrollDevice(t, st, first, "b1", "bob")
	enrollDevice(t, st, first, "c1", "carol")

	// Bootstrap: a founding entry that relabels b1 (bob) as alice is refused.
	bad := postCommitBody(t, "a1", "c1", 0, nil, membersOf([2]string{"a1", "alice"}, [2]string{"b1", "alice"}), []byte("relabel-bootstrap"))
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", bad); code != http.StatusForbidden || errField(t, raw) != "commit_actor_mismatch" {
		t.Fatalf("relabelled bootstrap: status=%d body=%s", code, raw)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_members WHERE room = 'r'`); n != 0 {
		t.Fatalf("rejected bootstrap seeded membership: %d", n)
	}
	boot := postCommitBody(t, "a1", "c2", 0, nil, membersOf([2]string{"a1", "alice"}), []byte("bootstrap"))
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", boot); code != http.StatusCreated {
		t.Fatalf("bootstrap: status=%d body=%s", code, raw)
	}
	// Add: carol's device smuggled in under the roster actor "alice" is
	// refused with the mismatch (not the roster error — the actor the
	// client wrote IS on the roster; the device's real actor is not).
	smuggle := postCommitBody(t, "a1", "c3", 1, nil, membersOf([2]string{"a1", "alice"}, [2]string{"c1", "alice"}), []byte("smuggle-c1"))
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", smuggle); code != http.StatusForbidden || errField(t, raw) != "commit_actor_mismatch" {
		t.Fatalf("smuggled add: status=%d body=%s", code, raw)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_members WHERE room = 'r' AND device = 'c1'`); n != 0 {
		t.Fatalf("smuggled c1 became a member: %d", n)
	}
	// The honest shape is still the roster verdict.
	honest := postCommitBody(t, "a1", "c4", 1, nil, membersOf([2]string{"a1", "alice"}, [2]string{"c1", "carol"}), []byte("honest-c1"))
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", honest); code != http.StatusForbidden || errField(t, raw) != "commit_actor_not_in_roster" {
		t.Fatalf("honest add off roster: status=%d body=%s", code, raw)
	}
}

func TestEventColumnsAreShapeBounded(t *testing.T) {
	_, srv := newTestRelay(t, testPolicy())
	post := func(mutate func(m map[string]any)) (int, []byte) {
		m := map[string]any{"device": "a1", "client_id": "c1", "kind": "application", "epoch": 0, "bytes": []byte("x")}
		mutate(m)
		raw, err := json.Marshal(m)
		if err != nil {
			t.Fatal(err)
		}
		return doJSON(t, srv, "POST", "/v2/rooms/r/events", raw)
	}
	cases := []struct {
		name   string
		mutate func(m map[string]any)
		detail string
		code   string
	}{
		{"client_id too long", func(m map[string]any) { m["client_id"] = strings.Repeat("c", maxIdentifierLen+1) }, "client_id", "bad_identifier"},
		{"client_id bad charset", func(m map[string]any) { m["client_id"] = "c/1" }, "client_id", "bad_identifier"},
		{"group_id too long", func(m map[string]any) { m["group_id"] = strings.Repeat("g", maxGroupIDLen+1) }, "group_id", "bad_identifier"},
		{"group_id bad charset", func(m map[string]any) { m["group_id"] = "g.1" }, "group_id", "bad_identifier"},
		{"too many targets", func(m map[string]any) {
			m["kind"] = "welcome"
			ts := make([]string, maxTargets+1)
			for i := range ts {
				ts[i] = "t" + strings.Repeat("x", i%10)
			}
			m["targets"] = ts
		}, "", "too_many_targets"},
		{"too many members", func(m map[string]any) {
			m["kind"] = "commit"
			ms := make([]map[string]string, maxMembers+1)
			for i := range ms {
				ms[i] = map[string]string{"device": "d" + strings.Repeat("x", i%10), "actor": "a"}
			}
			m["members"] = ms
		}, "", "too_many_members"},
	}
	for _, c := range cases {
		code, raw := post(c.mutate)
		if code != http.StatusBadRequest {
			t.Fatalf("%s: status=%d body=%s", c.name, code, raw)
		}
		e := decodeAPIError(t, raw)
		if e.Error != c.code || (c.detail != "" && e.Detail != c.detail) {
			t.Fatalf("%s: error=%+v want %s/%s", c.name, e, c.code, c.detail)
		}
	}
	// The boundaries themselves are accepted.
	if code, raw := post(func(m map[string]any) {
		m["client_id"] = strings.Repeat("c", maxIdentifierLen)
		m["group_id"] = strings.Repeat("g", maxGroupIDLen)
	}); code != http.StatusCreated {
		t.Fatalf("max-length client_id/group_id: status=%d body=%s", code, raw)
	}
}

func TestRoomPathMustBeIdentifier(t *testing.T) {
	_, srv := newTestRelay(t, testPolicy())
	for _, path := range []string{
		"/v2/rooms/bad%0Aroom/events?device=a1",
		"/v2/rooms/" + strings.Repeat("r", maxIdentifierLen+1) + "/events?device=a1",
		"/v2/rooms/r%C3%A4um/events?device=a1",
	} {
		for _, m := range []struct{ method, suffix string }{{"GET", ""}, {"POST", ""}} {
			code, raw := doJSON(t, srv, m.method, path+m.suffix, []byte(`{}`))
			if code != http.StatusBadRequest || errField(t, raw) != "bad_identifier" || decodeAPIError(t, raw).Detail != "room" {
				t.Fatalf("%s %s: status=%d body=%s", m.method, path, code, raw)
			}
		}
	}
	for _, path := range []string{
		"/v2/rooms/bad%0Aroom/keypackages?device=a1&consumer=b1",
		"/v2/rooms/bad%0Aroom/close?device=a1",
	} {
		code, raw := doJSON(t, srv, "POST", path, []byte(`{}`))
		if code != http.StatusBadRequest || decodeAPIError(t, raw).Detail != "room" {
			t.Fatalf("POST %s: status=%d body=%s", path, code, raw)
		}
		if strings.Contains(path, "keypackages") {
			code, raw = doJSON(t, srv, "GET", path, nil)
			if code != http.StatusBadRequest || decodeAPIError(t, raw).Detail != "room" {
				t.Fatalf("GET %s: status=%d body=%s", path, code, raw)
			}
		}
	}
}

func TestConsumeKeyPackageRequiresMembership(t *testing.T) {
	r, srv, st, _, first := newEnforcedRelay(t, testPolicy())
	enrollDevice(t, st, first, "a1", "alice")
	enrollDevice(t, st, first, "b1", "bob")
	enrollDevice(t, st, first, "c1", "carol")
	publish := func(device string, refs ...string) {
		pkgs := make([]keyPackageInput, 0, len(refs))
		for _, ref := range refs {
			pkgs = append(pkgs, keyPackageInput{Ref: ref, Bytes: []byte("pkg-" + ref)})
		}
		raw, _ := json.Marshal(keyPackagePost{Device: device, Packages: pkgs})
		if code, body := doJSON(t, srv, "POST", "/v2/rooms/r/keypackages", raw); code != http.StatusCreated {
			t.Fatalf("publish %s: status=%d body=%s", device, code, body)
		}
	}
	publish("b1", "k1", "k2", "k3")
	// Before the founding commit any active device may consume (bootstrap
	// needs the founder to fetch the invitees' packages).
	if code, raw := doJSON(t, srv, "GET", "/v2/rooms/r/keypackages?device=b1&consumer=a1", nil); code != http.StatusOK {
		t.Fatalf("founder consume pre-bootstrap: status=%d body=%s", code, raw)
	}
	boot := postCommitBody(t, "a1", "c1", 0, nil, membersOf([2]string{"a1", "alice"}, [2]string{"b1", "bob"}), []byte("bootstrap"))
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", boot); code != http.StatusCreated {
		t.Fatalf("bootstrap: status=%d body=%s", code, raw)
	}
	// c1 is active but not a member: it cannot drain b1's packages.
	if code, raw := doJSON(t, srv, "GET", "/v2/rooms/r/keypackages?device=b1&consumer=c1", nil); code != http.StatusForbidden || errField(t, raw) != "not_a_member" {
		t.Fatalf("outsider consume: status=%d body=%s", code, raw)
	}
	// A member still can, and exactly the two remaining packages are live.
	if code, raw := doJSON(t, srv, "GET", "/v2/rooms/r/keypackages?device=b1&consumer=a1", nil); code != http.StatusOK {
		t.Fatalf("member consume: status=%d body=%s", code, raw)
	}
	// Revoked after the handler's bind: the in-transaction policy re-check
	// is what the store sees (simulated by revoking before the request — the
	// handler bind already refuses, so drive the store directly).
	revokeDevice(t, st, "a1")
	if _, err := r.consumeKeyPackage("r", "b1", "a1"); err == nil {
		t.Fatal("revoked consumer must be refused inside the transaction")
	} else if _, ok := err.(deviceNotAllowed); !ok {
		t.Fatalf("revoked consumer error = %v, want deviceNotAllowed", err)
	}
}

func TestJWKSReloadIsThrottledFromLastAttemptAndFetchedOutsideLock(t *testing.T) {
	iss := newTestIssuer(t)
	v := iss.verifier()
	base := time.Now()
	v.now = func() time.Time { return base }
	good := iss.mint("s", nil)

	key2, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	token2 := signES256(t, key2, map[string]any{"alg": "ES256", "kid": "rotated"}, baseClaims("s"))

	// Source broken when the first unknown kid arrives after the gap: the
	// attempt fails and is recorded.
	v.now = func() time.Time { return base.Add(2 * time.Minute) }
	if err := os.WriteFile(iss.jwksPath, []byte("not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := v.verify(token2); err == nil {
		t.Fatal("unknown kid with a broken source must fail")
	}
	// The source is repaired with the rotated key, but a second unknown-kid
	// request ten seconds later must NOT refetch (G-M5: throttle counts from
	// the attempt, not from the last success).
	iss.extra = append(iss.extra, ecJWK("rotated", &key2.PublicKey))
	iss.writeJWKS()
	v.now = func() time.Time { return base.Add(2*time.Minute + 10*time.Second) }
	if _, err := v.verify(token2); err == nil {
		t.Fatal("second unknown kid within the gap of a failed attempt must be throttled")
	}
	// Known keys verify throughout.
	if _, err := v.verify(good); err != nil {
		t.Fatalf("known kid during throttle: %v", err)
	}
	// After the gap the reload happens and the rotated key is admitted.
	v.now = func() time.Time { return base.Add(4 * time.Minute) }
	if _, err := v.verify(token2); err != nil {
		t.Fatalf("rotated key after the gap: %v", err)
	}
	// L1: an emptied JWKS must not replace the working cache.
	if err := os.WriteFile(iss.jwksPath, []byte(`{"keys":[]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	key3, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	token3 := signES256(t, key3, map[string]any{"alg": "ES256", "kid": "third"}, baseClaims("s"))
	v.now = func() time.Time { return base.Add(6 * time.Minute) }
	if _, err := v.verify(token3); err == nil {
		t.Fatal("unknown kid against an empty JWKS must fail")
	}
	if _, err := v.verify(good); err != nil {
		t.Fatalf("empty JWKS reload replaced the working cache: %v", err)
	}
	if _, err := v.verify(token2); err != nil {
		t.Fatalf("empty JWKS reload dropped the rotated key: %v", err)
	}
}
