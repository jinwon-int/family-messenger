// HTTP contract tests for the native-mls v2 relay (#177 §3.4). Every test
// drives the real routes() mux over httptest with a throwaway SQLite file;
// policy fields are overridden directly (the sanctioned test hook — flags
// only gate the CLI). Fault injections pinned here: stale-epoch CAS 409,
// stale-revision CAS 409, client_id reuse 409, room byte cap 413, oversized
// body 413 and strict-JSON duplicate-key 400. Scenario pins: the 3-device
// commit → stale-epoch 409 → re-encrypt flow with Welcome target filtering
// (B4), application-event pruning gated on every known device's durable
// cursor across a relay restart and on Welcome targets that have not read
// yet, and the K4 byte-equal retry winning over a stale-epoch CAS.
package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// newTestRelay builds a relay over a fresh SQLite file plus an httptest
// server exposing the contract routes.
func newTestRelay(t *testing.T, pol policy) (*relay, *httptest.Server) {
	t.Helper()
	r, srv, _ := newTestRelayAt(t, pol, t.TempDir())
	return r, srv
}

// newTestRelayAt is newTestRelay with an explicit data dir so restart tests
// can open a second relay instance over the same database file.
func newTestRelayAt(t *testing.T, pol policy, dir string) (*relay, *httptest.Server, string) {
	t.Helper()
	db, err := openStore(dir)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	r := &relay{db: db, policy: pol}
	srv := httptest.NewServer(r.routes())
	t.Cleanup(srv.Close)
	return r, srv, dir
}

// testPolicy is defaultPolicy with a small byte cap so cap tests stay tiny.
func testPolicy() policy {
	p := defaultPolicy()
	p.RoomBytesCap = 1 << 20 // 1 MiB
	return p
}

func i64p(v int64) *int64 { return &v }

// doJSON performs one request against the test server and returns the status
// with the raw response body. A nil body sends no request body at all.
func doJSON(t *testing.T, srv *httptest.Server, method, path string, body []byte) (int, []byte) {
	t.Helper()
	var rd io.Reader
	if body != nil {
		rd = bytes.NewReader(body)
	}
	req, err := http.NewRequest(method, srv.URL+path, rd)
	if err != nil {
		t.Fatalf("new request %s %s: %v", method, path, err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, path, err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read response %s %s: %v", method, path, err)
	}
	return resp.StatusCode, raw
}

// postEventBody marshals one POST /events body; a nil revision is omitted so
// the epoch-only CAS path stays reachable, and nil targets are omitted.
func postEventBody(t *testing.T, device, clientID, kind string, epoch int64, revision *int64, targets []string, payload []byte) []byte {
	t.Helper()
	body := struct {
		Device   string   `json:"device"`
		ClientID string   `json:"client_id"`
		Kind     string   `json:"kind"`
		Epoch    int64    `json:"epoch"`
		Revision *int64   `json:"revision,omitempty"`
		Targets  []string `json:"targets,omitempty"`
		Bytes    []byte   `json:"bytes"`
	}{
		Device:   device,
		ClientID: clientID,
		Kind:     kind,
		Epoch:    epoch,
		Revision: revision,
		Targets:  targets,
		Bytes:    payload,
	}
	raw, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal event body: %v", err)
	}
	return raw
}

func decodeAPIError(t *testing.T, raw []byte) apiError {
	t.Helper()
	var e apiError
	if err := json.Unmarshal(raw, &e); err != nil {
		t.Fatalf("response is not an apiError: %v (%s)", err, raw)
	}
	return e
}

// errField decodes an apiError response and returns its "error" code.
func errField(t *testing.T, raw []byte) string {
	t.Helper()
	return decodeAPIError(t, raw).Error
}

func decodeEventResponse(t *testing.T, raw []byte) eventResponse {
	t.Helper()
	var resp eventResponse
	if err := json.Unmarshal(raw, &resp); err != nil {
		t.Fatalf("response is not an eventResponse: %v (%s)", err, raw)
	}
	return resp
}

func decodeEventsResponse(t *testing.T, raw []byte) eventsResponse {
	t.Helper()
	var resp eventsResponse
	if err := json.Unmarshal(raw, &resp); err != nil {
		t.Fatalf("response is not an eventsResponse: %v (%s)", err, raw)
	}
	return resp
}

