// Lobby key-package and pending-Welcome tests (#380 P5-1, lobby.go). Every
// test drives the real routes() mux over httptest with a throwaway SQLite
// file. Pinned: publish 201/200 idempotency, ref conflict 409, the live cap
// (8) with `live` in every success body, status, expiry sweep; consume for a
// room that does not exist yet (no room row created, consumed_room recorded),
// member-only consume for a seeded room, 410 on a closed room, one-shot
// draining to 404, the policy gate (403 device_not_allowed) and the JWT
// subject binding (403 device_subject_mismatch) on all five routes; and the
// welcomes listing: whole-identifier target match, closed rooms excluded,
// disappearing once the device acks past the Welcome.
package main

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

func lobbyPublishBody(t *testing.T, device string, refs ...string) []byte {
	t.Helper()
	pkgs := make([]keyPackageInput, 0, len(refs))
	for _, ref := range refs {
		pkgs = append(pkgs, keyPackageInput{Ref: ref, Bytes: []byte("pkg-" + ref)})
	}
	raw, err := json.Marshal(keyPackagePost{Device: device, Packages: pkgs})
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func decodeKeyPackages(t *testing.T, raw []byte) keyPackagesResponse {
	t.Helper()
	var resp keyPackagesResponse
	if err := json.Unmarshal(raw, &resp); err != nil {
		t.Fatalf("response is not a keyPackagesResponse: %v (%s)", err, raw)
	}
	return resp
}

func decodeStoredKeyPackage(t *testing.T, raw []byte) storedKeyPackage {
	t.Helper()
	var pkg storedKeyPackage
	if err := json.Unmarshal(raw, &pkg); err != nil {
		t.Fatalf("response is not a storedKeyPackage: %v (%s)", err, raw)
	}
	return pkg
}

func decodeLobbyStatus(t *testing.T, raw []byte) lobbyStatusResponse {
	t.Helper()
	var st lobbyStatusResponse
	if err := json.Unmarshal(raw, &st); err != nil {
		t.Fatalf("response is not a lobbyStatusResponse: %v (%s)", err, raw)
	}
	return st
}

func decodeWelcomes(t *testing.T, raw []byte) []pendingWelcome {
	t.Helper()
	var resp welcomesResponse
	if err := json.Unmarshal(raw, &resp); err != nil {
		t.Fatalf("response is not a welcomesResponse: %v (%s)", err, raw)
	}
	if resp.Welcomes == nil {
		t.Fatalf("welcomes must be a JSON array, never null: %s", raw)
	}
	return resp.Welcomes
}

// TestLobbyPolicyDefaults pins the #380 owner decisions: D2 = 8 lobby
// packages / 30-day TTL, D3 = RoomsMaxPerDevice 32.
func TestLobbyPolicyDefaults(t *testing.T) {
	p := defaultPolicy()
	if p.RoomsMaxPerDevice != 32 {
		t.Fatalf("RoomsMaxPerDevice = %d, want 32 (#380 D3)", p.RoomsMaxPerDevice)
	}
	if p.LobbyKeyPackagesMaxPerDevice != 8 {
		t.Fatalf("LobbyKeyPackagesMaxPerDevice = %d, want 8 (#380 D2)", p.LobbyKeyPackagesMaxPerDevice)
	}
	if p.LobbyKeyPackageTTLSeconds != 30*24*60*60 {
		t.Fatalf("LobbyKeyPackageTTLSeconds = %d, want 30 days (#380 D2)", p.LobbyKeyPackageTTLSeconds)
	}
	// The lobby pool is deliberately looser than the per-room one.
	if p.LobbyKeyPackagesMaxPerDevice <= p.KeyPackagesMaxPerDevice || p.LobbyKeyPackageTTLSeconds <= p.KeyPackageTTLSeconds {
		t.Fatalf("lobby bounds must exceed the room bounds: %+v", p)
	}
}

func TestLobbyPublishStatusAndLimit(t *testing.T) {
	r, srv := newTestRelay(t, testPolicy())

	code, raw := doJSON(t, srv, "POST", "/v2/lobby/keypackages", lobbyPublishBody(t, "a1", "k1", "k2", "k3"))
	if code != http.StatusCreated {
		t.Fatalf("publish: status=%d body=%s", code, raw)
	}
	if got := decodeKeyPackages(t, raw); got.Stored != 3 || got.Duplicates != 0 || got.Live != 3 {
		t.Fatalf("publish response = %+v, want stored=3 duplicates=0 live=3", got)
	}
	// Byte-identical replay: 200, counted as duplicates, live unchanged.
	code, raw = doJSON(t, srv, "POST", "/v2/lobby/keypackages", lobbyPublishBody(t, "a1", "k1", "k2", "k3"))
	if code != http.StatusOK {
		t.Fatalf("replay: status=%d body=%s", code, raw)
	}
	if got := decodeKeyPackages(t, raw); got.Stored != 0 || got.Duplicates != 3 || got.Live != 3 {
		t.Fatalf("replay response = %+v, want stored=0 duplicates=3 live=3", got)
	}
	// Different bytes under a stored ref: 409, nothing stored.
	conflict, _ := json.Marshal(keyPackagePost{Device: "a1", Packages: []keyPackageInput{{Ref: "k1", Bytes: []byte("other")}, {Ref: "k4", Bytes: []byte("pkg-k4")}}})
	if code, raw := doJSON(t, srv, "POST", "/v2/lobby/keypackages", conflict); code != http.StatusConflict || errField(t, raw) != "key_package_ref_conflict" {
		t.Fatalf("ref conflict: status=%d body=%s", code, raw)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_lobby_keypackages WHERE device = 'a1'`); n != 3 {
		t.Fatalf("conflict batch left rows behind: %d", n)
	}

	code, raw = doJSON(t, srv, "GET", "/v2/lobby/status?device=a1", nil)
	if code != http.StatusOK {
		t.Fatalf("status: status=%d body=%s", code, raw)
	}
	if st := decodeLobbyStatus(t, raw); st.Device != "a1" || st.Live != 3 || st.Max != 8 || st.TTLSeconds != 30*24*60*60 {
		t.Fatalf("status = %+v, want device=a1 live=3 max=8 ttl=30d", st)
	}
	if code, raw := doJSON(t, srv, "GET", "/v2/lobby/status?device=nobody", nil); code != http.StatusOK || decodeLobbyStatus(t, raw).Live != 0 {
		t.Fatalf("status of a device without packages: status=%d body=%s", code, raw)
	}

	// Up to the cap (8) is fine; the ninth live package is refused with the
	// live/max pair and the batch is not partially applied.
	code, raw = doJSON(t, srv, "POST", "/v2/lobby/keypackages", lobbyPublishBody(t, "a1", "k4", "k5", "k6", "k7", "k8"))
	if code != http.StatusCreated || decodeKeyPackages(t, raw).Live != 8 {
		t.Fatalf("fill to cap: status=%d body=%s", code, raw)
	}
	code, raw = doJSON(t, srv, "POST", "/v2/lobby/keypackages", lobbyPublishBody(t, "a1", "k9"))
	if code != http.StatusConflict {
		t.Fatalf("ninth package: status=%d body=%s", code, raw)
	}
	if e := decodeAPIError(t, raw); e.Error != "key_package_limit" || e.Live != 8 || e.Max != 8 {
		t.Fatalf("limit error = %+v, want key_package_limit live=8 max=8", e)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_lobby_keypackages WHERE device = 'a1'`); n != 8 {
		t.Fatalf("refused batch changed the table: %d rows", n)
	}
	// Another device has its own pool.
	if code, raw := doJSON(t, srv, "POST", "/v2/lobby/keypackages", lobbyPublishBody(t, "b1", "k1")); code != http.StatusCreated || decodeKeyPackages(t, raw).Live != 1 {
		t.Fatalf("other device: status=%d body=%s", code, raw)
	}

	// Expiry: an expired row is swept by the next lobby write/status and no
	// longer counts, so the ninth package now fits.
	if _, err := r.db.Exec(`UPDATE mls_lobby_keypackages SET expires_at = 1 WHERE device = 'a1' AND ref = 'k1'`); err != nil {
		t.Fatal(err)
	}
	if code, raw := doJSON(t, srv, "GET", "/v2/lobby/status?device=a1", nil); code != http.StatusOK || decodeLobbyStatus(t, raw).Live != 7 {
		t.Fatalf("status after expiry: status=%d body=%s", code, raw)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_lobby_keypackages WHERE device = 'a1' AND ref = 'k1'`); n != 0 {
		t.Fatalf("expired row not swept: %d", n)
	}
	if code, raw := doJSON(t, srv, "POST", "/v2/lobby/keypackages", lobbyPublishBody(t, "a1", "k9")); code != http.StatusCreated || decodeKeyPackages(t, raw).Live != 8 {
		t.Fatalf("publish after expiry: status=%d body=%s", code, raw)
	}

	// The room route carries `live` too (shared response shape).
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/keypackages", lobbyPublishBody(t, "a1", "k1")); code != http.StatusCreated || decodeKeyPackages(t, raw).Live != 1 {
		t.Fatalf("room publish live: status=%d body=%s", code, raw)
	}

	// Validation parity with the room route.
	bad := []struct {
		name, method, path string
		body               []byte
		code               string
	}{
		{"no device", "POST", "/v2/lobby/keypackages", []byte(`{"device":"","packages":[{"ref":"x","bytes":"AQ=="}]}`), "device_required"},
		{"bad device", "POST", "/v2/lobby/keypackages", []byte(`{"device":"a.1","packages":[{"ref":"x","bytes":"AQ=="}]}`), "bad_identifier"},
		{"no packages", "POST", "/v2/lobby/keypackages", []byte(`{"device":"a1","packages":[]}`), "packages_required"},
		{"empty ref", "POST", "/v2/lobby/keypackages", []byte(`{"device":"a1","packages":[{"ref":"","bytes":"AQ=="}]}`), "bad_package"},
		{"duplicate key", "POST", "/v2/lobby/keypackages", []byte(`{"device":"a1","device":"a1","packages":[{"ref":"x","bytes":"AQ=="}]}`), "bad_request"},
		{"unknown field", "POST", "/v2/lobby/keypackages", []byte(`{"device":"a1","room":"r","packages":[{"ref":"x","bytes":"AQ=="}]}`), "bad_request"},
		{"status no device", "GET", "/v2/lobby/status", nil, "device_required"},
		{"status bad device", "GET", "/v2/lobby/status?device=a%2F1", nil, "bad_identifier"},
		{"welcomes no device", "GET", "/v2/lobby/welcomes", nil, "device_required"},
		{"welcomes bad device", "GET", "/v2/lobby/welcomes?device=a.1", nil, "bad_identifier"},
		{"consume missing room", "GET", "/v2/lobby/keypackages?device=a1&consumer=b1", nil, "device_consumer_and_room_required"},
		{"consume bad room", "GET", "/v2/lobby/keypackages?device=a1&consumer=b1&room=r%0A", nil, "bad_identifier"},
		{"consume bad consumer", "GET", "/v2/lobby/keypackages?device=a1&consumer=b.1&room=r", nil, "bad_identifier"},
	}
	for _, b := range bad {
		if code, raw := doJSON(t, srv, b.method, b.path, b.body); code != http.StatusBadRequest || errField(t, raw) != b.code {
			t.Fatalf("%s: status=%d body=%s, want 400 %s", b.name, code, raw, b.code)
		}
	}
}

// TestLobbyConsumeRoomRules drives the consume route under membership
// enforcement: a room that does not exist yet admits any active consumer and
// gets no row; a seeded room admits members only; a closed room is 410; each
// package is spent exactly once, oldest first, down to 404.
func TestLobbyConsumeRoomRules(t *testing.T) {
	r, srv, st, _, first := newEnforcedRelay(t, testPolicy())
	enrollDevice(t, st, first, "a1", "alice")
	enrollDevice(t, st, first, "b1", "bob")
	enrollDevice(t, st, first, "c1", "carol")

	if code, raw := doJSON(t, srv, "POST", "/v2/lobby/keypackages", lobbyPublishBody(t, "b1", "k1", "k2", "k3")); code != http.StatusCreated {
		t.Fatalf("publish b1: status=%d body=%s", code, raw)
	}
	// Unknown (never enrolled) device: 403 device_not_allowed on both writes.
	if code, raw := doJSON(t, srv, "POST", "/v2/lobby/keypackages", lobbyPublishBody(t, "ghost", "g1")); code != http.StatusForbidden || errField(t, raw) != "device_not_allowed" {
		t.Fatalf("ghost publish: status=%d body=%s", code, raw)
	}
	if code, raw := doJSON(t, srv, "GET", "/v2/lobby/keypackages?device=b1&consumer=ghost&room=fresh", nil); code != http.StatusForbidden || errField(t, raw) != "device_not_allowed" {
		t.Fatalf("ghost consume: status=%d body=%s", code, raw)
	}

	// The room does not exist: the consumer is about to found it. No room row
	// appears, the package is marked with consumer and room.
	code, raw := doJSON(t, srv, "GET", "/v2/lobby/keypackages?device=b1&consumer=a1&room=fresh", nil)
	if code != http.StatusOK {
		t.Fatalf("consume for a new room: status=%d body=%s", code, raw)
	}
	if pkg := decodeStoredKeyPackage(t, raw); pkg.Ref != "k1" || string(pkg.Bytes) != "pkg-k1" || pkg.ExpiresAt == 0 {
		t.Fatalf("consumed package = %+v, want k1/pkg-k1 with expires_at", pkg)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_rooms WHERE room = 'fresh'`); n != 0 {
		t.Fatalf("lobby consume must not create the room row: %d", n)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_lobby_keypackages WHERE device = 'b1' AND ref = 'k1' AND consumed_by = 'a1' AND consumed_room = 'fresh'`); n != 1 {
		t.Fatalf("consumed_by/consumed_room not recorded")
	}
	if code, raw := doJSON(t, srv, "GET", "/v2/lobby/status?device=b1", nil); code != http.StatusOK || decodeLobbyStatus(t, raw).Live != 2 {
		t.Fatalf("status after one consume: status=%d body=%s", code, raw)
	}

	// Seed room r with a1 and b1; c1 is active but not a member.
	boot := postCommitBody(t, "a1", "c1", 0, nil, membersOf([2]string{"a1", "alice"}, [2]string{"b1", "bob"}), []byte("bootstrap"))
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", boot); code != http.StatusCreated {
		t.Fatalf("bootstrap: status=%d body=%s", code, raw)
	}
	if code, raw := doJSON(t, srv, "GET", "/v2/lobby/keypackages?device=b1&consumer=c1&room=r", nil); code != http.StatusForbidden || errField(t, raw) != "not_a_member" {
		t.Fatalf("outsider consume for a seeded room: status=%d body=%s", code, raw)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_lobby_keypackages WHERE device = 'b1' AND consumed_by IS NULL`); n != 2 {
		t.Fatalf("refused consume spent a package: %d live", n)
	}
	// A member consumes: oldest first, one shot each, then 404.
	code, raw = doJSON(t, srv, "GET", "/v2/lobby/keypackages?device=b1&consumer=a1&room=r", nil)
	if code != http.StatusOK || decodeStoredKeyPackage(t, raw).Ref != "k2" {
		t.Fatalf("member consume #1: status=%d body=%s", code, raw)
	}
	code, raw = doJSON(t, srv, "GET", "/v2/lobby/keypackages?device=b1&consumer=a1&room=r", nil)
	if code != http.StatusOK || decodeStoredKeyPackage(t, raw).Ref != "k3" {
		t.Fatalf("member consume #2: status=%d body=%s", code, raw)
	}
	if code, raw := doJSON(t, srv, "GET", "/v2/lobby/keypackages?device=b1&consumer=a1&room=r", nil); code != http.StatusNotFound || errField(t, raw) != "no_live_key_package" {
		t.Fatalf("drained: status=%d body=%s", code, raw)
	}
	// Consumed rows are kept (audit) until they expire.
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_lobby_keypackages WHERE device = 'b1' AND consumed_by = 'a1' AND consumed_room = 'r'`); n != 2 {
		t.Fatalf("consumed rows for r = %d, want 2", n)
	}
	// Closed room: 410 before any package lookup.
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/close?device=a1", nil); code != http.StatusOK {
		t.Fatalf("close r: status=%d body=%s", code, raw)
	}
	if code, raw := doJSON(t, srv, "POST", "/v2/lobby/keypackages", lobbyPublishBody(t, "b1", "k4")); code != http.StatusCreated {
		t.Fatalf("republish b1: status=%d body=%s", code, raw)
	}
	if code, raw := doJSON(t, srv, "GET", "/v2/lobby/keypackages?device=b1&consumer=a1&room=r", nil); code != http.StatusGone || errField(t, raw) != "room_closed" {
		t.Fatalf("consume for a closed room: status=%d body=%s", code, raw)
	}
	// Lobby publishing is room-independent: closing r changes nothing there.
	if code, raw := doJSON(t, srv, "GET", "/v2/lobby/keypackages?device=b1&consumer=a1&room=another", nil); code != http.StatusOK || decodeStoredKeyPackage(t, raw).Ref != "k4" {
		t.Fatalf("consume for another new room: status=%d body=%s", code, raw)
	}

	// Revoked after the handler's bind: the in-transaction re-check refuses.
	revokeDevice(t, st, "a1")
	if _, err := r.consumeLobbyKeyPackage("b1", "a1", "x"); err == nil {
		t.Fatal("revoked consumer must be refused inside the transaction")
	} else if _, ok := err.(deviceNotAllowed); !ok {
		t.Fatalf("revoked consumer error = %v, want deviceNotAllowed", err)
	}
	if _, err := r.postLobbyKeyPackages("a1", []keyPackageInput{{Ref: "z", Bytes: []byte("z")}}); err == nil {
		t.Fatal("revoked publisher must be refused inside the transaction")
	} else if _, ok := err.(deviceNotAllowed); !ok {
		t.Fatalf("revoked publisher error = %v, want deviceNotAllowed", err)
	}
}

// TestLobbyRoutesBindTheCaller mirrors TestAuthRequiredOnEveryContractRoute
// for the four lobby routes: no token → bare 401; a token whose subject does
// not own the device the request acts as → one indistinguishable 403. For
// consume the bound identity is the consumer, not the target device.
func TestLobbyRoutesBindTheCaller(t *testing.T) {
	_, srv, st, first, iss := newAuthedRelay(t, testPolicy())
	enrollDevice(t, st, first, "a1", "alice")
	enrollDevice(t, st, first, "b1", "bob")
	alice := iss.mint("subject-alice", nil)
	bob := iss.mint("subject-bob", nil)

	routes := []struct {
		name, method, path string
		body               []byte
	}{
		{"publish", "POST", "/v2/lobby/keypackages", lobbyPublishBody(t, "a1", "k1")},
		{"consume", "GET", "/v2/lobby/keypackages?device=b1&consumer=a1&room=r", nil},
		{"status", "GET", "/v2/lobby/status?device=a1", nil},
		{"welcomes", "GET", "/v2/lobby/welcomes?device=a1", nil},
		{"delete", "DELETE", "/v2/lobby/keypackages?device=a1", nil},
	}
	for _, rt := range routes {
		code, raw := doJSON(t, srv, rt.method, rt.path, rt.body)
		if code != http.StatusUnauthorized || errField(t, raw) != "unauthorized" {
			t.Fatalf("%s without token: status=%d body=%s", rt.name, code, raw)
		}
		code, raw = doAuth(t, srv, rt.method, rt.path, rt.body, bob)
		if code != http.StatusForbidden || errField(t, raw) != "device_subject_mismatch" {
			t.Fatalf("%s as a1 with bob's token: status=%d body=%s", rt.name, code, raw)
		}
		if e := decodeAPIError(t, raw); e.Detail != "" {
			t.Fatalf("%s: 403 body must not say which check failed: %s", rt.name, raw)
		}
	}
	// Unknown device under a valid token: the same 403, no detail.
	ghost := []struct {
		name, method, path string
		body               []byte
	}{
		{"publish", "POST", "/v2/lobby/keypackages", lobbyPublishBody(t, "ghost", "k1")},
		{"consume", "GET", "/v2/lobby/keypackages?device=b1&consumer=ghost&room=r", nil},
		{"status", "GET", "/v2/lobby/status?device=ghost", nil},
		{"welcomes", "GET", "/v2/lobby/welcomes?device=ghost", nil},
		{"delete", "DELETE", "/v2/lobby/keypackages?device=ghost", nil},
	}
	for _, rt := range ghost {
		code, raw := doAuth(t, srv, rt.method, rt.path, rt.body, alice)
		if code != http.StatusForbidden || errField(t, raw) != "device_subject_mismatch" || decodeAPIError(t, raw).Detail != "" {
			t.Fatalf("%s as ghost with alice's token: status=%d body=%s", rt.name, code, raw)
		}
	}
	// Nothing landed from the denied calls.
	if code, raw := doAuth(t, srv, "GET", "/v2/lobby/status?device=a1", nil, alice); code != http.StatusOK || decodeLobbyStatus(t, raw).Live != 0 {
		t.Fatalf("status as a1: status=%d body=%s", code, raw)
	}

	// The right subject: alice publishes as a1, bob consumes as b1 for a room
	// he is about to found — the target device is not the bound identity.
	if code, raw := doAuth(t, srv, "POST", "/v2/lobby/keypackages", lobbyPublishBody(t, "a1", "k1"), alice); code != http.StatusCreated {
		t.Fatalf("publish as a1: status=%d body=%s", code, raw)
	}
	if code, raw := doAuth(t, srv, "GET", "/v2/lobby/keypackages?device=a1&consumer=b1&room=r", nil, bob); code != http.StatusOK || decodeStoredKeyPackage(t, raw).Ref != "k1" {
		t.Fatalf("b1 consuming a1's lobby package: status=%d body=%s", code, raw)
	}
	if code, raw := doAuth(t, srv, "GET", "/v2/lobby/welcomes?device=a1", nil, alice); code != http.StatusOK || len(decodeWelcomes(t, raw)) != 0 {
		t.Fatalf("welcomes as a1: status=%d body=%s", code, raw)
	}
}

// TestLobbyWelcomesListing: after a founding commit and a Welcome targeting
// x1 in room R, GET /v2/lobby/welcomes?device=x1 lists {R, seq}; a Welcome
// for another device is not listed, neither is one in a closed room; the
// match is on the whole identifier; once x1 acks past the Welcome it is gone.
func TestLobbyWelcomesListing(t *testing.T) {
	_, srv := newTestRelay(t, testPolicy())
	found := func(room string, targets ...string) int64 {
		t.Helper()
		if code, raw := doJSON(t, srv, "POST", "/v2/rooms/"+room+"/events",
			postEventBody(t, "a1", "found", "commit", 0, nil, nil, []byte("commit-"+room))); code != http.StatusCreated {
			t.Fatalf("found %s: status=%d body=%s", room, code, raw)
		}
		code, raw := doJSON(t, srv, "POST", "/v2/rooms/"+room+"/events",
			postEventBody(t, "a1", "welcome", "welcome", 1, nil, targets, []byte("welcome-"+room)))
		if code != http.StatusCreated {
			t.Fatalf("welcome %s: status=%d body=%s", room, code, raw)
		}
		return decodeEventResponse(t, raw).Seq
	}
	// x1 published a lobby package that a1 consumed for R before founding it:
	// the listing names that package so x1 keeps its secret until it joins.
	if code, raw := doJSON(t, srv, "POST", "/v2/lobby/keypackages", lobbyPublishBody(t, "x1", "kx1", "kx2")); code != http.StatusCreated {
		t.Fatalf("publish x1: status=%d body=%s", code, raw)
	}
	if code, raw := doJSON(t, srv, "GET", "/v2/lobby/keypackages?device=x1&consumer=a1&room=R", nil); code != http.StatusOK {
		t.Fatalf("consume x1 for R: status=%d body=%s", code, raw)
	}
	seqR := found("R", "x1")
	seqR2 := found("R2", "y1", "x_1")
	found("R3", "x1")
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/R3/close?device=a1", nil); code != http.StatusOK {
		t.Fatalf("close R3: status=%d body=%s", code, raw)
	}

	code, raw := doJSON(t, srv, "GET", "/v2/lobby/welcomes?device=x1", nil)
	if code != http.StatusOK {
		t.Fatalf("welcomes x1: status=%d body=%s", code, raw)
	}
	got := decodeWelcomes(t, raw)
	if len(got) != 1 || got[0].Room != "R" || got[0].Seq != seqR || got[0].Epoch != 1 || got[0].CreatedAt == 0 {
		t.Fatalf("welcomes x1 = %+v, want exactly {R, seq %d, epoch 1, created_at>0}", got, seqR)
	}
	if got[0].KeyPackageRef != "kx1" {
		t.Fatalf("welcomes x1 key_package_ref = %q, want kx1 (the lobby package a1 consumed for R)", got[0].KeyPackageRef)
	}
	if !strings.Contains(string(raw), `"key_package_ref":"kx1"`) {
		t.Fatalf("welcomes x1 wire = %s, want key_package_ref kx1", raw)
	}
	if code, raw := doJSON(t, srv, "GET", "/v2/lobby/welcomes?device=y1", nil); code != http.StatusOK {
		t.Fatalf("welcomes y1: status=%d body=%s", code, raw)
	} else if got := decodeWelcomes(t, raw); len(got) != 1 || got[0].Room != "R2" || got[0].Seq != seqR2 || got[0].KeyPackageRef != "" {
		t.Fatalf("welcomes y1 = %+v, want exactly {R2, seq %d, no key_package_ref}", got, seqR2)
	}
	// Whole-identifier match: substrings and LIKE-wildcard look-alikes miss.
	for _, dev := range []string{"x", "1", "x1-", "xz1", "y"} {
		if code, raw := doJSON(t, srv, "GET", "/v2/lobby/welcomes?device="+dev, nil); code != http.StatusOK || len(decodeWelcomes(t, raw)) != 0 {
			t.Fatalf("welcomes %s: status=%d body=%s, want empty", dev, code, raw)
		}
	}
	if code, raw := doJSON(t, srv, "GET", "/v2/lobby/welcomes?device=x_1", nil); code != http.StatusOK || len(decodeWelcomes(t, raw)) != 1 {
		t.Fatalf("welcomes x_1: status=%d body=%s, want R2", code, raw)
	}

	// Reading alone does not clear it (M2: reads never move the cursor).
	if code, raw := doJSON(t, srv, "GET", "/v2/rooms/R/events?device=x1", nil); code != http.StatusOK {
		t.Fatalf("x1 reads R: status=%d body=%s", code, raw)
	} else if ev := decodeEventsResponse(t, raw).Events; len(ev) != 2 || ev[1].Kind != "welcome" {
		t.Fatalf("x1 must see the commit and its Welcome: %+v", ev)
	}
	if code, raw := doJSON(t, srv, "GET", "/v2/lobby/welcomes?device=x1", nil); code != http.StatusOK || len(decodeWelcomes(t, raw)) != 1 {
		t.Fatalf("welcomes x1 after a plain read: status=%d body=%s, want still listed", code, raw)
	}
	// An ack below the Welcome keeps it listed; acking past it clears it.
	if code, raw := doJSON(t, srv, "GET", "/v2/rooms/R/events?device=x1&ack=1", nil); code != http.StatusOK {
		t.Fatalf("x1 acks 1: status=%d body=%s", code, raw)
	}
	if code, raw := doJSON(t, srv, "GET", "/v2/lobby/welcomes?device=x1", nil); code != http.StatusOK || len(decodeWelcomes(t, raw)) != 1 {
		t.Fatalf("welcomes x1 after ack below the Welcome: status=%d body=%s, want still listed", code, raw)
	}
	getAck(t, srv, "R", "x1")
	if code, raw := doJSON(t, srv, "GET", "/v2/lobby/welcomes?device=x1", nil); code != http.StatusOK || len(decodeWelcomes(t, raw)) != 0 {
		t.Fatalf("welcomes x1 after ack: status=%d body=%s, want empty", code, raw)
	}
	// y1 is untouched by x1's ack.
	if code, raw := doJSON(t, srv, "GET", "/v2/lobby/welcomes?device=y1", nil); code != http.StatusOK || len(decodeWelcomes(t, raw)) != 1 {
		t.Fatalf("welcomes y1 after x1's ack: status=%d body=%s", code, raw)
	}
}

// TestLobbyDeleteWithdrawsUnconsumedPackages (#389): DELETE removes only the
// caller's unconsumed rows (consumed ones keep consumed_room for the Welcome
// bookkeeping), another device's pool is untouched, a repeat is 200 deleted=0,
// ?device= is required and validated, and the pool can be refilled afterwards.
func TestLobbyDeleteWithdrawsUnconsumedPackages(t *testing.T) {
	r, srv := newTestRelay(t, testPolicy())
	if code, raw := doJSON(t, srv, "POST", "/v2/lobby/keypackages", lobbyPublishBody(t, "a1", "k1", "k2", "k3")); code != http.StatusCreated {
		t.Fatalf("publish a1: status=%d body=%s", code, raw)
	}
	if code, raw := doJSON(t, srv, "POST", "/v2/lobby/keypackages", lobbyPublishBody(t, "b1", "m1")); code != http.StatusCreated {
		t.Fatalf("publish b1: status=%d body=%s", code, raw)
	}
	if code, raw := doJSON(t, srv, "GET", "/v2/lobby/keypackages?device=a1&consumer=b1&room=fresh", nil); code != http.StatusOK {
		t.Fatalf("consume one of a1: status=%d body=%s", code, raw)
	}

	code, raw := doJSON(t, srv, "DELETE", "/v2/lobby/keypackages?device=a1", nil)
	if code != http.StatusOK {
		t.Fatalf("delete: status=%d body=%s", code, raw)
	}
	var got lobbyDeleteResponse
	if err := json.Unmarshal(raw, &got); err != nil || got.Device != "a1" || got.Deleted != 2 {
		t.Fatalf("delete response = %+v (%v), want device=a1 deleted=2", got, err)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_lobby_keypackages WHERE device = 'a1' AND consumed_by IS NULL`); n != 0 {
		t.Fatalf("unconsumed a1 rows left: %d", n)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_lobby_keypackages WHERE device = 'a1' AND consumed_room = 'fresh'`); n != 1 {
		t.Fatalf("the consumed row must stay for the Welcome bookkeeping: %d", n)
	}
	if code, raw := doJSON(t, srv, "GET", "/v2/lobby/status?device=b1", nil); code != http.StatusOK || decodeLobbyStatus(t, raw).Live != 1 {
		t.Fatalf("b1's pool must be untouched: status=%d body=%s", code, raw)
	}
	if code, raw := doJSON(t, srv, "GET", "/v2/lobby/keypackages?device=a1&consumer=b1&room=other", nil); code != http.StatusNotFound || errField(t, raw) != "no_live_key_package" {
		t.Fatalf("nothing left to consume: status=%d body=%s", code, raw)
	}

	// Idempotent; the device can publish again afterwards.
	code, raw = doJSON(t, srv, "DELETE", "/v2/lobby/keypackages?device=a1", nil)
	if err := json.Unmarshal(raw, &got); code != http.StatusOK || err != nil || got.Deleted != 0 {
		t.Fatalf("repeat delete: status=%d body=%s", code, raw)
	}
	if code, raw := doJSON(t, srv, "POST", "/v2/lobby/keypackages", lobbyPublishBody(t, "a1", "k9")); code != http.StatusCreated || decodeKeyPackages(t, raw).Live != 1 {
		t.Fatalf("republish after delete: status=%d body=%s", code, raw)
	}

	if code, raw := doJSON(t, srv, "DELETE", "/v2/lobby/keypackages", nil); code != http.StatusBadRequest || errField(t, raw) != "device_required" {
		t.Fatalf("missing device: status=%d body=%s", code, raw)
	}
	if code, raw := doJSON(t, srv, "DELETE", "/v2/lobby/keypackages?device=bad%20id", nil); code != http.StatusBadRequest || errField(t, raw) != "bad_identifier" {
		t.Fatalf("bad device: status=%d body=%s", code, raw)
	}
}
