// Room list order shared across one actor's devices (room-order v1, #715).
// Until now each client kept its own order (iOS UserDefaults, web
// localStorage), so a new device started from a different list. The relay now
// keeps one row per actor:
//
//   - GET /v2/me/room-order?device=<id>
//     200 {"rooms":[…],"revision":N,"updated_at":<unix>}; never stored is
//     {"rooms":[],"revision":0,"updated_at":0}.
//   - PUT /v2/me/room-order {"device","rooms","base_revision"}
//     base_revision == current → stored, 200 with revision current+1;
//     otherwise 409 {"error":"revision_conflict","rooms","revision","updated_at"}
//     carrying the current value so the client adopts it.
//
// Authentication and actor resolution follow /v2/me and POST /read·/mute:
// the JWT is verified, the device identifier checked, and bindDevice requires
// a policy-active device whose subject is the JWT subject (403
// device_subject_mismatch for unknown, revoked and foreign devices alike).
// The order is not per room, so the actor comes from the device-policy chain
// record of that device (policyActor) — never from mls_members, the request
// body or the device id prefix. Room ids are validIdentifier strings (at most
// maxRoomOrderRooms, no duplicates); they are not checked against
// membership, so the relay learns nothing new and reveals nothing: the client
// filters the list to its own rooms. Relay metadata only — nothing about the
// E2EE payload. An older relay answers 404 and clients keep their local order.
package main

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"time"
)

const (
	roomOrderPath = mePath + "/room-order"
	// maxRoomOrderRooms bounds one actor's stored order (#715).
	maxRoomOrderRooms = 64
)

// roomOrderPut is the PUT body. Rooms and BaseRevision are pointers so a body
// without them is refused instead of meaning "empty list" / "revision 0".
type roomOrderPut struct {
	Device       string    `json:"device"`
	Rooms        *[]string `json:"rooms"`
	BaseRevision *int64    `json:"base_revision"`
}

// roomOrder is the GET/PUT answer; Rooms is never null on the wire.
type roomOrder struct {
	Rooms     []string `json:"rooms"`
	Revision  int64    `json:"revision"`
	UpdatedAt int64    `json:"updated_at"`
}

// roomOrderConflict is the 409 body: the error code plus the current value.
// Its own type (not apiError) because revision 0 must stay on the wire.
type roomOrderConflict struct {
	Error string `json:"error"`
	roomOrder
}

// errRevisionConflict carries the stored order when base_revision is stale.
type errRevisionConflict struct{ current roomOrder }

func (e errRevisionConflict) Error() string {
	return fmt.Sprintf("room order revision conflict (current %d)", e.current.Revision)
}

func noStore(w http.ResponseWriter) {
	h := w.Header()
	h.Set("Cache-Control", "no-store")
	h.Set("X-Content-Type-Options", "nosniff")
}

// handleGetRoomOrder answers the caller actor's stored order.
func (s *relay) handleGetRoomOrder(w http.ResponseWriter, req *http.Request) {
	noStore(w)
	c, ok := s.authenticate(w, req)
	if !ok {
		return
	}
	device := req.URL.Query().Get("device")
	switch {
	case device == "":
		s.fail(w, http.StatusBadRequest, apiError{Error: "device_required"})
		return
	case !validIdentifier(device):
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_identifier", Detail: "device"})
		return
	}
	if !s.bindDevice(w, c, device) {
		return
	}
	order, err := s.readRoomOrder(device)
	if err != nil {
		s.failRoomOrder(w, "get", device, err)
		return
	}
	writeJSON(w, http.StatusOK, order)
}

// handlePutRoomOrder stores the caller actor's order under a revision CAS.
func (s *relay) handlePutRoomOrder(w http.ResponseWriter, req *http.Request) {
	noStore(w)
	c, ok := s.authenticate(w, req)
	if !ok {
		return
	}
	body, ok := s.readBody(w, req)
	if !ok {
		return
	}
	var put roomOrderPut
	if err := strictJSON(body, &put); err != nil {
		s.failJSON(w, err)
		return
	}
	switch {
	case put.Device == "":
		s.fail(w, http.StatusBadRequest, apiError{Error: "device_required"})
		return
	case !validIdentifier(put.Device):
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_identifier", Detail: "device"})
		return
	case put.Rooms == nil:
		s.fail(w, http.StatusBadRequest, apiError{Error: "rooms_required"})
		return
	case put.BaseRevision == nil:
		s.fail(w, http.StatusBadRequest, apiError{Error: "base_revision_required"})
		return
	case *put.BaseRevision < 0:
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_request", Detail: "base_revision must be >= 0"})
		return
	case len(*put.Rooms) > maxRoomOrderRooms:
		s.fail(w, http.StatusBadRequest, apiError{Error: "too_many_rooms", Max: maxRoomOrderRooms})
		return
	}
	rooms := *put.Rooms
	seen := make(map[string]struct{}, len(rooms))
	for _, room := range rooms {
		if !validIdentifier(room) {
			s.fail(w, http.StatusBadRequest, apiError{Error: "bad_identifier", Detail: "rooms"})
			return
		}
		if _, dup := seen[room]; dup {
			s.fail(w, http.StatusBadRequest, apiError{Error: "duplicate_room", Detail: room})
			return
		}
		seen[room] = struct{}{}
	}
	if !s.bindDevice(w, c, put.Device) {
		return
	}
	order, err := s.writeRoomOrder(put.Device, rooms, *put.BaseRevision)
	var conflict errRevisionConflict
	switch {
	case err == nil:
		writeJSON(w, http.StatusOK, order)
	case errors.As(err, &conflict):
		writeJSON(w, http.StatusConflict, roomOrderConflict{Error: "revision_conflict", roomOrder: conflict.current})
	default:
		s.failRoomOrder(w, "put", put.Device, err)
	}
}