// TestPostEventStaleEpochMismatchReturns409 pins the epoch-only CAS path: a
// device that missed a commit posts at the old epoch and gets 409 carrying
// the room's current epoch/revision (§3.4).
func TestPostEventStaleEpochMismatchReturns409(t *testing.T) {
	_, srv := newTestRelay(t, testPolicy())

	st, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "a1", "c1", "commit", 0, nil, nil, []byte("commit-one")))
	if st != http.StatusCreated {
		t.Fatalf("seed commit: status=%d body=%s", st, raw)
	}
	if resp := decodeEventResponse(t, raw); resp.Epoch != 1 || resp.Revision != 1 {
		t.Fatalf("seed commit epoch/revision = %d/%d, want 1/1", resp.Epoch, resp.Revision)
	}

	st, raw = doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "b1", "c2", "application", 0, nil, nil, []byte("stale-epoch")))
	if st != http.StatusConflict {
		t.Fatalf("stale epoch post: status=%d body=%s", st, raw)
	}
	e := decodeAPIError(t, raw)
	if e.Error != "cas_mismatch" {
		t.Fatalf("error code = %q, want cas_mismatch", e.Error)
	}
	if e.Epoch != 1 || e.Revision != 1 {
		t.Fatalf("cas_mismatch carries epoch/revision = %d/%d, want current 1/1", e.Epoch, e.Revision)
	}
}

// TestPostEventStaleRevisionMismatchReturns409 pins the revision CAS path:
// same epoch but a stale revision pointer is rejected with the current pair.
func TestPostEventStaleRevisionMismatchReturns409(t *testing.T) {
	_, srv := newTestRelay(t, testPolicy())

	st, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "a1", "c1", "application", 0, nil, nil, []byte("first")))
	if st != http.StatusCreated {
		t.Fatalf("seed application: status=%d body=%s", st, raw)
	}
	if resp := decodeEventResponse(t, raw); resp.Epoch != 0 || resp.Revision != 1 {
		t.Fatalf("seed application epoch/revision = %d/%d, want 0/1", resp.Epoch, resp.Revision)
	}

	// Epoch is current (0) but the sender cached revision 0; the room is at 1.
	st, raw = doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "a2", "c2", "application", 0, i64p(0), nil, []byte("stale-revision")))
	if st != http.StatusConflict {
		t.Fatalf("stale revision post: status=%d body=%s", st, raw)
	}
	e := decodeAPIError(t, raw)
	if e.Error != "cas_mismatch" {
		t.Fatalf("error code = %q, want cas_mismatch", e.Error)
	}
	if e.Epoch != 0 || e.Revision != 1 {
		t.Fatalf("cas_mismatch carries epoch/revision = %d/%d, want current 0/1", e.Epoch, e.Revision)
	}
}

// TestPostEventClientIDReuseReturns409 pins K4 idempotency against its abuse
// case: a byte-equal replay of (room, device, client_id) answers 200, but
// reusing the same identity with different bytes is a hard 409.
func TestPostEventClientIDReuseReturns409(t *testing.T) {
	_, srv := newTestRelay(t, testPolicy())

	first := postEventBody(t, "a1", "c1", "application", 0, nil, nil, []byte("first-payload"))
	st, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", first)
	if st != http.StatusCreated {
		t.Fatalf("seed post: status=%d body=%s", st, raw)
	}
	seeded := decodeEventResponse(t, raw)

	// Byte-equal replay: 200 + duplicate=true + the original seq.
	st, raw = doJSON(t, srv, "POST", "/v2/rooms/r/events", first)
	if st != http.StatusOK {
		t.Fatalf("byte-equal replay: status=%d body=%s, want 200", st, raw)
	}
	if replay := decodeEventResponse(t, raw); !replay.Duplicate || replay.Seq != seeded.Seq {
		t.Fatalf("replay = %+v seq=%d, want duplicate with seq %d", replay, replay.Seq, seeded.Seq)
	}

	// Same identity, different bytes: client_id reuse -> 409.
	st, raw = doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "a1", "c1", "application", 0, nil, nil, []byte("different-payload")))
	if st != http.StatusConflict {
		t.Fatalf("client_id reuse: status=%d body=%s", st, raw)
	}
	e := decodeAPIError(t, raw)
	if e.Error != "client_id_reuse" {
		t.Fatalf("error code = %q, want client_id_reuse", e.Error)
	}
	if !strings.Contains(e.Detail, "c1") || !strings.Contains(e.Detail, "a1") {
		t.Fatalf("client_id_reuse detail %q should name device and client_id", e.Detail)
	}
}

