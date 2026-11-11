package main

// Long-poll (#424, #755 stage 0). GET /v2/rooms/{room}/events?wait=<ms> holds an
// empty page until the room changes (a fresh event, typing, read, mute, close)
// or the wait runs out, then reads again; without ?wait= the route answers at
// once exactly as before. GET /v2/watch lets one device wait on many rooms over
// one connection and answers with the rooms that changed, so a client with ~20
// rooms does not hold ~20 waiting requests (each still syncs a changed room
// with GET …/events as today).
//
// Nothing here widens what a caller can read: /v2/watch authenticates and binds
// the device like GET …/events and asks readEvents per room — it only reports
// "this room has rows after your seq", which GET …/events already answers.
//
// The hub is memory-only. A restart drops waiting requests (the relay has no
// graceful shutdown); clients retry like after any network error.

import (
	"context"
	"errors"
	"log"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	// maxEventsWait caps ?wait= (larger values are clamped, not refused). It
	// stays well under the server's 60 s WriteTimeout and Cloudflare's 100 s
	// idle limit for proxied requests.
	maxEventsWait = 25 * time.Second
	// maxWaitersPerDevice bounds concurrent waiting requests of one device;
	// past it a request answers at once (no wait) instead of failing, so an
	// over-eager client degrades to plain polling.
	maxWaitersPerDevice = 8
	// maxWatchRooms bounds the room list of one /v2/watch request.
	maxWatchRooms = 64
)

// changeHub fans "room changed" out to waiting requests. The zero value is
// ready to use (like typingState).
type changeHub struct {
	mu      sync.Mutex
	subs    map[*changeSub]struct{}
	waiters map[string]int
}

// changeSub is one waiting request. notify records the room in fired under the
// hub lock and pokes wake (capacity 1), so no change is lost between the
// subscriber's read and its wait, and a burst collapses into one wake.
type changeSub struct {
	rooms map[string]struct{}
	fired map[string]struct{}
	wake  chan struct{}
}

// subscribe must happen before the caller reads the rooms: a change that lands
// between the read and the wait is then already recorded.
func (h *changeHub) subscribe(rooms []string) *changeSub {
	sub := &changeSub{rooms: make(map[string]struct{}, len(rooms)), fired: map[string]struct{}{}, wake: make(chan struct{}, 1)}
	for _, r := range rooms {
		sub.rooms[r] = struct{}{}
	}
	h.mu.Lock()
	if h.subs == nil {
		h.subs = map[*changeSub]struct{}{}
	}
	h.subs[sub] = struct{}{}
	h.mu.Unlock()
	return sub
}

func (h *changeHub) unsubscribe(sub *changeSub) {
	h.mu.Lock()
	delete(h.subs, sub)
	h.mu.Unlock()
}

// notify marks room changed for every subscriber watching it. Never blocks.
func (h *changeHub) notify(room string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for sub := range h.subs {
		if _, ok := sub.rooms[room]; !ok {
			continue
		}
		sub.fired[room] = struct{}{}
		select {
		case sub.wake <- struct{}{}:
		default:
		}
	}
}

// take returns (sorted) and clears the rooms that fired for sub.
func (h *changeHub) take(sub *changeSub) []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	out := make([]string, 0, len(sub.fired))
	for r := range sub.fired {
		out = append(out, r)
	}
	sub.fired = map[string]struct{}{}
	// Drop a wake token left by a change await already saw through fired, so
	// the next await does not return on a stale token.
	select {
	case <-sub.wake:
	default:
	}
	sort.Strings(out)
	return out
}

func (h *changeHub) pending(sub *changeSub) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(sub.fired) > 0
}

// acquire reserves one waiting slot for device; release returns it.
func (h *changeHub) acquire(device string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.waiters == nil {
		h.waiters = map[string]int{}
	}
	if h.waiters[device] >= maxWaitersPerDevice {
		return false
	}
	h.waiters[device]++
	return true
}

func (h *changeHub) release(device string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.waiters[device] <= 1 {
		delete(h.waiters, device)
		return
	}
	h.waiters[device]--
}

// await blocks until sub fires, d elapses or ctx ends; true when it fired.
func (h *changeHub) await(ctx context.Context, sub *changeSub, d time.Duration) bool {
	if d <= 0 {
		return false
	}
	if h.pending(sub) {
		return true
	}
	timer := time.NewTimer(d)
	defer timer.Stop()
	for {
		select {
		case <-sub.wake:
			// fired is the truth; a token without a recorded change is stale.
			if h.pending(sub) {
				return true
			}
		case <-timer.C:
			return false
		case <-ctx.Done():
			return false
		}
	}
}

var errBadWait = errors.New("bad_wait")

// parseWait reads ?wait= in milliseconds: absent or 0 = no wait, negative or
// non-numeric = 400 bad_wait, above maxEventsWait = clamped.
func parseWait(raw string) (time.Duration, error) {
	if raw == "" {
		return 0, nil
	}
	v, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || v < 0 {
		return 0, errBadWait
	}
	if v >= maxEventsWait.Milliseconds() {
		return maxEventsWait, nil
	}
	return time.Duration(v) * time.Millisecond, nil
}

