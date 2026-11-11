// Long-poll relay tests (#424, #755 stage 0, wait.go). Pinned here: without
// ?wait= GET …/events answers at once as before; with it an empty page waits
// until a fresh event / typing / close lands or the wait runs out, a page with
// rows answers at once, bad values are 400 and large ones clamp; /v2/watch
// reports rooms that already have rows at once, else the first rooms that
// change, keeps per-room refusals in "errors" without waiting on them, and
// validates its room list; the hub loses no change that lands before the wait
// and bounds waiting requests per device.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type timedResult struct {
	status  int
	raw     []byte
	elapsed time.Duration
}

// getAsync issues GET path in the background and reports status, body and
// how long it took.
func getAsync(t *testing.T, srv *httptest.Server, path string) <-chan timedResult {
	t.Helper()
	out := make(chan timedResult, 1)
	go func() {
		start := time.Now()
		resp, err := http.Get(srv.URL + path)
		if err != nil {
			out <- timedResult{status: -1, raw: []byte(err.Error()), elapsed: time.Since(start)}
			return
		}
		defer resp.Body.Close()
		raw, _ := io.ReadAll(resp.Body)
		out <- timedResult{status: resp.StatusCode, raw: raw, elapsed: time.Since(start)}
	}()
	return out
}

// waitSubscribed blocks until the relay has n waiting subscribers.
func waitSubscribed(t *testing.T, r *relay, n int) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		r.changes.mu.Lock()
		got := len(r.changes.subs)
		r.changes.mu.Unlock()
		if got >= n {
			return
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatalf("subscribers never reached %d", n)
}

func receive(t *testing.T, ch <-chan timedResult, within time.Duration) timedResult {
	t.Helper()
	select {
	case res := <-ch:
		return res
	case <-time.After(within):
		t.Fatalf("no answer within %v", within)
		return timedResult{}
	}
}

func postApp(t *testing.T, srv *httptest.Server, room, device, clientID string) {
	t.Helper()
	if st, raw := doJSON(t, srv, "POST", "/v2/rooms/"+room+"/events",
		postEventBody(t, device, clientID, "application", 0, nil, nil, []byte(clientID))); st != http.StatusCreated {
		t.Fatalf("post %s/%s: status=%d body=%s", room, clientID, st, raw)
	}
}

func TestEventsWithoutWaitAnswersAtOnce(t *testing.T) {
	_, srv := newTestRelay(t, testPolicy())
	seedRoom(t, srv, "r")
	res := receive(t, getAsync(t, srv, "/v2/rooms/r/events?device=b1&after=1"), 2*time.Second)
	if res.status != http.StatusOK || len(decodeEventsResponse(t, res.raw).Events) != 0 {
		t.Fatalf("status=%d body=%s", res.status, res.raw)
	}
	if res.elapsed > time.Second {
		t.Fatalf("plain GET waited %v", res.elapsed)
	}
}

func TestEventsWaitWakesOnFreshEvent(t *testing.T) {
	r, srv := newTestRelay(t, testPolicy())
	seedRoom(t, srv, "r")
	ch := getAsync(t, srv, "/v2/rooms/r/events?device=b1&after=1&wait=10000")
	waitSubscribed(t, r, 1)
	postApp(t, srv, "r", "a1", "m2")
	res := receive(t, ch, 3*time.Second)
	if res.status != http.StatusOK {
		t.Fatalf("status=%d body=%s", res.status, res.raw)
	}
	page := decodeEventsResponse(t, res.raw)
	if len(page.Events) != 1 || page.Events[0].Seq != 2 || page.NextAfter != 2 {
		t.Fatalf("woken page = %+v", page)
	}
	if res.elapsed > 3*time.Second {
		t.Fatalf("wake took %v", res.elapsed)
	}
}

func TestEventsWaitTimesOutWithEmptyPage(t *testing.T) {
	_, srv := newTestRelay(t, testPolicy())
	seedRoom(t, srv, "r")
	res := receive(t, getAsync(t, srv, "/v2/rooms/r/events?device=b1&after=1&wait=200"), 3*time.Second)
	if res.status != http.StatusOK || len(decodeEventsResponse(t, res.raw).Events) != 0 {
		t.Fatalf("status=%d body=%s", res.status, res.raw)
	}
	if res.elapsed < 180*time.Millisecond {
		t.Fatalf("answered after %v, want ≈200ms", res.elapsed)
	}
}

func TestEventsWaitWithRowsAnswersAtOnce(t *testing.T) {
	_, srv := newTestRelay(t, testPolicy())
	seedRoom(t, srv, "r")
	res := receive(t, getAsync(t, srv, "/v2/rooms/r/events?device=b1&after=0&wait=10000"), 2*time.Second)
	if res.status != http.StatusOK || len(decodeEventsResponse(t, res.raw).Events) != 1 {
		t.Fatalf("status=%d body=%s", res.status, res.raw)
	}
	if res.elapsed > time.Second {
		t.Fatalf("page with rows waited %v", res.elapsed)
	}
}