// TestPostEventRoomBytesCapReturns413 pins B5: the cap counts event bytes per
// room, the offending post answers 413 with used/cap, and the rejected event
// leaves no partial write behind.
func TestPostEventRoomBytesCapReturns413(t *testing.T) {
	pol := testPolicy()
	pol.RoomBytesCap = 1 << 10 // 1 KiB
	_, srv := newTestRelay(t, pol)

	st, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "a1", "c1", "application", 0, nil, nil, bytes.Repeat([]byte("a"), 600)))
	if st != http.StatusCreated {
		t.Fatalf("seed 600B post: status=%d body=%s", st, raw)
	}

	st, raw = doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "a2", "c2", "application", 0, nil, nil, bytes.Repeat([]byte("b"), 600)))
	if st != http.StatusRequestEntityTooLarge {
		t.Fatalf("cap-exceeding post: status=%d body=%s", st, raw)
	}
	e := decodeAPIError(t, raw)
	if e.Error != "room_bytes_cap" {
		t.Fatalf("error code = %q, want room_bytes_cap", e.Error)
	}
	if e.Used != 600 || e.Cap != 1<<10 {
		t.Fatalf("room_bytes_cap used/cap = %d/%d, want 600/1024", e.Used, e.Cap)
	}

	// The rejected event must not appear: only the seed (seq 1) is stored.
	st, raw = doJSON(t, srv, "GET", "/v2/rooms/r/events?device=a1", nil)
	if st != http.StatusOK {
		t.Fatalf("get events after cap rejection: status=%d body=%s", st, raw)
	}
	if got := decodeEventsResponse(t, raw); len(got.Events) != 1 || got.Revision != 1 {
		t.Fatalf("events after cap rejection = %+v, want only the seed at revision 1", got)
	}
}

// TestPostEventOversizedBodyReturns413 pins the transport guard: a body above
// RoomBytesCap+1MiB never reaches the store and answers 413 body_too_large.
func TestPostEventOversizedBodyReturns413(t *testing.T) {
	pol := testPolicy() // RoomBytesCap 1MiB -> read limit 2MiB
	_, srv := newTestRelay(t, pol)

	oversized := bytes.Repeat([]byte("a"), int(pol.RoomBytesCap+(1<<20)+1))
	st, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", oversized)
	if st != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversized body: status=%d body=%s", st, raw)
	}
	if got := errField(t, raw); got != "body_too_large" {
		t.Fatalf("error code = %q, want body_too_large", got)
	}
}

// TestPostEventDuplicateKeyRejected400 pins strict JSON (K6): a repeated
// object key anywhere in the body is a 400 bad_request, never silently
// last-value-wins.
func TestPostEventDuplicateKeyRejected400(t *testing.T) {
	_, srv := newTestRelay(t, testPolicy())

	dup := []byte(`{"device":"a1","device":"a1","client_id":"c1","kind":"application","epoch":0,"bytes":"aGk="}`)
	st, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", dup)
	if st != http.StatusBadRequest {
		t.Fatalf("duplicate-key body: status=%d body=%s", st, raw)
	}
	e := decodeAPIError(t, raw)
	if e.Error != "bad_request" {
		t.Fatalf("error code = %q, want bad_request", e.Error)
	}
	if !strings.Contains(e.Detail, `duplicate key "device"`) {
		t.Fatalf("bad_request detail %q should name the duplicate key", e.Detail)
	}
}

