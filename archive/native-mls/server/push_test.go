package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// #275 L2 ①② — GET /v2/rooms?device=, POST/DELETE /v2/push/devices, APNs.

func decodeRooms(t *testing.T, raw []byte) []roomListing {
	t.Helper()
	var resp map[string]json.RawMessage
	if err := json.Unmarshal(raw, &resp); err != nil {
		t.Fatalf("rooms body %s: %v", raw, err)
	}
	if string(resp["rooms"]) == "null" {
		t.Fatalf("rooms must be an array, got null")
	}
	var out roomsResponse
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatal(err)
	}
	return out.Rooms
}

func pushBody(device string, token []byte, topic string) []byte {
	b, _ := json.Marshal(map[string]any{"device": device, "apns_token": base64.StdEncoding.EncodeToString(token), "topic": topic})
	return b
}

func keyPackageBody(t *testing.T, device string, kp []byte) []byte {
	t.Helper()
	sum := sha256.Sum256(kp)
	b, err := json.Marshal(keyPackagePost{Device: device, Packages: []keyPackageInput{{Ref: hex.EncodeToString(sum[:]), Bytes: kp}}})
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestListRoomsReportsPublicStatePerDevice(t *testing.T) {
	_, srv := newTestRelay(t, testPolicy())
	post := func(room, device, client, kind string, epoch int64) {
		t.Helper()
		var targets []string
		if kind == "welcome" {
			targets = []string{"c1"}
		}
		if st, raw := doJSON(t, srv, "POST", "/v2/rooms/"+room+"/events", postEventBody(t, device, client, kind, epoch, nil, targets, []byte(client))); st != http.StatusCreated {
			t.Fatalf("post %s/%s: %d %s", room, client, st, raw)
		}
	}
	post("r", "a1", "x1", "application", 0)
	post("r", "b1", "x2", "commit", 0) // epoch 0 -> 1, revision 1 -> 2
	post("q", "a1", "y1", "application", 0)
	if st, raw := doJSON(t, srv, "POST", "/v2/rooms/q/close?device=a1", nil); st != http.StatusOK {
		t.Fatalf("close q: %d %s", st, raw)
	}
	if st, raw := doJSON(t, srv, "POST", "/v2/rooms/k/keypackages", keyPackageBody(t, "a1", []byte("kp-a1"))); st != http.StatusCreated && st != http.StatusOK {
		t.Fatalf("key package: %d %s", st, raw)
	}
	post("s", "b1", "z1", "application", 0) // a1 has nothing in s

	st, raw := doJSON(t, srv, "GET", "/v2/rooms?device=a1", nil)
	if st != http.StatusOK {
		t.Fatalf("list: %d %s", st, raw)
	}
	got := decodeRooms(t, raw)
	want := []roomListing{
		{Room: "k", Epoch: 0, Revision: 0, Member: false, KeyPackagesOutstanding: 1, Closed: false},
		{Room: "q", Epoch: 0, Revision: 1, Member: true, KeyPackagesOutstanding: 0, Closed: true},
		{Room: "r", Epoch: 1, Revision: 2, Member: true, KeyPackagesOutstanding: 0, Closed: false},
	}
	if len(got) != len(want) {
		t.Fatalf("rooms = %+v, want %+v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("room %d = %+v, want %+v", i, got[i], want[i])
		}
	}
	// Every contract key is present (Swift RoomListing has no optionals) and
	// nothing else leaks (no members, events, group id, creator).
	var generic struct {
		Rooms []map[string]json.RawMessage `json:"rooms"`
	}
	if err := json.Unmarshal(raw, &generic); err != nil {
		t.Fatal(err)
	}
	for _, r := range generic.Rooms {
		if len(r) != 6 {
			t.Fatalf("listing keys = %v, want exactly the 6 contract keys", r)
		}
		for _, k := range []string{"room", "epoch", "revision", "member", "keypackages_outstanding", "closed"} {
			if _, ok := r[k]; !ok {
				t.Fatalf("listing missing %q: %v", k, r)
			}
		}
	}

	// A device with no rooms gets an empty array, not null.
	if st, raw := doJSON(t, srv, "GET", "/v2/rooms?device=nobody", nil); st != http.StatusOK || len(decodeRooms(t, raw)) != 0 {
		t.Fatalf("empty list: %d %s", st, raw)
	}
	for path, code := range map[string]string{"/v2/rooms": "device_required", "/v2/rooms?device=a.b": "bad_identifier"} {
		if st, raw := doJSON(t, srv, "GET", path, nil); st != http.StatusBadRequest || errField(t, raw) != code {
			t.Fatalf("GET %s: %d %s, want 400 %s", path, st, raw, code)
		}
	}
}

func TestRoomsAndPushAreBoundToTheCallersSubject(t *testing.T) {
	_, srv, st, first, iss := newAuthedRelay(t, testPolicy())
	enrollDevice(t, st, first, "alice-phone", "alice")
	enrollDevice(t, st, first, "bob-phone", "bob")
	alice := iss.mint("subject-alice", nil)

	if code, raw := doAuth(t, srv, "GET", "/v2/rooms?device=alice-phone", nil, alice); code != http.StatusOK {
		t.Fatalf("own rooms: %d %s", code, raw)
	}
	tok := []byte{1, 2, 3, 4}
	if code, raw := doAuth(t, srv, "POST", "/v2/push/devices", pushBody("alice-phone", tok, "com.example.familychat.ios"), alice); code != http.StatusNoContent {
		t.Fatalf("own push register: %d %s", code, raw)
	}
	for _, c := range []struct {
		method, path string
		body         []byte
	}{
		{"GET", "/v2/rooms?device=bob-phone", nil},
		{"POST", "/v2/push/devices", pushBody("bob-phone", tok, "com.example.familychat.ios")},
		{"DELETE", "/v2/push/devices?device=bob-phone", nil},
		{"GET", "/v2/rooms?device=ghost-phone", nil}, // unknown device: same answer as foreign
	} {
		code, raw := doAuth(t, srv, c.method, c.path, c.body, alice)
		if code != http.StatusForbidden || errField(t, raw) != "device_subject_mismatch" {
			t.Fatalf("%s %s as alice: %d %s, want 403 device_subject_mismatch", c.method, c.path, code, raw)
		}
	}
	for _, c := range []struct{ method, path string }{{"GET", "/v2/rooms?device=alice-phone"}, {"DELETE", "/v2/push/devices?device=alice-phone"}} {
		if code, _ := doJSON(t, srv, c.method, c.path, nil); code != http.StatusUnauthorized {
			t.Fatalf("%s %s without token: %d, want 401", c.method, c.path, code)
		}
	}
	if code, raw := doAuth(t, srv, "DELETE", "/v2/push/devices?device=alice-phone", nil, alice); code != http.StatusNoContent {
		t.Fatalf("own push delete: %d %s", code, raw)
	}
}

func TestPushRegistrationIsIdempotentAndRotates(t *testing.T) {
	r, srv := newTestRelay(t, testPolicy())
	count := func() int { return tableCount(t, r, `SELECT COUNT(*) FROM push_devices`) }
	token := func() []byte {
		var b []byte
		if err := r.db.QueryRow(`SELECT token FROM push_devices WHERE device = 'a1'`).Scan(&b); err != nil {
			t.Fatal(err)
		}
		return b
	}
	const topic = "com.example.familychat.ios"
	for i := 0; i < 2; i++ {
		if st, raw := doJSON(t, srv, "POST", "/v2/push/devices", pushBody("a1", []byte{0xaa, 0xbb}, topic)); st != http.StatusNoContent {
			t.Fatalf("register #%d: %d %s", i, st, raw)
		}
	}
	if count() != 1 || hex.EncodeToString(token()) != "aabb" {
		t.Fatalf("after idempotent register: count=%d token=%x", count(), token())
	}
	if st, raw := doJSON(t, srv, "POST", "/v2/push/devices", pushBody("a1", []byte{0xcc}, topic)); st != http.StatusNoContent {
		t.Fatalf("rotate: %d %s", st, raw)
	}
	if count() != 1 || hex.EncodeToString(token()) != "cc" {
		t.Fatalf("after rotation: count=%d token=%x", count(), token())
	}

	bad := []struct {
		body []byte
		code string
	}{
		{[]byte(`{"device":"a1","apns_token":"%%%","topic":"` + topic + `"}`), "bad_request"},
		{pushBody("a1", nil, topic), "bad_apns_token"},
		{pushBody("a1", make([]byte, maxAPNsTokenBytes+1), topic), "bad_apns_token"},
		{pushBody("a1", []byte{1}, "com..example"), "bad_topic"},
		{pushBody("a1", []byte{1}, "com.example/../x"), "bad_topic"},
		{pushBody("a.1", []byte{1}, topic), "bad_identifier"},
		{[]byte(`{"device":"a1","apns_token":"AQ==","topic":"` + topic + `","sender":"x"}`), "bad_request"},
	}
	for _, b := range bad {
		if st, raw := doJSON(t, srv, "POST", "/v2/push/devices", b.body); st != http.StatusBadRequest || errField(t, raw) != b.code {
			t.Fatalf("POST %s: %d %s, want 400 %s", b.body, st, raw, b.code)
		}
	}

	r.pushTopics = map[string]bool{topic: true}
	if st, raw := doJSON(t, srv, "POST", "/v2/push/devices", pushBody("a1", []byte{1}, "com.other.app")); st != http.StatusBadRequest || errField(t, raw) != "topic_not_allowed" {
		t.Fatalf("disallowed topic: %d %s", st, raw)
	}

	for i := 0; i < 2; i++ {
		if st, raw := doJSON(t, srv, "DELETE", "/v2/push/devices?device=a1", nil); st != http.StatusNoContent {
			t.Fatalf("delete #%d: %d %s", i, st, raw)
		}
	}
	if count() != 0 {
		t.Fatalf("after delete: count=%d", count())
	}
}

// fakeAPNs is an HTTP/2 TLS server standing in for api.push.apple.com.
type fakeAPNs struct {
	srv   *httptest.Server
	mu    sync.Mutex
	calls []apnsCall
	reply map[string]int // hex token -> status (default 200)
}

type apnsCall struct {
	token, topic, pushType, priority, auth string
	body                                   []byte
	proto                                  int
}

func newFakeAPNs(t *testing.T) *fakeAPNs {
	f := &fakeAPNs{reply: map[string]int{}}
	f.srv = httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		body, _ := io.ReadAll(req.Body)
		tok := strings.TrimPrefix(req.URL.Path, "/3/device/")
		f.mu.Lock()
		f.calls = append(f.calls, apnsCall{token: tok, topic: req.Header.Get("apns-topic"), pushType: req.Header.Get("apns-push-type"),
			priority: req.Header.Get("apns-priority"), auth: req.Header.Get("authorization"), body: body, proto: req.ProtoMajor})
		status := f.reply[tok]
		f.mu.Unlock()
		if status == 0 || status == http.StatusOK {
			w.WriteHeader(http.StatusOK)
			return
		}
		w.Header().Set("content-type", "application/json")
		w.WriteHeader(status)
		reason := "Unregistered"
		if status == http.StatusForbidden {
			reason = "ExpiredProviderToken"
		}
		_, _ = w.Write([]byte(`{"reason":"` + reason + `"}`))
	}))
	f.srv.EnableHTTP2 = true
	f.srv.StartTLS()
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeAPNs) taken() []apnsCall {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := f.calls
	f.calls = nil
	return out
}