func TestEventsWaitWakesOnTypingAndClose(t *testing.T) {
	r, srv := newTestRelay(t, testPolicy())
	seedRoom(t, srv, "r")
	ch := getAsync(t, srv, "/v2/rooms/r/events?device=b1&after=1&wait=10000")
	waitSubscribed(t, r, 1)
	postTyping(t, srv, "r", "a1", false)
	res := receive(t, ch, 3*time.Second)
	if page := decodeEventsResponse(t, res.raw); res.status != http.StatusOK || !equalStrings(page.Typing, []string{"a1"}) {
		t.Fatalf("typing wake: status=%d body=%s", res.status, res.raw)
	}

	ch = getAsync(t, srv, "/v2/rooms/r/events?device=b1&after=1&wait=10000")
	waitSubscribed(t, r, 1)
	if st, raw := doJSON(t, srv, "POST", "/v2/rooms/r/close?device=a1", nil); st != http.StatusOK {
		t.Fatalf("close: status=%d body=%s", st, raw)
	}
	if res := receive(t, ch, 3*time.Second); res.status != http.StatusGone {
		t.Fatalf("close wake: status=%d body=%s", res.status, res.raw)
	}
}

func TestEventsWaitCappedWhileSomeoneTypes(t *testing.T) {
	pol := testPolicy()
	pol.TypingTTLSeconds = 1
	_, srv := newTestRelay(t, pol)
	seedRoom(t, srv, "r")
	postTyping(t, srv, "r", "a1", false)
	res := receive(t, getAsync(t, srv, "/v2/rooms/r/events?device=b1&after=1&wait=10000"), 4*time.Second)
	if res.status != http.StatusOK {
		t.Fatalf("status=%d body=%s", res.status, res.raw)
	}
	if res.elapsed > 2500*time.Millisecond {
		t.Fatalf("wait with a typer ran %v, want ≈ TypingTTL (1s)", res.elapsed)
	}
}

func TestEventsWaitRejectsBadValues(t *testing.T) {
	_, srv := newTestRelay(t, testPolicy())
	seedRoom(t, srv, "r")
	for _, v := range []string{"-1", "abc", "1.5"} {
		st, raw := doJSON(t, srv, "GET", "/v2/rooms/r/events?device=b1&after=1&wait="+v, nil)
		if st != http.StatusBadRequest || !strings.Contains(string(raw), "bad_wait") {
			t.Fatalf("wait=%s: status=%d body=%s", v, st, raw)
		}
	}
}

func TestParseWaitClampsAndDefaults(t *testing.T) {
	cases := map[string]time.Duration{"": 0, "0": 0, "250": 250 * time.Millisecond, "25000": maxEventsWait, "999999999": maxEventsWait}
	for in, want := range cases {
		got, err := parseWait(in)
		if err != nil || got != want {
			t.Fatalf("parseWait(%q) = %v, %v; want %v", in, got, err, want)
		}
	}
}

func decodeWatch(t *testing.T, raw []byte) watchResponse {
	t.Helper()
	var w watchResponse
	if err := json.Unmarshal(raw, &w); err != nil {
		t.Fatalf("watch body %s: %v", raw, err)
	}
	return w
}

func TestWatchAnswersAtOnceForRoomsWithRows(t *testing.T) {
	_, srv := newTestRelay(t, testPolicy())
	seedRoom(t, srv, "r1")
	seedRoom(t, srv, "r2")
	res := receive(t, getAsync(t, srv, "/v2/watch?device=b1&wait=10000&room=r1:0&room=r2:1"), 2*time.Second)
	if res.status != http.StatusOK {
		t.Fatalf("status=%d body=%s", res.status, res.raw)
	}
	if w := decodeWatch(t, res.raw); !equalStrings(w.Changed, []string{"r1"}) || len(w.Errors) != 0 {
		t.Fatalf("watch = %+v", w)
	}
	if res.elapsed > time.Second {
		t.Fatalf("watch with a changed room waited %v", res.elapsed)
	}
}

func TestWatchWakesOnTheRoomThatChanges(t *testing.T) {
	r, srv := newTestRelay(t, testPolicy())
	seedRoom(t, srv, "r1")
	seedRoom(t, srv, "r2")
	ch := getAsync(t, srv, "/v2/watch?device=b1&wait=10000&room=r1:1&room=r2:1")
	waitSubscribed(t, r, 1)
	postApp(t, srv, "r2", "a1", "m2")
	res := receive(t, ch, 3*time.Second)
	if w := decodeWatch(t, res.raw); res.status != http.StatusOK || !equalStrings(w.Changed, []string{"r2"}) {
		t.Fatalf("status=%d body=%s", res.status, res.raw)
	}
}