// TestThreeDeviceCommitWelcomeTargetingScenario pins the §3.4 add-member flow
// over three devices: a commit bumps the epoch, a device that missed it gets
// 409 carrying the current epoch/revision, the re-encrypt retry reuses the
// same client_id successfully (a CAS-rejected write never consumes identity,
// K4), and the a2-targeted Welcome is filtered from b1/a1 reads without a 403
// while still delivered to a2 (B4).
func TestThreeDeviceCommitWelcomeTargetingScenario(t *testing.T) {
	_, srv := newTestRelay(t, testPolicy())

	// Seed: the room exists at epoch 0 revision 1.
	st, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "a1", "c1", "application", 0, nil, nil, []byte("before-commit")))
	if st != http.StatusCreated {
		t.Fatalf("seed application: status=%d body=%s", st, raw)
	}

	// b1 commits the add of a2: epoch 0 -> 1, revision 1 -> 2.
	st, raw = doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "b1", "c2", "commit", 0, nil, nil, []byte("commit-add-a2")))
	if st != http.StatusCreated {
		t.Fatalf("commit: status=%d body=%s", st, raw)
	}
	if resp := decodeEventResponse(t, raw); resp.Epoch != 1 || resp.Revision != 2 {
		t.Fatalf("commit epoch/revision = %d/%d, want 1/2", resp.Epoch, resp.Revision)
	}

	// a1 cached the old epoch and posts application traffic: hard 409 with
	// the room's current epoch/revision so it can re-key and retry.
	st, raw = doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "a1", "c3", "application", 0, nil, nil, []byte("stale-ciphertext")))
	if st != http.StatusConflict {
		t.Fatalf("stale-epoch post: status=%d body=%s", st, raw)
	}
	e := decodeAPIError(t, raw)
	if e.Error != "cas_mismatch" || e.Epoch != 1 || e.Revision != 2 {
		t.Fatalf("stale-epoch error = %+v, want cas_mismatch at epoch/revision 1/2", e)
	}

	// Re-encrypt at epoch 1 and retry with the SAME client_id: the rejected
	// write must not have consumed the (room, device, client_id) identity,
	// otherwise this retry would answer 409 client_id_reuse (K4).
	st, raw = doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "a1", "c3", "application", 1, nil, nil, []byte("re-encrypted-at-epoch-1")))
	if st != http.StatusCreated {
		t.Fatalf("re-encrypt retry: status=%d body=%s", st, raw)
	}
	if resp := decodeEventResponse(t, raw); resp.Seq != 3 || resp.Epoch != 1 || resp.Revision != 3 {
		t.Fatalf("retry response = %+v, want seq 3 epoch 1 revision 3", resp)
	}

	// b1 welcomes only a2 into the new epoch.
	st, raw = doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "b1", "c4", "welcome", 1, nil, []string{"a2"}, []byte("welcome-for-a2")))
	if st != http.StatusCreated {
		t.Fatalf("welcome post: status=%d body=%s", st, raw)
	}

	// B4: members the Welcome does not target read the room without it and
	// without a 403; both see the same three visible events in seq order.
	for _, device := range []string{"b1", "a1"} {
		st, raw = doJSON(t, srv, "GET", "/v2/rooms/r/events?device="+device, nil)
		if st != http.StatusOK {
			t.Fatalf("get as %s: status=%d body=%s", device, st, raw)
		}
		got := decodeEventsResponse(t, raw)
		if got.Revision != 4 {
			t.Fatalf("get as %s revision = %d, want 4", device, got.Revision)
		}
		if len(got.Events) != 3 {
			t.Fatalf("get as %s returned %d events, want 3 (welcome filtered): %+v", device, len(got.Events), got.Events)
		}
		for i, want := range []struct {
			seq  int64
			kind string
		}{{1, "application"}, {2, "commit"}, {3, "application"}} {
			if got.Events[i].Seq != want.seq || got.Events[i].Kind != want.kind {
				t.Fatalf("get as %s event[%d] = seq %d kind %s, want seq %d kind %s",
					device, i, got.Events[i].Seq, got.Events[i].Kind, want.seq, want.kind)
			}
		}
	}

	// a2 is the Welcome's target: it gets the full order including seq 4.
	st, raw = doJSON(t, srv, "GET", "/v2/rooms/r/events?device=a2", nil)
	if st != http.StatusOK {
		t.Fatalf("get as a2: status=%d body=%s", st, raw)
	}
	got := decodeEventsResponse(t, raw)
	if len(got.Events) != 4 {
		t.Fatalf("get as a2 returned %d events, want 4: %+v", len(got.Events), got.Events)
	}
	w := got.Events[3]
	if w.Seq != 4 || w.Kind != "welcome" || w.Device != "b1" || string(w.Bytes) != "welcome-for-a2" {
		t.Fatalf("get as a2 event[3] = seq %d kind %s device %s bytes %q, want the targeted welcome from b1",
			w.Seq, w.Kind, w.Device, w.Bytes)
	}
}