func testAPNsKey(t *testing.T) *ecdsa.PrivateKey {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return key
}

// verifyProviderToken checks the ES256 JWT the relay sent against the key.
func verifyProviderToken(t *testing.T, auth string, pub *ecdsa.PublicKey) {
	t.Helper()
	jwt, ok := strings.CutPrefix(auth, "bearer ")
	if !ok {
		t.Fatalf("authorization = %q", auth)
	}
	parts := strings.Split(jwt, ".")
	if len(parts) != 3 {
		t.Fatalf("jwt parts = %d", len(parts))
	}
	var header, claims map[string]any
	for i, v := range []*map[string]any{&header, &claims} {
		raw, err := base64.RawURLEncoding.DecodeString(parts[i])
		if err != nil || json.Unmarshal(raw, v) != nil {
			t.Fatalf("jwt part %d: %v", i, err)
		}
	}
	if header["alg"] != "ES256" || header["kid"] != "KEY1234567" || claims["iss"] != "TEAM123456" {
		t.Fatalf("jwt header %v claims %v", header, claims)
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || len(sig) != 64 {
		t.Fatalf("jwt signature: %v len %d", err, len(sig))
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if !ecdsa.Verify(pub, digest[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])) {
		t.Fatal("jwt signature does not verify")
	}
}

func TestAPNsAlertsBehindMembersOutsideTheTransaction(t *testing.T) {
	r, srv := newTestRelay(t, testPolicy())
	fake := newFakeAPNs(t)
	key := testAPNsKey(t)
	sender, err := newAPNsSender(fake.srv.URL, "TEAM123456", "KEY1234567", key, fake.srv.Client())
	if err != nil {
		t.Fatal(err)
	}
	r.push = sender
	const topic = "com.example.familychat.ios"
	tokens := map[string][]byte{"a1": {0xa1, 0x01}, "b1": {0xb1, 0x01}, "c1": {0xc1, 0x01}, "d1": {0xd1, 0x01}}
	for dev, tok := range tokens {
		if st, raw := doJSON(t, srv, "POST", "/v2/push/devices", pushBody(dev, tok, topic)); st != http.StatusNoContent {
			t.Fatalf("register %s: %d %s", dev, st, raw)
		}
	}
	post := func(device, client, kind string, epoch int64, targets []string) int64 {
		t.Helper()
		st, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", postEventBody(t, device, client, kind, epoch, nil, targets, []byte(client)))
		if st != http.StatusCreated && st != http.StatusOK {
			t.Fatalf("post %s: %d %s", client, st, raw)
		}
		r.pushWG.Wait()
		return decodeEventResponse(t, raw).Seq
	}
	devicesOf := func(calls []apnsCall) []string {
		var out []string
		for _, c := range calls {
			for dev, tok := range tokens {
				if c.token == hex.EncodeToString(tok) {
					out = append(out, dev)
				}
			}
		}
		return out
	}

	// a1 founds the room: nobody else is in it yet.
	post("a1", "m1", "application", 0, nil)
	if calls := fake.taken(); len(calls) != 0 {
		t.Fatalf("founding post pushed %v", devicesOf(calls))
	}
	// b1 posts: a1 (behind) gets exactly one alert; b1 (sender), c1/d1 (not in the room) none.
	seq := post("b1", "m2", "application", 0, nil)
	calls := fake.taken()
	if got := devicesOf(calls); len(got) != 1 || got[0] != "a1" {
		t.Fatalf("pushed %v, want [a1]", got)
	}
	c := calls[0]
	want := `{"aps":{"mutable-content":1,"alert":{"loc-key":"NEW_MESSAGE"},"thread-id":"r"},"room":"r","seq":` + jsonInt(seq) + `}`
	if string(c.body) != want {
		t.Fatalf("payload = %s, want %s", c.body, want)
	}
	if c.topic != topic || c.pushType != "alert" || c.priority != "10" || c.proto != 2 {
		t.Fatalf("headers topic=%q type=%q prio=%q proto=%d", c.topic, c.pushType, c.priority, c.proto)
	}
	verifyProviderToken(t, c.auth, &key.PublicKey)
	for _, leak := range []string{"m2", "b1", "a1"} {
		if strings.Contains(string(c.body), leak) {
			t.Fatalf("payload leaks %q: %s", leak, c.body)
		}
	}

	// A byte-equal replay (200 duplicate) and a commit do not push.
	post("b1", "m2", "application", 0, nil)
	post("b1", "m3", "commit", 0, nil)
	if calls := fake.taken(); len(calls) != 0 {
		t.Fatalf("replay/commit pushed %v", devicesOf(calls))
	}
	// A Welcome reaches its target (c1 now holds a cursor below the seq).
	post("b1", "m4", "welcome", 1, []string{"c1"})
	if got := devicesOf(fake.taken()); strings.Join(sortStrings(got), ",") != "a1,c1" {
		t.Fatalf("welcome pushed %v, want a1,c1", got)
	}

	// Apple says b1's token is gone: the next push drops it, a1/c1 stay.
	fake.mu.Lock()
	fake.reply[hex.EncodeToString(tokens["b1"])] = http.StatusGone
	fake.mu.Unlock()
	post("a1", "m5", "application", 1, nil)
	if got := devicesOf(fake.taken()); strings.Join(sortStrings(got), ",") != "b1,c1" {
		t.Fatalf("pushed %v, want b1,c1", got)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM push_devices WHERE device = 'b1'`); n != 0 {
		t.Fatalf("410 token still registered (%d)", n)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM push_devices`); n != 3 {
		t.Fatalf("registrations = %d, want a1 c1 d1", n)
	}
}

func TestAPNsDropOnlyTheRejectedToken(t *testing.T) {
	r, _ := newTestRelay(t, testPolicy())
	if err := r.savePushDevice(pushRegistration{Device: "a1", APNsToken: []byte{2}, Topic: "com.example.app"}, 1); err != nil {
		t.Fatal(err)
	}
	// A 410 for an older token must not erase the rotation that replaced it.
	if err := r.deletePushDevice("a1", []byte{1}); err != nil {
		t.Fatal(err)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM push_devices`); n != 1 {
		t.Fatalf("rotated token was dropped (%d)", n)
	}
}

func TestAPNsProviderTokenAndKeyHandling(t *testing.T) {
	key := testAPNsKey(t)
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	p8 := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
	dir := t.TempDir()
	path := filepath.Join(dir, "AuthKey.p8")
	if err := os.WriteFile(path, p8, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0o644); err != nil { // explicit: WriteFile's mode is masked by umask
		t.Fatal(err)
	}
	if _, err := loadAPNsKey(path); err == nil || !strings.Contains(err.Error(), "group/world") {
		t.Fatalf("0644 key accepted: %v", err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		t.Fatal(err)
	}
	loaded, err := loadAPNsKey(path)
	if err != nil || !loaded.Equal(key) {
		t.Fatalf("load: %v", err)
	}
	if _, err := parseAPNsKey(pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: der})); err == nil {
		t.Fatal("non-PKCS8 PEM type accepted")
	}
	for _, c := range []struct{ host, team, kid string }{
		{"http://api.push.apple.com", "TEAM123456", "KEY1234567"},
		{"https://api.push.apple.com/3/device", "TEAM123456", "KEY1234567"},
		{apnsDefaultHost, "team123456", "KEY1234567"},
		{apnsDefaultHost, "TEAM123456", "KEY123"},
	} {
		if _, err := newAPNsSender(c.host, c.team, c.kid, key, nil); err == nil {
			t.Fatalf("accepted %+v", c)
		}
	}

	s, err := newAPNsSender(apnsDefaultHost, "TEAM123456", "KEY1234567", key, nil)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Unix(1_800_000_000, 0)
	s.now = func() time.Time { return now }
	first, err := s.providerToken()
	if err != nil {
		t.Fatal(err)
	}
	verifyProviderToken(t, "bearer "+first, &key.PublicKey)
	now = now.Add(49 * time.Minute)
	if again, _ := s.providerToken(); again != first {
		t.Fatal("token re-minted inside its lifetime (Apple throttles refreshes)")
	}
	now = now.Add(2 * time.Minute)
	if later, _ := s.providerToken(); later == first {
		t.Fatal("token not re-minted after 50 minutes")
	}
	cur, _ := s.providerToken()
	s.invalidateToken() // what a 403 ExpiredProviderToken does
	if next, _ := s.providerToken(); next == cur {
		t.Fatal("invalidated token reused")
	}
}

func TestPushPayloadShape(t *testing.T) {
	got := string(newPushPayload("room-1", 42))
	want := `{"aps":{"mutable-content":1,"alert":{"loc-key":"NEW_MESSAGE"},"thread-id":"room-1"},"room":"room-1","seq":42}`
	if got != want {
		t.Fatalf("payload = %s, want %s", got, want)
	}
}

func jsonInt(v int64) string { b, _ := json.Marshal(v); return string(b) }

func sortStrings(in []string) []string {
	out := append([]string(nil), in...)
	for i := range out {
		for j := i + 1; j < len(out); j++ {
			if out[j] < out[i] {
				out[i], out[j] = out[j], out[i]
			}
		}
	}
	return out
}