// failRoomOrder maps the store errors shared by GET and PUT.
func (s *relay) failRoomOrder(w http.ResponseWriter, op, device string, err error) {
	switch {
	case errors.As(err, new(policyUnavailable)):
		log.Printf("room order %s device=%s: %v", op, device, err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "device_policy_unavailable", Detail: "device policy chain unreadable; writes fail closed"})
	case errors.As(err, new(deviceNotAllowed)):
		var na deviceNotAllowed
		errors.As(err, &na)
		s.fail(w, http.StatusForbidden, apiError{Error: "device_not_allowed", Detail: na.Error()})
	default:
		log.Printf("room order %s device=%s: %v", op, device, err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "internal"})
	}
}

// policyActor is the actor of device's active device-policy record — the
// second line after bindDevice (a revoke between the two is
// device_not_allowed). Without a chain there is no actor to key on; the
// routes are not registered then, this only fails closed.
func (s *relay) policyActor(device string) (string, error) {
	active, err := s.enforceDevicePolicy()
	if err != nil {
		return "", err
	}
	d, ok := active[device]
	if !ok || d.Actor == "" {
		return "", deviceNotAllowed{Device: device}
	}
	return d.Actor, nil
}

func (s *relay) readRoomOrder(device string) (roomOrder, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	actor, err := s.policyActor(device)
	if err != nil {
		return roomOrder{}, err
	}
	return selectRoomOrder(s.db, actor)
}

// writeRoomOrder is the CAS: read the actor's row and store rooms as
// revision+1 only when base matches, in one BEGIN IMMEDIATE transaction.
func (s *relay) writeRoomOrder(device string, rooms []string, base int64) (roomOrder, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	actor, err := s.policyActor(device)
	if err != nil {
		return roomOrder{}, err
	}
	tx, err := s.db.Begin()
	if err != nil {
		return roomOrder{}, err
	}
	defer tx.Rollback()
	cur, err := selectRoomOrder(tx, actor)
	if err != nil {
		return roomOrder{}, err
	}
	if cur.Revision != base {
		return roomOrder{}, errRevisionConflict{current: cur}
	}
	encoded, err := json.Marshal(rooms)
	if err != nil {
		return roomOrder{}, err
	}
	next := roomOrder{Rooms: rooms, Revision: cur.Revision + 1, UpdatedAt: time.Now().Unix()}
	if _, err := tx.Exec(`INSERT INTO actor_room_order (actor, rooms, revision, updated_at) VALUES (?, ?, ?, ?)
		ON CONFLICT(actor) DO UPDATE SET rooms = excluded.rooms, revision = excluded.revision, updated_at = excluded.updated_at`,
		actor, string(encoded), next.Revision, next.UpdatedAt); err != nil {
		return roomOrder{}, err
	}
	return next, tx.Commit()
}

// selectRoomOrder reads the actor's row; no row is the empty revision-0 order.
func selectRoomOrder(q interface{ QueryRow(string, ...any) *sql.Row }, actor string) (roomOrder, error) {
	var raw string
	order := roomOrder{Rooms: []string{}}
	err := q.QueryRow(`SELECT rooms, revision, updated_at FROM actor_room_order WHERE actor = ?`, actor).
		Scan(&raw, &order.Revision, &order.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return order, nil
	}
	if err != nil {
		return roomOrder{}, err
	}
	if err := json.Unmarshal([]byte(raw), &order.Rooms); err != nil {
		return roomOrder{}, fmt.Errorf("decode actor_room_order rooms for %s: %w", actor, err)
	}
	if order.Rooms == nil {
		order.Rooms = []string{}
	}
	return order, nil
}
