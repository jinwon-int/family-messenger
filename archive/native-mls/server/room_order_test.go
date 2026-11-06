// Actor-wide room list order tests (room-order v1, #715, room_order.go).
// Pinned here: a never-stored order is {"rooms":[],"revision":0,"updated_at":0};
// PUT is a base_revision CAS (match → revision+1, stale → 409
// revision_conflict carrying the current value, revision 0 included); the row
// is keyed by the device-policy actor so a second device of the same person
// reads it while another actor does not; the body is strict JSON with the
// #715 limits (64 rooms, identifiers, no duplicates; non-member room ids are
// accepted); authentication answers the /read·/mute codes (401 unauthorized,
// 400 device_required / bad_identifier, 403 device_subject_mismatch for
// foreign, unknown and revoked devices alike, 500 device_policy_unavailable);
// the routes exist only with a verifier and a device store; and the row
// survives a restart and an open over a database that predates the table.
package main

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/jinwon-int/family-messenger/archive/native-mls/server/internal/devicepolicy"
)

// roomOrderRelay is an authenticated relay with a chain: alice (a1, a2,
// revoked a3), bob (b1). Tokens are per subject ("subject-<actor>").
func roomOrderRelay(t *testing.T) (*relay, *httptest.Server, *devicepolicy.DevicePolicyStore, string, *testIssuer) {
	t.Helper()
	r, srv, st, dir, first := newEnforcedRelay(t, testPolicy())
	iss := newTestIssuer(t)
	r.access = iss.verifier()
	srv.Config.Handler = r.routes() // the route needs r.access, set after construction
	enrollDevice(t, st, first, "a1", "alice")
	enrollDevice(t, st, first, "a2", "alice")
	enrollDevice(t, st, first, "a3", "alice")
	enrollDevice(t, st, first, "b1", "bob")
	revokeDevice(t, st, "a3")
	return r, srv, st, dir, iss
}

func roomOrderBody(t *testing.T, device string, rooms []string, base int64) []byte {
	t.Helper()
	return mustJSON(t, map[string]any{"device": device, "rooms": rooms, "base_revision": base})
}

func getRoomOrder(t *testing.T, srv *httptest.Server, device, token string) roomOrder {
	t.Helper()
	code, raw := doAuth(t, srv, "GET", roomOrderPath+"?device="+device, nil, token)
	if code != http.StatusOK {
		t.Fatalf("get room order %s: %d %s", device, code, raw)
	}
	var o roomOrder
	decodeInto(t, raw, &o)
	if o.Rooms == nil {
		t.Fatalf("get room order %s: rooms is null in %s", device, raw)
	}
	return o
}

func putRoomOrder(t *testing.T, srv *httptest.Server, device, token string, rooms []string, base int64) roomOrder {
	t.Helper()
	code, raw := doAuth(t, srv, "PUT", roomOrderPath, roomOrderBody(t, device, rooms, base), token)
	if code != http.StatusOK {
		t.Fatalf("put room order %s base=%d: %d %s", device, base, code, raw)
	}
	var o roomOrder
	decodeInto(t, raw, &o)
	return o
}