func TestWatchTimesOutEmptyAndSkipsRefusedRooms(t *testing.T) {
	_, srv := newTestRelay(t, testPolicy())
	seedRoom(t, srv, "r1")
	res := receive(t, getAsync(t, srv, "/v2/watch?device=b1&wait=200&room=r1:1&room=ghost:0"), 3*time.Second)
	w := decodeWatch(t, res.raw)
	if res.status != http.StatusOK || len(w.Changed) != 0 || w.Errors["ghost"] != "no_such_room" {
		t.Fatalf("status=%d body=%s", res.status, res.raw)
	}
	if res.elapsed < 180*time.Millisecond {
		t.Fatalf("answered after %v, want ≈200ms", res.elapsed)
	}
	// Only refused rooms: nothing to wait on, answer at once.
	res = receive(t, getAsync(t, srv, "/v2/watch?device=b1&wait=10000&room=ghost:0"), 2*time.Second)
	if res.status != http.StatusOK || res.elapsed > time.Second {
		t.Fatalf("all-refused watch: status=%d after %v body=%s", res.status, res.elapsed, res.raw)
	}
}

func TestWatchValidatesRequest(t *testing.T) {
	_, srv := newTestRelay(t, testPolicy())
	many := make([]string, 0, maxWatchRooms+1)
	for i := 0; i <= maxWatchRooms; i++ {
		many = append(many, fmt.Sprintf("room=r%d:0", i))
	}
	cases := map[string]string{
		"/v2/watch?device=b1":                            "rooms_required",
		"/v2/watch?room=r1:0":                            "device_required",
		"/v2/watch?device=b1&room=r1":                    "bad_identifier",
		"/v2/watch?device=b1&room=r1:-1":                 "bad_after",
		"/v2/watch?device=b1&room=r1:0&room=r1:2":        "duplicate_room",
		"/v2/watch?device=b1&room=r1:0&wait=x":           "bad_wait",
		"/v2/watch?device=b1&" + strings.Join(many, "&"): "too_many_rooms",
	}
	for path, code := range cases {
		st, raw := doJSON(t, srv, "GET", path, nil)
		if st != http.StatusBadRequest || !strings.Contains(string(raw), code) {
			t.Fatalf("%s: status=%d body=%s (want %s)", path, st, raw, code)
		}
	}
}

func TestChangeHubKeepsAChangeThatLandsBeforeTheWait(t *testing.T) {
	var h changeHub
	sub := h.subscribe([]string{"a", "b"})
	defer h.unsubscribe(sub)
	h.notify("b")
	h.notify("zzz") // not watched
	h.notify("a")
	if !h.await(context.Background(), sub, time.Second) {
		t.Fatal("await missed a change recorded before it")
	}
	if got := h.take(sub); !equalStrings(got, []string{"a", "b"}) {
		t.Fatalf("take = %v", got)
	}
	if h.await(context.Background(), sub, 20*time.Millisecond) {
		t.Fatal("await fired with nothing recorded")
	}
}

func TestChangeHubBoundsWaitersPerDevice(t *testing.T) {
	var h changeHub
	for i := 0; i < maxWaitersPerDevice; i++ {
		if !h.acquire("d") {
			t.Fatalf("slot %d refused", i)
		}
	}
	if h.acquire("d") {
		t.Fatal("slot past the cap granted")
	}
	if !h.acquire("other") {
		t.Fatal("another device is not bounded by d")
	}
	h.release("d")
	if !h.acquire("d") {
		t.Fatal("released slot not reusable")
	}
	for i := 0; i < maxWaitersPerDevice; i++ {
		h.release("d")
	}
	h.mu.Lock()
	_, left := h.waiters["d"]
	h.mu.Unlock()
	if left {
		t.Fatal("waiter count not cleaned up")
	}
}

// A request past the per-device cap degrades to an immediate answer.
func TestEventsWaitPastCapAnswersAtOnce(t *testing.T) {
	r, srv := newTestRelay(t, testPolicy())
	seedRoom(t, srv, "r")
	for i := 0; i < maxWaitersPerDevice; i++ {
		r.changes.acquire("b1")
	}
	res := receive(t, getAsync(t, srv, "/v2/rooms/r/events?device=b1&after=1&wait=10000"), 2*time.Second)
	if res.status != http.StatusOK || res.elapsed > time.Second {
		t.Fatalf("over-cap request: status=%d after %v", res.status, res.elapsed)
	}
}