// TestPruneAfterRestartWaitsForEveryKnownDevice pins cursor-gated
// application-event pruning across a relay restart. Cursors are durable
// (mls_cursors), and every device that posted to the room is known with a
// cursor from its first post, so a device that has not read yet blocks
// deletion before AND after the restart — a restart must not turn "b1 has not
// come back yet" into "b1 never existed". Only once b1 reads do stale events
// up to the minimum cursor go. created_at is wall-clock now, so the policy
// runs with a negative AppEventTTLSeconds: every stored application event is
// stale at prune time, which isolates the cursor gate from clock assumptions.
func TestPruneAfterRestartWaitsForEveryKnownDevice(t *testing.T) {
	pol := testPolicy()
	pol.AppEventTTLSeconds = -1
	dir := t.TempDir()

	// Relay instance 1: two application events land, then the process dies.
	rA, srvA, _ := newTestRelayAt(t, pol, dir)
	st, raw := doJSON(t, srvA, "POST", "/v2/rooms/r/events",
		postEventBody(t, "a1", "c1", "application", 0, nil, nil, []byte("message-one")))
	if st != http.StatusCreated {
		t.Fatalf("seed one: status=%d body=%s", st, raw)
	}
	st, raw = doJSON(t, srvA, "POST", "/v2/rooms/r/events",
		postEventBody(t, "b1", "c2", "application", 0, nil, nil, []byte("message-two")))
	if st != http.StatusCreated {
		t.Fatalf("seed two: status=%d body=%s", st, raw)
	}
	srvA.Close()
	if err := rA.db.Close(); err != nil {
		t.Fatalf("close relay 1: %v", err)
	}

	// Relay instance 2 over the same file.
	_, srvB, _ := newTestRelayAt(t, pol, dir)
	getAll := func(device string) eventsResponse {
		t.Helper()
		st, raw := doJSON(t, srvB, "GET", "/v2/rooms/r/events?device="+device, nil)
		if st != http.StatusOK {
			t.Fatalf("get %s: status=%d body=%s", device, st, raw)
		}
		return decodeEventsResponse(t, raw)
	}

	// a1 reads everything after the restart (cursor 2), then writes seq 3,
	// which prunes. b1 posted before the restart and has not read: nothing
	// it has not seen may go.
	if got := getAll("a1"); len(got.Events) != 2 {
		t.Fatalf("restart kept %d events, want 2: %+v", len(got.Events), got.Events)
	}
	st, raw = doJSON(t, srvB, "POST", "/v2/rooms/r/events",
		postEventBody(t, "a1", "c3", "application", 0, nil, nil, []byte("message-three")))
	if st != http.StatusCreated {
		t.Fatalf("post-restart write: status=%d body=%s", st, raw)
	}
	if got := getAll("b1"); len(got.Events) != 3 {
		t.Fatalf("b1 (offline across restart) sees %d events, want all 3: %+v", len(got.Events), got.Events)
	}
	// That GET moved b1's cursor to 3; a1 re-reads to 3 as well. The next
	// write prunes everything up to the minimum cursor (3); seq 4 survives.
	getAll("a1")
	st, raw = doJSON(t, srvB, "POST", "/v2/rooms/r/events",
		postEventBody(t, "a1", "c4", "application", 0, nil, nil, []byte("message-four")))
	if st != http.StatusCreated {
		t.Fatalf("post-cursor write: status=%d body=%s", st, raw)
	}
	got := getAll("a1")
	if len(got.Events) != 1 || got.Events[0].Seq != 4 || string(got.Events[0].Bytes) != "message-four" {
		t.Fatalf("after prune = %+v, want only seq 4 (stale <= min cursor 3 deleted, seq 4 beyond it kept)",
			got.Events)
	}
	if got.Epoch != 0 || got.Revision != 4 {
		t.Fatalf("epoch/revision after prune = %d/%d, want 0/4 (deletes never touch CAS state)",
			got.Epoch, got.Revision)
	}
}

