// Per-room notification setting shared across one actor's devices. A member
// device posts POST /v2/rooms/{room}/mute {device, muted}; the relay keeps one
// row per (room, actor) — present = muted — and every GET /events answer
// carries the caller's actor-wide value as `muted`, so turning a room's alerts
// off on the PC also silences the same person's phone. Push delivery
// (push.go pushTargets) skips every device of a muted actor for application
// events; a welcome still pushes (it is how a new device gets invited, and a
// new room has no mute row yet). Like the read position (read.go) the actor
// comes from mls_members, never from the request body or the device id, and
// the flag is relay metadata only — nothing about the E2EE payload is exposed.
package main

import (
	"database/sql"
	"errors"
	"log"
	"net/http"
	"time"
)

// mutePost is the POST /v2/rooms/{room}/mute body. Muted is a pointer so a
// body without it is refused (400 muted_required) instead of meaning "on".
type mutePost struct {
	Device string `json:"device"`
	Muted  *bool  `json:"muted"`
}

// muteResponse is the POST /mute answer: the actor's setting after the request.
type muteResponse struct {
	Muted bool `json:"muted"`
}

// handlePostMute records the caller's actor-wide notification setting. Same
// front half as POST /read (room identifier, JWT, strict JSON, device
// identifier, subject binding) and the same store gate (404 / 410 / 403
// device_not_allowed / 403 not_a_member). 200 with the resulting value.
func (s *relay) handlePostMute(w http.ResponseWriter, req *http.Request) {
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
	var post mutePost
	if err := strictJSON(body, &post); err != nil {
		s.failJSON(w, err)
		return
	}
	switch {
	case post.Device == "":
		s.fail(w, http.StatusBadRequest, apiError{Error: "device_required"})
		return
	case !validIdentifier(post.Device):
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_identifier", Detail: "device"})
		return
	case post.Muted == nil:
		s.fail(w, http.StatusBadRequest, apiError{Error: "muted_required"})
		return
	}
	if !s.bindDevice(w, c, post.Device) {
		return
	}
	muted, err := s.setMute(room, post.Device, *post.Muted)
	switch {
	case err == nil:
		writeJSON(w, http.StatusOK, muteResponse{Muted: muted})
	case errors.Is(err, errNoRoom):
		s.fail(w, http.StatusNotFound, apiError{Error: "no_such_room"})
	case errors.Is(err, errClosed):
		s.fail(w, http.StatusGone, apiError{Error: "room_closed"})
	case errors.As(err, new(policyUnavailable)):
		log.Printf("post mute room=%s: %v", room, err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "device_policy_unavailable", Detail: "device policy chain unreadable; writes fail closed"})
	case errors.As(err, new(deviceNotAllowed)):
		var na deviceNotAllowed
		errors.As(err, &na)
		s.fail(w, http.StatusForbidden, apiError{Error: "device_not_allowed", Detail: na.Error()})
	case errors.Is(err, errNotMember):
		s.fail(w, http.StatusForbidden, apiError{Error: "not_a_member"})
	default:
		log.Printf("post mute room=%s device=%s: %v", room, post.Device, err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "internal"})
	}
}

// setMute is the store half of POST /mute: the markRead gate (room exists and
// is open, device policy-active, tracked member — its actor is the key), then
// one insert-or-delete in the same transaction. Idempotent both ways.
func (s *relay) setMute(room, device string, muted bool) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	row, err := readRoom(tx, room)
	if errors.Is(err, sql.ErrNoRows) {
		return false, errNoRoom
	}
	if err != nil {
		return false, err
	}
	if row.closed {
		return false, errClosed
	}
	active, err := s.enforceDevicePolicy()
	if err != nil {
		return false, err
	}
	if active != nil {
		if _, ok := active[device]; !ok {
			return false, deviceNotAllowed{Device: device}
		}
	}
	tracked, err := readMembers(tx, room)
	if err != nil {
		return false, err
	}
	actor := actorOfMember(tracked, device)
	if actor == "" {
		return false, errNotMember
	}
	if muted {
		_, err = tx.Exec(`INSERT INTO mls_mute (room, actor, updated_at) VALUES (?, ?, ?)
			ON CONFLICT(room, actor) DO UPDATE SET updated_at = excluded.updated_at`, room, actor, time.Now().Unix())
	} else {
		_, err = tx.Exec(`DELETE FROM mls_mute WHERE room = ? AND actor = ?`, room, actor)
	}
	if err != nil {
		return false, err
	}
	cur, err := readActorMuted(tx, room, actor)
	if err != nil {
		return false, err
	}
	return cur, tx.Commit()
}

// readActorMuted reports whether the actor muted the room.
func readActorMuted(q interface{ QueryRow(string, ...any) *sql.Row }, room, actor string) (bool, error) {
	var one int
	err := q.QueryRow(`SELECT 1 FROM mls_mute WHERE room = ? AND actor = ?`, room, actor).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}
