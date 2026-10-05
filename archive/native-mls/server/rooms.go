package main

import (
	"log"
	"net/http"
	"time"
)

// GET /v2/rooms?device= (#275 L2 ①, CONTRACTS §2.3): the rooms one device
// takes part in, public fields only — no events, rosters or key material. The
// device must belong to the JWT subject (bindDevice: 403 device_subject_mismatch
// otherwise), so one person cannot enumerate another's rooms.

// roomListing mirrors FamilyMLSCore RoomListing; every key is always present.
type roomListing struct {
	Room                   string `json:"room"`
	Epoch                  int64  `json:"epoch"`
	Revision               int64  `json:"revision"`
	Member                 bool   `json:"member"`
	KeyPackagesOutstanding int    `json:"keypackages_outstanding"`
	Closed                 bool   `json:"closed"`
}

type roomsResponse struct {
	Rooms []roomListing `json:"rooms"`
}

// maxListedRooms bounds the response; a device past it is far outside the
// family use (rooms-max-per-device caps creation at a much lower number).
const maxListedRooms = 500

func (s *relay) handleListRooms(w http.ResponseWriter, req *http.Request) {
	c, ok := s.authenticate(w, req)
	if !ok {
		return
	}
	device := req.URL.Query().Get("device")
	if device == "" {
		s.fail(w, http.StatusBadRequest, apiError{Error: "device_required"})
		return
	}
	if !validIdentifier(device) {
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_identifier", Detail: "device"})
		return
	}
	if !s.bindDevice(w, c, device) {
		return
	}
	rooms, err := s.listRooms(device, time.Now().Unix())
	if err != nil {
		log.Printf("list rooms device=%s: %v", device, err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "internal"})
		return
	}
	writeJSON(w, http.StatusOK, roomsResponse{Rooms: rooms})
}

// listRooms returns every room where the device is a tracked member, holds a
// cursor (it posted, was a Welcome target, or acked), or has key packages.
// member: a tracked member when the room has tracked membership (M3b on);
// otherwise a cursor that was not removed by a commit. Closed rooms are listed
// with closed=true so the client can drop them.
func (s *relay) listRooms(device string, now int64) ([]roomListing, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	rows, err := tx.Query(`
SELECT r.room, r.epoch, r.revision, r.closed_at IS NOT NULL,
       EXISTS (SELECT 1 FROM mls_members m WHERE m.room = r.room AND m.device = ?1),
       EXISTS (SELECT 1 FROM mls_members m WHERE m.room = r.room),
       EXISTS (SELECT 1 FROM mls_cursors c WHERE c.room = r.room AND c.device = ?1 AND c.removed_at IS NULL),
       (SELECT COUNT(*) FROM mls_keypackages k
         WHERE k.room = r.room AND k.device = ?1 AND k.consumed_by IS NULL AND k.expires_at > ?2)
FROM mls_rooms r
WHERE EXISTS (SELECT 1 FROM mls_members m WHERE m.room = r.room AND m.device = ?1)
   OR EXISTS (SELECT 1 FROM mls_cursors c WHERE c.room = r.room AND c.device = ?1)
   OR EXISTS (SELECT 1 FROM mls_keypackages k WHERE k.room = r.room AND k.device = ?1)
ORDER BY r.room
LIMIT ?3`, device, now, maxListedRooms)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []roomListing{}
	for rows.Next() {
		var l roomListing
		var tracked, anyTracked, liveCursor bool
		if err := rows.Scan(&l.Room, &l.Epoch, &l.Revision, &l.Closed, &tracked, &anyTracked, &liveCursor, &l.KeyPackagesOutstanding); err != nil {
			return nil, err
		}
		l.Member = tracked || (!anyTracked && liveCursor)
		out = append(out, l)
	}
	return out, rows.Err()
}