func sameRooms(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestRoomOrderCASSharedAcrossOneActorsDevices(t *testing.T) {
	_, srv, _, _, iss := roomOrderRelay(t)
	alice, bob := iss.mint("subject-alice", nil), iss.mint("subject-bob", nil)

	// Never stored: the exact empty body, no-store headers.
	resp, body := doHeadersResp(t, srv, "GET", roomOrderPath+"?device=a1", map[string]string{"Cf-Access-Jwt-Assertion": alice})
	if resp.StatusCode != http.StatusOK || body != "{\"rooms\":[],\"revision\":0,\"updated_at\":0}\n" {
		t.Fatalf("empty get: %d %q", resp.StatusCode, body)
	}
	if resp.Header.Get("Cache-Control") != "no-store" || !strings.HasPrefix(resp.Header.Get("Content-Type"), "application/json") {
		t.Fatalf("empty get headers: %v", resp.Header)
	}

	// Seed from a1 (base 0) → revision 1; a2 (same actor) reads it, bob does not.
	order := []string{"family", "r-2", "not-my-room"} // membership is not checked
	got := putRoomOrder(t, srv, "a1", alice, order, 0)
	if got.Revision != 1 || got.UpdatedAt <= 0 || !sameRooms(got.Rooms, order) {
		t.Fatalf("seed put: %+v", got)
	}
	for _, d := range []string{"a1", "a2"} {
		if o := getRoomOrder(t, srv, d, alice); o.Revision != 1 || !sameRooms(o.Rooms, order) || o.UpdatedAt != got.UpdatedAt {
			t.Fatalf("alice %s get: %+v", d, o)
		}
	}
	if o := getRoomOrder(t, srv, "b1", bob); o.Revision != 0 || len(o.Rooms) != 0 || o.UpdatedAt != 0 {
		t.Fatalf("bob sees alice's order: %+v", o)
	}

	// a2 moves on from revision 1 → 2.
	order2 := []string{"r-2", "family"}
	if o := putRoomOrder(t, srv, "a2", alice, order2, 1); o.Revision != 2 || !sameRooms(o.Rooms, order2) {
		t.Fatalf("a2 put: %+v", o)
	}
	// a1 still holds revision 1: 409 with the current value, nothing stored.
	code, raw := doAuth(t, srv, "PUT", roomOrderPath, roomOrderBody(t, "a1", []string{"x"}, 1), alice)
	var conflict struct {
		Error     string   `json:"error"`
		Rooms     []string `json:"rooms"`
		Revision  int64    `json:"revision"`
		UpdatedAt int64    `json:"updated_at"`
	}
	decodeInto(t, raw, &conflict)
	if code != http.StatusConflict || conflict.Error != "revision_conflict" || conflict.Revision != 2 || !sameRooms(conflict.Rooms, order2) || conflict.UpdatedAt <= 0 {
		t.Fatalf("stale put: %d %s", code, raw)
	}
	if o := getRoomOrder(t, srv, "a1", alice); o.Revision != 2 || !sameRooms(o.Rooms, order2) {
		t.Fatalf("after conflict: %+v", o)
	}
	// A base ahead of the store is stale too.
	if code, raw := doAuth(t, srv, "PUT", roomOrderPath, roomOrderBody(t, "a1", []string{"x"}, 7), alice); code != http.StatusConflict {
		t.Fatalf("future base: %d %s", code, raw)
	}

	// Bob's conflict against a never-stored order still carries revision 0 on the wire.
	code, raw = doAuth(t, srv, "PUT", roomOrderPath, roomOrderBody(t, "b1", []string{"b"}, 3), bob)
	if code != http.StatusConflict || string(raw) != "{\"error\":\"revision_conflict\",\"rooms\":[],\"revision\":0,\"updated_at\":0}\n" {
		t.Fatalf("bob conflict at revision 0: %d %s", code, raw)
	}
	// Bob seeds his own; alice's is untouched.
	if o := putRoomOrder(t, srv, "b1", bob, []string{"bob-room"}, 0); o.Revision != 1 {
		t.Fatalf("bob seed: %+v", o)
	}
	if o := getRoomOrder(t, srv, "a2", alice); o.Revision != 2 || !sameRooms(o.Rooms, order2) {
		t.Fatalf("alice after bob: %+v", o)
	}
	// An empty list is a valid order (stored, revision moves on).
	if o := putRoomOrder(t, srv, "a1", alice, []string{}, 2); o.Revision != 3 || len(o.Rooms) != 0 {
		t.Fatalf("empty put: %+v", o)
	}
	if o := getRoomOrder(t, srv, "a2", alice); o.Revision != 3 || len(o.Rooms) != 0 {
		t.Fatalf("empty get: %+v", o)
	}
}

func TestRoomOrderValidation(t *testing.T) {
	_, srv, _, _, iss := roomOrderRelay(t)
	alice := iss.mint("subject-alice", nil)

	rooms := func(n int) []string {
		out := make([]string, n)
		for i := range out {
			out[i] = fmt.Sprintf("room-%02d", i)
		}
		return out
	}
	long := strings.Repeat("x", maxIdentifierLen+1)
	cases := []struct {
		name, body, code string
		status           int
	}{
		{"65 rooms", string(roomOrderBody(t, "a1", rooms(65), 0)), "too_many_rooms", 400},
		{"duplicate", string(roomOrderBody(t, "a1", []string{"r1", "r2", "r1"}, 0)), "duplicate_room", 400},
		{"bad room id", string(roomOrderBody(t, "a1", []string{"r1", "has space"}, 0)), "bad_identifier", 400},
		{"empty room id", string(roomOrderBody(t, "a1", []string{""}, 0)), "bad_identifier", 400},
		{"long room id", string(roomOrderBody(t, "a1", []string{long}, 0)), "bad_identifier", 400},
		{"missing device", `{"rooms":["r1"],"base_revision":0}`, "device_required", 400},
		{"empty device", `{"device":"","rooms":["r1"],"base_revision":0}`, "device_required", 400},
		{"bad device", `{"device":"a 1","rooms":["r1"],"base_revision":0}`, "bad_identifier", 400},
		{"missing rooms", `{"device":"a1","base_revision":0}`, "rooms_required", 400},
		{"missing base", `{"device":"a1","rooms":["r1"]}`, "base_revision_required", 400},
		{"negative base", `{"device":"a1","rooms":["r1"],"base_revision":-1}`, "bad_request", 400},
		{"null rooms", `{"device":"a1","rooms":null,"base_revision":0}`, "bad_request", 400},
		{"unknown field", `{"device":"a1","rooms":[],"base_revision":0,"actor":"bob"}`, "bad_request", 400},
		{"duplicate key", `{"device":"a1","rooms":[],"rooms":["r1"],"base_revision":0}`, "bad_request", 400},
		{"rooms not strings", `{"device":"a1","rooms":[1],"base_revision":0}`, "bad_request", 400},
		{"empty body", ``, "empty_body", 400},
	}
	for _, c := range cases {
		code, raw := doAuth(t, srv, "PUT", roomOrderPath, []byte(c.body), alice)
		if code != c.status || errField(t, raw) != c.code {
			t.Fatalf("%s: %d %s, want %d %s", c.name, code, raw, c.status, c.code)
		}
	}
	// Nothing above was stored.
	if o := getRoomOrder(t, srv, "a1", alice); o.Revision != 0 {
		t.Fatalf("after refused puts: %+v", o)
	}
	// Exactly 64 is accepted and comes back in order.
	if o := putRoomOrder(t, srv, "a1", alice, rooms(64), 0); o.Revision != 1 || !sameRooms(o.Rooms, rooms(64)) {
		t.Fatalf("64 rooms: %+v", o)
	}
	if o := getRoomOrder(t, srv, "a2", alice); !sameRooms(o.Rooms, rooms(64)) {
		t.Fatalf("64 rooms get: %+v", o)
	}
	// GET query validation.
	for p, want := range map[string]string{
		roomOrderPath:                   "device_required",
		roomOrderPath + "?device=":      "device_required",
		roomOrderPath + "?device=a%201": "bad_identifier",
	} {
		if code, raw := doAuth(t, srv, "GET", p, nil, alice); code != http.StatusBadRequest || errField(t, raw) != want {
			t.Fatalf("GET %s: %d %s, want %s", p, code, raw, want)
		}
	}
}

func TestRoomOrderAuth(t *testing.T) {
	_, srv, _, dir, iss := roomOrderRelay(t)
	alice, bob := iss.mint("subject-alice", nil), iss.mint("subject-bob", nil)
	putA1 := roomOrderBody(t, "a1", []string{"r1"}, 0)

	// No / invalid token → bare 401 like /v2/me.
	for name, headers := range map[string]map[string]string{
		"none":    {},
		"garbage": {"Cf-Access-Jwt-Assertion": "not.a.jwt"},
		"cookie":  {"Cookie": "CF_Authorization=" + alice},
	} {
		for _, m := range []struct {
			method, path string
			body         []byte
		}{{"GET", roomOrderPath + "?device=a1", nil}, {"PUT", roomOrderPath, putA1}} {
			code, raw := doHeaders(t, srv, m.method, m.path, m.body, headers)
			if code != http.StatusUnauthorized || errField(t, raw) != "unauthorized" {
				t.Fatalf("%s %s: %d %s", name, m.method, code, raw)
			}
		}
	}
	// Cross-site browser request refused before anything else.
	if code, _ := doHeaders(t, srv, "PUT", roomOrderPath, putA1, map[string]string{"Cf-Access-Jwt-Assertion": alice, "Sec-Fetch-Site": "cross-site"}); code != http.StatusForbidden {
		t.Fatalf("cross-site: %d", code)
	}
	// Another subject's device, an unknown device and a revoked device: one
	// indistinguishable 403 (bindDevice), on GET and PUT.
	for name, c := range map[string]struct{ device, token string }{
		"bob token, alice device": {"a1", bob},
		"alice token, bob device": {"b1", alice},
		"unknown device":          {"zz9", alice},
		"revoked device":          {"a3", alice},
	} {
		if code, raw := doAuth(t, srv, "GET", roomOrderPath+"?device="+c.device, nil, c.token); code != http.StatusForbidden || errField(t, raw) != "device_subject_mismatch" {
			t.Fatalf("%s GET: %d %s", name, code, raw)
		}
		if code, raw := doAuth(t, srv, "PUT", roomOrderPath, roomOrderBody(t, c.device, []string{"r1"}, 0), c.token); code != http.StatusForbidden || errField(t, raw) != "device_subject_mismatch" {
			t.Fatalf("%s PUT: %d %s", name, code, raw)
		}
	}
	// Bob's attempt with alice's device stored nothing for alice.
	if o := getRoomOrder(t, srv, "a1", alice); o.Revision != 0 {
		t.Fatalf("after refused writes: %+v", o)
	}
	// Methods: only GET and PUT.
	if code, _ := doAuth(t, srv, "POST", roomOrderPath, putA1, alice); code != http.StatusMethodNotAllowed {
		t.Fatalf("POST: %d", code)
	}
	// A tampered chain fails closed.
	genesis := filepath.Join(dir, "policy-000001.json")
	if err := os.WriteFile(genesis, []byte(`{"revision":1,"tampered":true}`), 0600); err != nil {
		t.Fatal(err)
	}
	if code, raw := doAuth(t, srv, "PUT", roomOrderPath, putA1, alice); code != http.StatusInternalServerError || errField(t, raw) != "device_policy_unavailable" {
		t.Fatalf("corrupt chain PUT: %d %s", code, raw)
	}
	if code, raw := doAuth(t, srv, "GET", roomOrderPath+"?device=a1", nil, alice); code != http.StatusInternalServerError || errField(t, raw) != "device_policy_unavailable" {
		t.Fatalf("corrupt chain GET: %d %s", code, raw)
	}
}

// The actor is the chain record's, not the device id's prefix: a device
// named like bob's but enrolled under alice reads and writes alice's order.
func TestRoomOrderActorComesFromPolicyChain(t *testing.T) {
	_, srv, st, _, iss := roomOrderRelay(t)
	enrollDevice(t, st, map[string]string{"alice": "a1"}, "bob-lookalike", "alice")
	alice, bob := iss.mint("subject-alice", nil), iss.mint("subject-bob", nil)
	putRoomOrder(t, srv, "bob-lookalike", alice, []string{"r1"}, 0)
	if o := getRoomOrder(t, srv, "a1", alice); o.Revision != 1 || !sameRooms(o.Rooms, []string{"r1"}) {
		t.Fatalf("alice via a1: %+v", o)
	}
	if o := getRoomOrder(t, srv, "b1", bob); o.Revision != 0 {
		t.Fatalf("bob: %+v", o)
	}
}

// The routes exist only with a verifier AND a device store (404 = old relay
// to the clients, which keep their local order).
func TestRoomOrderAbsentWithoutVerifierOrStore(t *testing.T) {
	_, srv, _, _, _ := newEnforcedRelay(t, testPolicy())
	if code, _ := doJSON(t, srv, "GET", roomOrderPath+"?device=a1", nil); code != http.StatusNotFound {
		t.Fatalf("without verifier: %d", code)
	}
	r, srv2 := newTestRelay(t, testPolicy())
	iss := newTestIssuer(t)
	r.access = iss.verifier()
	srv2.Config.Handler = r.routes()
	tok := iss.mint("s", nil)
	if code, _ := doAuth(t, srv2, "GET", roomOrderPath+"?device=a1", nil, tok); code != http.StatusNotFound {
		t.Fatalf("GET without store: %d", code)
	}
	if code, _ := doAuth(t, srv2, "PUT", roomOrderPath, []byte(`{}`), tok); code != http.StatusNotFound {
		t.Fatalf("PUT without store: %d", code)
	}
}

// The row lives in the relay's one SQLite file (what the snapshot copies):
// it survives a restart, and opening a database from before #715 (no
// actor_room_order table, e.g. a restored older snapshot) creates the table
// and answers revision 0 without touching the other tables.
func TestRoomOrderSurvivesRestartAndOldDatabase(t *testing.T) {
	policyDir := t.TempDir()
	if err := os.Chmod(policyDir, 0700); err != nil {
		t.Fatal(err)
	}
	st, err := devicepolicy.OpenDevicePolicyStore(policyDir)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.Init(); err != nil {
		t.Fatal(err)
	}
	iss := newTestIssuer(t)
	alice := iss.mint("subject-alice", nil)
	start := func(dataDir string) (*relay, *httptest.Server) {
		r, srv, _ := newTestRelayAt(t, testPolicy(), dataDir)
		r.devices = st
		r.access = iss.verifier()
		srv.Config.Handler = r.routes()
		return r, srv
	}
	stop := func(r *relay, srv *httptest.Server) {
		srv.Close()
		if err := r.db.Close(); err != nil {
			t.Fatalf("close relay: %v", err)
		}
	}

	dataDir := t.TempDir()
	r1, srv1 := start(dataDir)
	enrollDevice(t, st, map[string]string{}, "a1", "alice")
	putRoomOrder(t, srv1, "a1", alice, []string{"r2", "r1"}, 0)
	stop(r1, srv1)

	r2, srv2 := start(dataDir)
	if o := getRoomOrder(t, srv2, "a1", alice); o.Revision != 1 || !sameRooms(o.Rooms, []string{"r2", "r1"}) {
		t.Fatalf("after restart: %+v", o)
	}
	// Simulate a pre-#715 database: drop the table, keep a marker row elsewhere.
	if _, err := r2.db.Exec(`DROP TABLE actor_room_order`); err != nil {
		t.Fatal(err)
	}
	if _, err := r2.db.Exec(`INSERT INTO push_devices (device, token, topic, updated_at) VALUES ('a1', x'00', 't', 1)`); err != nil {
		t.Fatal(err)
	}
	stop(r2, srv2)

	r3, srv3 := start(dataDir)
	if o := getRoomOrder(t, srv3, "a1", alice); o.Revision != 0 || len(o.Rooms) != 0 {
		t.Fatalf("old database: %+v", o)
	}
	var n int
	if err := r3.db.QueryRow(`SELECT COUNT(*) FROM push_devices`).Scan(&n); err != nil || n != 1 {
		t.Fatalf("other tables touched: n=%d err=%v", n, err)
	}
	if o := putRoomOrder(t, srv3, "a1", alice, []string{"r1"}, 0); o.Revision != 1 {
		t.Fatalf("seed on old database: %+v", o)
	}
}

// doHeadersResp is a body-less request that also returns the response headers.
func doHeadersResp(t *testing.T, srv *httptest.Server, method, path string, headers map[string]string) (*http.Response, string) {
	t.Helper()
	req, err := http.NewRequest(method, srv.URL+path, nil)
	if err != nil {
		t.Fatal(err)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	return resp, string(raw)
}