// TestLostResponseRetryAfterCommitReturns200Duplicate pins K4 over CAS: a
// device whose POST landed but whose response was lost retries the exact
// same bytes after another device's commit moved the epoch. The original row
// is already stored, so the retry must be the byte-equal 200 duplicate — not
// a stale-epoch 409 that would push the client into re-encrypting an event
// the room already holds (and then into client_id_reuse).
func TestLostResponseRetryAfterCommitReturns200Duplicate(t *testing.T) {
	_, srv := newTestRelay(t, testPolicy())
	app := postEventBody(t, "a1", "a1-m1", "application", 0, nil, nil, []byte("hello at epoch 0"))
	st, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", app)
	if st != http.StatusCreated {
		t.Fatalf("first send: status=%d body=%s", st, raw)
	}
	first := decodeEventResponse(t, raw)
	// Response "lost"; meanwhile b1 commits and the room moves to epoch 1.
	st, raw = doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "b1", "b1-c1", "commit", 0, nil, nil, []byte("commit 0->1")))
	if st != http.StatusCreated {
		t.Fatalf("commit: status=%d body=%s", st, raw)
	}
	st, raw = doJSON(t, srv, "POST", "/v2/rooms/r/events", app)
	if st != http.StatusOK {
		t.Fatalf("byte-equal retry after commit: status=%d body=%s, want 200 duplicate (K4 before CAS)", st, raw)
	}
	got := decodeEventResponse(t, raw)
	if !got.Duplicate || got.Seq != first.Seq {
		t.Fatalf("retry = %+v, want duplicate of seq %d", got, first.Seq)
	}
	// Different bytes under the same client_id stay a reuse conflict even
	// when the epoch is stale: the id is taken, whatever the epoch says.
	st, raw = doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "a1", "a1-m1", "application", 0, nil, nil, []byte("different bytes")))
	if st != http.StatusConflict || errField(t, raw) != "client_id_reuse" {
		t.Fatalf("reuse with stale epoch: status=%d body=%s, want 409 client_id_reuse", st, raw)
	}
}

// TestPruneWaitsForWelcomeTargetToRead pins that a device added by a
// targeted Welcome blocks pruning of everything after that Welcome until it
// reads, without any restart: the relay must not delete application events
// the newest member has never seen just because the older members read them.
// Events before the Welcome are not gated on the new device (it cannot
// decrypt them anyway).
func TestPruneWaitsForWelcomeTargetToRead(t *testing.T) {
	pol := testPolicy()
	pol.AppEventTTLSeconds = -1
	_, srv := newTestRelay(t, pol)
	post := func(device, clientID, kind string, epoch int64, targets []string, payload string) {
		t.Helper()
		st, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
			postEventBody(t, device, clientID, kind, epoch, nil, targets, []byte(payload)))
		if st != http.StatusCreated {
			t.Fatalf("post %s/%s: status=%d body=%s", device, clientID, st, raw)
		}
	}
	get := func(device string) eventsResponse {
		t.Helper()
		st, raw := doJSON(t, srv, "GET", "/v2/rooms/r/events?device="+device, nil)
		if st != http.StatusOK {
			t.Fatalf("get %s: status=%d body=%s", device, st, raw)
		}
		return decodeEventsResponse(t, raw)
	}
	post("a1", "m1", "application", 0, nil, "before welcome")    // seq 1
	get("a1")                                                    // a1 cursor 1
	post("a1", "w1", "welcome", 0, []string{"b1"}, "welcome b1") // seq 2
	post("a1", "m3", "application", 0, nil, "after welcome")     // seq 3
	get("a1")                                                    // a1 cursor 3
	post("a1", "m4", "application", 0, nil, "trigger prune")     // seq 4, prunes

	seen := map[int64]bool{}
	for _, ev := range get("b1").Events {
		seen[ev.Seq] = true
	}
	if !seen[3] {
		t.Fatalf("b1 lost seq 3 before ever reading (min cursor ignored the welcome target): saw %v", seen)
	}
	if seen[1] {
		t.Fatalf("seq 1 predates b1's welcome and a1 read it; it should have been pruned: saw %v", seen)
	}
}
