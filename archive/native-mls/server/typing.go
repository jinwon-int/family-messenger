// Typing indicator relay part (#562 PR A). A device that is composing posts
// POST /v2/rooms/{room}/typing; every member's next GET /events carries the
// set of other devices still typing in the `typing` field. The state is
// memory-only and bounded: one map per room, at most maxMembers devices per
// room, entries expire after policy.TypingTTLSeconds and a device's refresh
// is ignored for one second after its last accepted set. Nothing here is
// persisted, pushed or logged per call — a typing signal that is lost on a
// restart is simply gone, which is the right outcome for a six-second hint.
package main

import (
	"errors"
	"log"
	"net/http"
	"sort"
	"sync"
	"time"
)

// typingRefreshFloorSeconds: a device's entry is only re-armed when its last
// accepted set is at least this old, so a client spamming the route cannot
// make the relay do more than one map write per device per second.
const typingRefreshFloorSeconds = 1

// typingEntry is one device's typing signal in a room.
type typingEntry struct {
	expires int64 // unix seconds after which the entry is gone
	setAt   int64 // unix seconds of the last accepted set (refresh floor)
}

// typingState holds every room's typing devices. It has its own mutex and is
// never touched under s.mu: the handlers call it after the store transaction
// has committed (or without any transaction at all).
type typingState struct {
	mu    sync.Mutex
	rooms map[string]map[string]typingEntry
}

// set records device as typing in room until now+ttl. A new device in a room
// that already holds maxMembers typing devices is dropped silently (the
// caller still answers 204); a refresh younger than typingRefreshFloorSeconds
// is ignored the same way.
func (t *typingState) set(room, device string, now, ttl int64) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.rooms == nil {
		t.rooms = map[string]map[string]typingEntry{}
	}
	devices := t.rooms[room]
	if devices == nil {
		devices = map[string]typingEntry{}
		t.rooms[room] = devices
	}
	if cur, ok := devices[device]; ok {
		if now-cur.setAt < typingRefreshFloorSeconds {
			return
		}
	} else if len(devices) >= maxMembers {
		return
	}
	devices[device] = typingEntry{expires: now + ttl, setAt: now}
}

// clear drops device's typing signal in room, if any.
func (t *typingState) clear(room, device string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	devices := t.rooms[room]
	if devices == nil {
		return
	}
	delete(devices, device)
	if len(devices) == 0 {
		delete(t.rooms, room)
	}
}

// snapshot returns the sorted ids of the devices typing in room at now,
// without exclude (the reader itself). Expired entries are dropped while
// scanning and an emptied room map is deleted, so the state never outgrows
// the live signals. The result is never nil (JSON `[]`, not `null`).
func (t *typingState) snapshot(room, exclude string, now int64) []string {
	out := []string{}
	t.mu.Lock()
	defer t.mu.Unlock()
	devices := t.rooms[room]
	if devices == nil {
		return out
	}
	for device, e := range devices {
		if e.expires <= now {
			delete(devices, device)
			continue
		}
		if device != exclude {
			out = append(out, device)
		}
	}
	if len(devices) == 0 {
		delete(t.rooms, room)
	}
	sort.Strings(out)
	return out
}

// typingPost is the POST /v2/rooms/{room}/typing body: the acting device and
// whether it stopped (clear) rather than started/kept typing.
type typingPost struct {
	Device string `json:"device"`
	Clear  bool   `json:"clear"`
}

// handlePostTyping records or clears the caller's typing signal. Same front
// half as every write route (room identifier, JWT, strict JSON, device
// identifier, subject binding) and the same store-side gate as consuming a
// key package — the room must exist and be open, the device policy-active
// and, once the room has a membership, a tracked member — but no row is
// written, no push is sent and nothing is logged per call. 204 on success.
func (s *relay) handlePostTyping(w http.ResponseWriter, req *http.Request) {
	room, ok := s.roomParam(w, req)
	if !ok {
		return
	}
	c, ok := s.authenticate(w, req)
	if !ok {
		return
	}
	body, ok := s.readBody(w, req)
	if !ok {
		return
	}
	var post typingPost
	if err := strictJSON(body, &post); err != nil {
		s.failJSON(w, err)
		return
	}
	if post.Device == "" {
		s.fail(w, http.StatusBadRequest, apiError{Error: "device_required"})
		return
	}
	if !validIdentifier(post.Device) {
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_identifier", Detail: "device"})
		return
	}
	if !s.bindDevice(w, c, post.Device) {
		return
	}
	err := s.typingGate(room, post.Device)
	switch {
	case err == nil:
		if post.Clear {
			s.typing.clear(room, post.Device)
		} else {
			s.typing.set(room, post.Device, time.Now().Unix(), s.policy.TypingTTLSeconds)
		}
		w.WriteHeader(http.StatusNoContent)
	case errors.Is(err, errNoRoom):
		s.fail(w, http.StatusNotFound, apiError{Error: "no_such_room"})
	case errors.Is(err, errClosed):
		s.fail(w, http.StatusGone, apiError{Error: "room_closed"})
	case errors.As(err, new(policyUnavailable)):
		log.Printf("post typing room=%s: %v", room, err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "device_policy_unavailable", Detail: "device policy chain unreadable; writes fail closed"})
	case errors.As(err, new(deviceNotAllowed)):
		var na deviceNotAllowed
		errors.As(err, &na)
		s.fail(w, http.StatusForbidden, apiError{Error: "device_not_allowed", Detail: na.Error()})
	case errors.Is(err, errNotMember):
		s.fail(w, http.StatusForbidden, apiError{Error: "not_a_member"})
	default:
		log.Printf("post typing room=%s device=%s: %v", room, post.Device, err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "internal"})
	}
}
