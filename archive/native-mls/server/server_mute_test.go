// Per-room notification setting tests (mute.go). Pinned here: POST /mute keys
// the flag by the tracked member's actor so the same person's other device
// sees it in GET /events `muted` while another actor does not; it is
// idempotent both ways; the gate answers the read codes; `muted` is required;
// and APNs targets skip every device of a muted actor for application events
// but not for a welcome.
package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func postMute(t *testing.T, srv *httptest.Server, room, device string, muted bool) bool {
	t.Helper()
	raw, _ := json.Marshal(map[string]any{"device": device, "muted": muted})
	st, body := doJSON(t, srv, "POST", "/v2/rooms/"+room+"/mute", raw)
	if st != http.StatusOK {
		t.Fatalf("mute %s=%v: status=%d body=%s", device, muted, st, body)
	}
	var resp muteResponse
	if err := json.Unmarshal(body, &resp); err != nil {
		t.Fatalf("decode mute response %s: %v", body, err)
	}
	return resp.Muted
}

func mutedOf(t *testing.T, srv *httptest.Server, room, device string) bool {
	t.Helper()
	st, raw := doJSON(t, srv, "GET", "/v2/rooms/"+room+"/events?device="+device, nil)
	if st != http.StatusOK {
		t.Fatalf("get %s: status=%d body=%s", device, st, raw)
	}
	return decodeEventsResponse(t, raw).Muted
}

func TestMuteIsSharedAcrossOneActorsDevices(t *testing.T) {
	_, srv, st, _, first := newEnforcedRelay(t, testPolicy())
	seedActors(t, srv, st, first)

	for _, d := range []string{"a1", "a2", "b1"} {
		if mutedOf(t, srv, "r", d) {
			t.Fatalf("fresh muted for %s = true", d)
		}
	}
	if !postMute(t, srv, "r", "a1", true) {
		t.Fatal("a1 mute → false")
	}
	if !mutedOf(t, srv, "r", "a2") {
		t.Fatal("a2 muted = false, want true (alice-wide)")
	}
	if mutedOf(t, srv, "r", "b1") {
		t.Fatal("b1 muted = true, want false (bob did not mute)")
	}
	// Idempotent: muting again keeps it, unmuting from the other device clears it for both.
	if !postMute(t, srv, "r", "a1", true) {
		t.Fatal("a1 re-mute → false")
	}
	if postMute(t, srv, "r", "a2", false) {
		t.Fatal("a2 unmute → true")
	}
	if mutedOf(t, srv, "r", "a1") {
		t.Fatal("a1 muted after a2 unmute = true")
	}
	if postMute(t, srv, "r", "a2", false) {
		t.Fatal("a2 second unmute → true")
	}
}

func TestMuteGate(t *testing.T) {
	_, srv, st, _, first := newEnforcedRelay(t, testPolicy())
	seedActors(t, srv, st, first)

	cases := []struct {
		name   string
		room   string
		body   string
		status int
		err    string
	}{
		{"unknown room", "nope", `{"device":"a1","muted":true}`, http.StatusNotFound, "no_such_room"},
		{"unknown device", "r", `{"device":"ghost","muted":true}`, http.StatusForbidden, "device_not_allowed"},
		{"active non-member", "r", `{"device":"c1","muted":true}`, http.StatusForbidden, "not_a_member"},
		{"device required", "r", `{"muted":true}`, http.StatusBadRequest, "device_required"},
		{"bad identifier", "r", `{"device":"a 1","muted":true}`, http.StatusBadRequest, "bad_identifier"},
		{"muted required", "r", `{"device":"a1"}`, http.StatusBadRequest, "muted_required"},
		{"unknown field", "r", `{"device":"a1","muted":true,"actor":"bob"}`, http.StatusBadRequest, "bad_request"},
	}
	for _, c := range cases {
		code, raw := doJSON(t, srv, "POST", "/v2/rooms/"+c.room+"/mute", []byte(c.body))
		if code != c.status || errField(t, raw) != c.err {
			t.Fatalf("%s: status=%d body=%s, want %d %s", c.name, code, raw, c.status, c.err)
		}
	}
	if mutedOf(t, srv, "r", "a1") {
		t.Fatal("muted after refused posts = true")
	}
	if mutedOf(t, srv, "r", "c1") {
		t.Fatal("non-member muted = true")
	}
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/close?device=a1", nil); code != http.StatusOK {
		t.Fatalf("close: status=%d body=%s", code, raw)
	}
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/mute", []byte(`{"device":"a1","muted":true}`)); code != http.StatusGone || errField(t, raw) != "room_closed" {
		t.Fatalf("mute on closed room: status=%d body=%s", code, raw)
	}
}

func TestAPNsSkipsMutedActor(t *testing.T) {
	r, srv, st, _, first := newEnforcedRelay(t, testPolicy())
	seedActors(t, srv, st, first) // alice a1,a2 · bob b1 in r; a2 posted seq 2
	const topic = "com.seoyoon-family.hande"
	for dev, tok := range map[string][]byte{"a1": {0xa1}, "a2": {0xa2}, "b1": {0xb1}} {
		if st, raw := doJSON(t, srv, "POST", "/v2/push/devices", pushBody(dev, tok, topic)); st != http.StatusNoContent {
			t.Fatalf("register %s: %d %s", dev, st, raw)
		}
	}
	devices := func(kind, sender string, seq int64) map[string]bool {
		t.Helper()
		targets, err := r.pushTargets("r", sender, kind, seq)
		if err != nil {
			t.Fatal(err)
		}
		out := map[string]bool{}
		for _, tg := range targets {
			out[tg.device] = true
		}
		return out
	}
	if got := devices("application", "b1", 3); len(got) != 2 || !got["a1"] || !got["a2"] {
		t.Fatalf("before mute: %v, want a1 a2", got)
	}
	postMute(t, srv, "r", "a2", true)
	if got := devices("application", "b1", 3); len(got) != 0 {
		t.Fatalf("alice muted: %v, want none", got)
	}
	// bob is unaffected by alice's setting.
	if got := devices("application", "a1", 3); len(got) != 1 || !got["b1"] {
		t.Fatalf("alice muted, alice sends: %v, want b1", got)
	}
	// A welcome still reaches a muted actor's device.
	if got := devices("welcome", "b1", 3); len(got) != 2 || !got["a1"] || !got["a2"] {
		t.Fatalf("welcome while muted: %v, want a1 a2", got)
	}
	postMute(t, srv, "r", "a1", false)
	if got := devices("application", "b1", 3); len(got) != 2 {
		t.Fatalf("after unmute: %v, want a1 a2", got)
	}
}