// typingCap shortens a wait while someone is typing in a watched room: typing
// signals expire without a write (TypingTTLSeconds), and a reader parked for
// the full wait would keep showing a stale 「입력중…」.
func (s *relay) typingCap(rooms []string, device string, d time.Duration) time.Duration {
	ttl := time.Duration(s.policy.TypingTTLSeconds) * time.Second
	if ttl <= 0 || d <= ttl {
		return d
	}
	now := time.Now().Unix()
	for _, room := range rooms {
		if len(s.typing.snapshot(room, device, now)) > 0 {
			return ttl
		}
	}
	return d
}

// waitForEvents is the ?wait= half of GET …/events: called with the first page
// (already acked), it parks an empty page until the room changes and re-reads
// without an ack (the first read moved the cursor already).
func (s *relay) waitForEvents(req *http.Request, sub *changeSub, room, device string, after int64, limit int, wait time.Duration, page eventsPage) (eventsPage, error) {
	if sub == nil || len(page.rows) > 0 || page.nextAfter > after {
		return page, nil
	}
	if !s.changes.acquire(device) {
		return page, nil
	}
	defer s.changes.release(device)
	if !s.changes.await(req.Context(), sub, s.typingCap([]string{room}, device, wait)) {
		return page, nil
	}
	return s.readEvents(room, device, after, limit, nil)
}

type watchResponse struct {
	Changed []string          `json:"changed"`
	Errors  map[string]string `json:"errors,omitempty"`
}

// handleWatch: GET /v2/watch?device=<d>&wait=<ms>&room=<name>:<after>[&room=…]
// answers {"changed":[rooms with rows after their seq, or that changed while
// waiting]} — at once when any room already has rows, else after the first
// change or the wait. Per-room refusals (no_such_room, room_closed) go to
// "errors" and are not waited on; the client handles them through GET …/events.
func (s *relay) handleWatch(w http.ResponseWriter, req *http.Request) {
	c, ok := s.authenticate(w, req)
	if !ok {
		return
	}
	q := req.URL.Query()
	device := q.Get("device")
	if device == "" {
		s.fail(w, http.StatusBadRequest, apiError{Error: "device_required"})
		return
	}
	if !validIdentifier(device) {
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_identifier", Detail: "device"})
		return
	}
	wait, err := parseWait(q.Get("wait"))
	if err != nil {
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_wait"})
		return
	}
	raw := q["room"]
	if len(raw) == 0 {
		s.fail(w, http.StatusBadRequest, apiError{Error: "rooms_required"})
		return
	}
	if len(raw) > maxWatchRooms {
		s.fail(w, http.StatusBadRequest, apiError{Error: "too_many_rooms", Detail: strconv.Itoa(maxWatchRooms)})
		return
	}
	names := make([]string, 0, len(raw))
	afters := make(map[string]int64, len(raw))
	for _, item := range raw {
		name, seq, found := strings.Cut(item, ":")
		if !found || !validIdentifier(name) {
			s.fail(w, http.StatusBadRequest, apiError{Error: "bad_identifier", Detail: "room"})
			return
		}
		after, err := strconv.ParseInt(seq, 10, 64)
		if err != nil || after < 0 {
			s.fail(w, http.StatusBadRequest, apiError{Error: "bad_after", Detail: name})
			return
		}
		if _, dup := afters[name]; dup {
			s.fail(w, http.StatusBadRequest, apiError{Error: "duplicate_room", Detail: name})
			return
		}
		afters[name] = after
		names = append(names, name)
	}
	if !s.bindDevice(w, c, device) {
		return
	}
	sub := s.changes.subscribe(names)
	defer s.changes.unsubscribe(sub)
	resp := watchResponse{Changed: []string{}}
	live := make([]string, 0, len(names))
	for _, name := range names {
		page, err := s.readEvents(name, device, afters[name], 1, nil)
		switch {
		case err == nil:
			if len(page.rows) > 0 || page.nextAfter > afters[name] {
				resp.Changed = append(resp.Changed, name)
			} else {
				live = append(live, name)
			}
		case errors.Is(err, errNoRoom):
			resp.setError(name, "no_such_room")
		case errors.Is(err, errClosed):
			resp.setError(name, "room_closed")
		default:
			log.Printf("watch room=%s device=%s: %v", name, device, err)
			s.fail(w, http.StatusInternalServerError, apiError{Error: "internal"})
			return
		}
	}
	if len(resp.Changed) == 0 && len(live) > 0 && wait > 0 && s.changes.acquire(device) {
		fired := false
		func() {
			defer s.changes.release(device)
			fired = s.changes.await(req.Context(), sub, s.typingCap(live, device, wait))
		}()
		if fired {
			for _, name := range s.changes.take(sub) {
				if _, refused := resp.Errors[name]; !refused {
					resp.Changed = append(resp.Changed, name)
				}
			}
		}
	}
	writeJSON(w, http.StatusOK, resp)
}

func (r *watchResponse) setError(room, code string) {
	if r.Errors == nil {
		r.Errors = map[string]string{}
	}
	r.Errors[room] = code
}
