// Read position shared across one actor's devices (#571 B). A device that has
// shown the room up to seq posts POST /v2/rooms/{room}/read {device, seq}; the
// relay keeps one row per (room, actor) — never per device — and every GET
// /events answer carries the caller's actor-wide value as `read_seq`, so the
// same person's phone stops showing the N badge once the PC has read the
// room. seq is relay metadata the relay already knows (the per-room total
// order), so nothing about the E2EE payload is exposed. The value only ever
// grows (max(current, posted)), is bounded by the room's last_seq and is
// accepted from tracked members only: the actor is taken from mls_members,
// which the commit gate pins to the policy actor (DEVICES-V4 G-H3), never
// from the device id's prefix or from the request body.
package main

import (
	"database/sql"
	"errors"
	"fmt"
	"log"
	"net/http"
	"time"
)

// readPost is the POST /v2/rooms/{room}/read body.
type readPost struct {
	Device string `json:"device"`
	Seq    int64  `json:"seq"`
}

// readResponse is the POST /read answer: the actor's read position after the
// request (the posted seq or the higher value another device already set).
type readResponse struct {
	ReadSeq int64 `json:"read_seq"`
}

// badReadSeq: a posted seq below 0 or above the room's last_seq (400).
type badReadSeq struct{ Seq, LastSeq int64 }

func (e badReadSeq) Error() string {
	return fmt.Sprintf("read seq %d outside 0..last_seq %d", e.Seq, e.LastSeq)
}

// handlePostRead records the caller's actor-wide read position. Same front
// half as every write route (room identifier, JWT, strict JSON, device
// identifier, subject binding); the store gate matches POST /typing (404 /
// 410 / 403 device_not_allowed / 403 not_a_member), then 400 bad_seq for a
// value outside 0..last_seq — membership verdict first, so the range check
// is no last_seq oracle for outsiders. 200 with the resulting read_seq.
func (s *relay) handlePostRead(w http.ResponseWriter, req *http.Request) {
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
	var post readPost
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
	seq, err := s.markRead(room, post.Device, post.Seq)
	var bad badReadSeq
	switch {
	case err == nil:
		writeJSON(w, http.StatusOK, readResponse{ReadSeq: seq})
	case errors.As(err, &bad):
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_seq", Detail: bad.Error()})
	case errors.Is(err, errNoRoom):
		s.fail(w, http.StatusNotFound, apiError{Error: "no_such_room"})
	case errors.Is(err, errClosed):
		s.fail(w, http.StatusGone, apiError{Error: "room_closed"})
	case errors.As(err, new(policyUnavailable)):
		log.Printf("post read room=%s: %v", room, err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "device_policy_unavailable", Detail: "device policy chain unreadable; writes fail closed"})
	case errors.As(err, new(deviceNotAllowed)):
		var na deviceNotAllowed
		errors.As(err, &na)
		s.fail(w, http.StatusForbidden, apiError{Error: "device_not_allowed", Detail: na.Error()})
	case errors.Is(err, errNotMember):
		s.fail(w, http.StatusForbidden, apiError{Error: "not_a_member"})
	default:
		log.Printf("post read room=%s device=%s: %v", room, post.Device, err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "internal"})
	}
}

// markRead is the store half of POST /read: the typingGate checks (room
// exists and is open, device policy-active), then the device must be a
// tracked member — its mls_members.actor is the key — and seq must lie in
// 0..last_seq. The row becomes max(current, seq) in one transaction and the
// resulting value is returned. A room without a seeded membership has no
// actor to key on (its founding commit seeds it), so it is errNotMember.
func (s *relay) markRead(room, device string, seq int64) (int64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	row, err := readRoom(tx, room)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, errNoRoom
	}
	if err != nil {
		return 0, err
	}
	if row.closed {
		return 0, errClosed
	}
	active, err := s.enforceDevicePolicy()
	if err != nil {
		return 0, err
	}
	if active != nil {
		if _, ok := active[device]; !ok {
			return 0, deviceNotAllowed{Device: device}
		}
	}
	tracked, err := readMembers(tx, room)
	if err != nil {
		return 0, err
	}
	actor := actorOfMember(tracked, device)
	if actor == "" {
		return 0, errNotMember
	}
	if seq < 0 || seq > row.lastSeq {
		return 0, badReadSeq{Seq: seq, LastSeq: row.lastSeq}
	}
	if _, err := tx.Exec(`INSERT INTO mls_read (room, actor, seq, updated_at) VALUES (?, ?, ?, ?)
		ON CONFLICT(room, actor) DO UPDATE SET seq = MAX(seq, excluded.seq), updated_at = excluded.updated_at`,
		room, actor, seq, time.Now().Unix()); err != nil {
		return 0, err
	}
	cur, err := readActorSeq(tx, room, actor)
	if err != nil {
		return 0, err
	}
	return cur, tx.Commit()
}

// actorOfMember returns the tracked member's actor, "" when device is not a
// tracked member of the room.
func actorOfMember(tracked []memberRow, device string) string {
	for _, m := range tracked {
		if m.Device == device {
			return m.Actor
		}
	}
	return ""
}

// readActorSeq returns the actor's read position in room, 0 when none.
func readActorSeq(q interface{ QueryRow(string, ...any) *sql.Row }, room, actor string) (int64, error) {
	var seq int64
	err := q.QueryRow(`SELECT seq FROM mls_read WHERE room = ? AND actor = ?`, room, actor).Scan(&seq)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	return seq, err
}
