package chat

// Synthetic transport framing only. The server cannot verify opaque MLS bytes.
import (
	"bytes"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"sort"

	"github.com/jinwon-int/family-messenger/server/internal/access"
)

const MLSMaxWire = 65536
const MLSMaxEvents = 1024
const MLSMaxRoomEvents = 256
const MLSMaxBytes = 32 * 1024 * 1024

type MLSPin struct {
	ID       string `json:"device_id"`
	Actor    string `json:"actor"`
	Key      string `json:"signing_key"`
	Revision uint64 `json:"device_revision"`
}
type MLSRoom struct {
	Room     string   `json:"room"`
	Group    string   `json:"group_id"`
	Creator  string   `json:"creator_device"`
	Peer     string   `json:"peer_device"`
	Pins     []MLSPin `json:"pins"`
	Revision int64    `json:"revision"`
	Epoch    int64    `json:"epoch"`
	Phase    string   `json:"phase"`
	Next     int64    `json:"next_seq"`
}
type MLSRequest struct {
	ID       string `json:"client_id"`
	Device   string `json:"device_id"`
	Group    string `json:"group_id"`
	Kind     string `json:"kind"`
	Revision int64  `json:"expected_revision"`
	Epoch    int64  `json:"epoch"`
	Target   string `json:"target_device"`
	Payload  []byte `json:"payload"`
}
type MLSEvent struct {
	Seq      int64      `json:"seq"`
	Room     string     `json:"room"`
	Request  MLSRequest `json:"request"`
	Revision int64      `json:"revision"`
	Epoch    int64      `json:"epoch"`
	SHA256   string     `json:"sha256"`
}
type mlsCreate struct {
	Room   string `json:"room"`
	Group  string `json:"group_id"`
	Device string `json:"device_id"`
	Peer   string `json:"peer_device"`
}

func migrateMLS(db *sql.DB, dir string, fresh bool) error {
	if !fresh {
		if e := snapshotSchema(db, dir, "v2-before-mls-"); e != nil {
			return e
		}
	}
	_, e := db.Exec(`BEGIN IMMEDIATE;
 CREATE TABLE mls_rooms(room TEXT PRIMARY KEY REFERENCES rooms(id), group_id TEXT UNIQUE, creator TEXT NOT NULL, peer TEXT NOT NULL, pins BLOB NOT NULL, revision INTEGER NOT NULL, epoch INTEGER NOT NULL, phase TEXT NOT NULL, next_seq INTEGER NOT NULL);
 CREATE TABLE mls_events(room TEXT NOT NULL REFERENCES mls_rooms(room), seq INTEGER NOT NULL, device TEXT NOT NULL, client_id TEXT NOT NULL, request BLOB NOT NULL, sha256 TEXT NOT NULL, revision INTEGER NOT NULL, epoch INTEGER NOT NULL, PRIMARY KEY(room,seq), UNIQUE(room,device,client_id));
 PRAGMA user_version=3; COMMIT;`)
	return e
}
func (s *Store) legacyRoom(room string) error {
	var n int
	if e := s.db.QueryRow("SELECT count(*) FROM mls_rooms WHERE room=?", room).Scan(&n); e != nil {
		return e
	}
	if n != 0 {
		return ErrForbidden
	}
	return nil
}
func canonicalGroup(v string) bool {
	b, e := hex.DecodeString(v)
	return e == nil && len(b) >= 16 && len(b) <= 128 && hex.EncodeToString(b) == v
}
func digestMLS(raw []byte) string { h := sha256.Sum256(raw); return hex.EncodeToString(h[:]) }
func activePin(devices []access.Device, id string) (MLSPin, error) {
	for _, d := range devices {
		if d.ID == id && d.Status == "active" && d.Revision == 1 {
			return MLSPin{d.ID, d.Actor, d.SigningKey, d.Revision}, nil
		}
	}
	return MLSPin{}, ErrForbidden
}
func (s *Store) mlsRoom(room string) (MLSRoom, error) {
	var out MLSRoom
	var pins []byte
	e := s.db.QueryRow("SELECT room,coalesce(group_id,''),creator,peer,pins,revision,epoch,phase,next_seq FROM mls_rooms WHERE room=?", room).Scan(&out.Room, &out.Group, &out.Creator, &out.Peer, &pins, &out.Revision, &out.Epoch, &out.Phase, &out.Next)
	if e == sql.ErrNoRows {
		return out, ErrForbidden
	}
	if e != nil {
		return out, e
	}
	if len(pins) > 2048 || json.Unmarshal(pins, &out.Pins) != nil || (len(out.Pins) != 2 && !(out.Phase == "reserved" && len(out.Pins) == 0)) {
		return out, ErrIntegrity
	}
	return out, nil
}

// Called only inside Grant.Run then Store.mu. A CF principal does not prove
// possession of a device key; recipient MLS validation remains mandatory.
func (s *Store) mlsAdmit(room MLSRoom, actor, device string, devices []access.Device) error {
	if room.Phase == "reserved" {
		return ErrForbidden
	}
	if !validID(device) {
		return ErrInvalid
	}
	own, err := activePin(devices, device)
	if err != nil || own.Actor != actor {
		return ErrForbidden
	}
	found := false
	for _, pin := range room.Pins {
		current, e := activePin(devices, pin.ID)
		if e != nil || current != pin {
			return ErrForbidden
		}
		if pin.ID == device {
			found = true
		}
		if e = s.member(room.Room, pin.Actor); e != nil {
			return e
		}
	}
	if !found {
		return ErrForbidden
	}
	return nil
}
func (s *Store) createMLS(q mlsCreate, actor string, devices []access.Device) (MLSRoom, bool, error) {
	if !validID(q.Room) || !canonicalGroup(q.Group) || !validID(q.Device) || !validID(q.Peer) || q.Device == q.Peer {
		return MLSRoom{}, false, ErrInvalid
	}
	own, e := activePin(devices, q.Device)
	if e != nil || own.Actor != actor {
		return MLSRoom{}, false, ErrForbidden
	}
	peer, e := activePin(devices, q.Peer)
	if e != nil || peer.Actor == actor {
		return MLSRoom{}, false, ErrForbidden
	}
	pins := []MLSPin{own, peer}
	sort.Slice(pins, func(i, j int) bool { return pins[i].ID < pins[j].ID })
	var exists int
	if e = s.db.QueryRow("SELECT count(*) FROM rooms WHERE id=?", q.Room).Scan(&exists); e != nil {
		return MLSRoom{}, false, e
	}
	reserved := false
	if exists != 0 {
		old, e := s.mlsRoom(q.Room)
		if e != nil {
			return MLSRoom{}, false, ErrConflict
		}
		if old.Phase == "reserved" {
			var owner string
			var count int
			if e = s.db.QueryRow("SELECT owner FROM rooms WHERE id=?", q.Room).Scan(&owner); e != nil {
				return MLSRoom{}, false, e
			}
			if e = s.db.QueryRow("SELECT count(*) FROM members WHERE room=?", q.Room).Scan(&count); e != nil {
				return MLSRoom{}, false, e
			}
			if owner != actor || count != 2 || s.member(q.Room, peer.Actor) != nil {
				return MLSRoom{}, false, ErrForbidden
			}
			reserved = true
		} else {
			if e = s.mlsAdmit(old, actor, q.Device, devices); e != nil {
				return MLSRoom{}, false, e
			}
			if old.Group != q.Group || old.Creator != q.Device || old.Peer != q.Peer {
				return MLSRoom{}, false, ErrConflict
			}
			return old, false, nil
		}
	}

	if e = s.db.QueryRow("SELECT count(*) FROM mls_rooms WHERE group_id=?", q.Group).Scan(&exists); e != nil {
		return MLSRoom{}, false, e
	}
	if exists != 0 {
		return MLSRoom{}, false, ErrConflict
	}
	if e = s.db.QueryRow("SELECT count(*) FROM rooms").Scan(&exists); e != nil {
		return MLSRoom{}, false, e
	}
	if exists >= 32 && !reserved {
		return MLSRoom{}, false, ErrLimit
	}
	raw, _ := json.Marshal(pins)
	tx, e := s.db.Begin()
	if e != nil {
		return MLSRoom{}, false, e
	}
	defer tx.Rollback()
	if !reserved {
		if _, e = tx.Exec("INSERT INTO rooms(id,owner) VALUES(?,?)", q.Room, actor); e != nil {
			return MLSRoom{}, false, e
		}
		for _, p := range pins {
			if _, e = tx.Exec("INSERT INTO members VALUES(?,?)", q.Room, p.Actor); e != nil {
				return MLSRoom{}, false, e
			}
		}
		if _, e = tx.Exec("INSERT INTO mls_rooms VALUES(?,?,?,?,?,0,0,'key-package',1)", q.Room, q.Group, q.Device, q.Peer, raw); e != nil {
			return MLSRoom{}, false, e
		}
	} else {
		if _, e = tx.Exec("UPDATE mls_rooms SET group_id=?,creator=?,peer=?,pins=?,phase='key-package' WHERE room=?", q.Group, q.Device, q.Peer, raw, q.Room); e != nil {
			return MLSRoom{}, false, e
		}
	}

	if e = tx.Commit(); e != nil {
		return MLSRoom{}, false, e
	}
	s.wake()
	return MLSRoom{q.Room, q.Group, q.Device, q.Peer, pins, 0, 0, "key-package", 1}, true, nil
}
func validMLSRequest(q MLSRequest) bool {
	return validID(q.ID) && validID(q.Device) && canonicalGroup(q.Group) && q.Revision >= 0 && q.Revision <= MLSMaxRoomEvents && q.Epoch >= 0 && q.Epoch <= MLSMaxRoomEvents && len(q.Payload) <= MLSMaxWire && (q.Target == "" || validID(q.Target)) && (q.Kind == "key_package" || q.Kind == "welcome" || q.Kind == "ack" || q.Kind == "commit" || q.Kind == "application")
}
func eventMLS(room string, seq, revision, epoch int64, raw []byte, hash string) (MLSEvent, error) {
	var q MLSRequest
	if len(raw) > 96*1024 || digestMLS(raw) != hash || json.Unmarshal(raw, &q) != nil || !validMLSRequest(q) {
		return MLSEvent{}, ErrIntegrity
	}
	return MLSEvent{seq, room, q, revision, epoch, hash}, nil
}
func (s *Store) appendMLS(room MLSRoom, q MLSRequest) (MLSEvent, bool, error) {
	if !validMLSRequest(q) || q.Group != room.Group {
		return MLSEvent{}, false, ErrInvalid
	}
	raw, _ := json.Marshal(q)
	hash := digestMLS(raw)
	var priorRaw []byte
	var priorHash string
	var seq, revision, epoch int64
	e := s.db.QueryRow("SELECT seq,request,sha256,revision,epoch FROM mls_events WHERE room=? AND device=? AND client_id=?", room.Room, q.Device, q.ID).Scan(&seq, &priorRaw, &priorHash, &revision, &epoch)
	if e == nil {
		prior, e := eventMLS(room.Room, seq, revision, epoch, priorRaw, priorHash)
		if e != nil {
			return MLSEvent{}, false, e
		}
		if !bytes.Equal(raw, priorRaw) {
			return MLSEvent{}, false, ErrConflict
		}
		return prior, false, nil
	}
	if e != sql.ErrNoRows {
		return MLSEvent{}, false, e
	}
	if q.Revision != room.Revision || q.Epoch != room.Epoch {
		return MLSEvent{}, false, ErrConflict
	}
	phase := room.Phase
	revision = room.Revision
	epoch = room.Epoch
	switch q.Kind {
	case "key_package":
		if phase != "key-package" || q.Device != room.Peer || q.Target != room.Creator || len(q.Payload) == 0 {
			return MLSEvent{}, false, ErrConflict
		}
		phase = "welcome"
		revision++
	case "welcome":
		if phase != "welcome" || q.Device != room.Creator || q.Target != room.Peer || len(q.Payload) == 0 {
			return MLSEvent{}, false, ErrConflict
		}
		phase = "ack"
		epoch++
		revision++
	case "ack":
		if phase != "ack" || q.Device != room.Peer || q.Target != room.Creator || len(q.Payload) != 0 {
			return MLSEvent{}, false, ErrConflict
		}
		phase = "ready"
		revision++
	case "commit":
		if phase != "ready" || q.Device != room.Creator || q.Target != room.Peer || len(q.Payload) == 0 {
			return MLSEvent{}, false, ErrConflict
		}
		phase = "ack"
		epoch++
		revision++
	case "application":
		if phase != "ready" || q.Target != "" || len(q.Payload) == 0 {
			return MLSEvent{}, false, ErrConflict
		}
	}
	var count, size int
	if e = s.db.QueryRow("SELECT count(*),coalesce(sum(length(request)),0) FROM mls_events").Scan(&count, &size); e != nil {
		return MLSEvent{}, false, e
	}
	if room.Next > MLSMaxRoomEvents || count >= MLSMaxEvents || size+len(raw) > MLSMaxBytes {
		return MLSEvent{}, false, ErrLimit
	}
	tx, e := s.db.Begin()
	if e != nil {
		return MLSEvent{}, false, e
	}
	defer tx.Rollback()
	if _, e = tx.Exec("INSERT INTO mls_events VALUES(?,?,?,?,?,?,?,?)", room.Room, room.Next, q.Device, q.ID, raw, hash, revision, epoch); e != nil {
		return MLSEvent{}, false, e
	}
	if _, e = tx.Exec("UPDATE mls_rooms SET revision=?,epoch=?,phase=?,next_seq=next_seq+1 WHERE room=?", revision, epoch, phase, room.Room); e != nil {
		return MLSEvent{}, false, e
	}
	if e = tx.Commit(); e != nil {
		return MLSEvent{}, false, e
	}
	s.wake()
	return MLSEvent{room.Next, room.Room, q, revision, epoch, hash}, true, nil
}
func (s *Store) mlsHistory(room MLSRoom, device string, after int64) ([]MLSEvent, error) {
	if after < 0 || after >= room.Next {
		return nil, ErrInvalid
	}
	rows, e := s.db.Query("SELECT seq,request,sha256,revision,epoch FROM mls_events WHERE room=? AND seq>? ORDER BY seq LIMIT 8", room.Room, after)
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	out := []MLSEvent{}
	for rows.Next() {
		var seq, rev, epoch int64
		var raw []byte
		var hash string
		if e = rows.Scan(&seq, &raw, &hash, &rev, &epoch); e != nil {
			return nil, e
		}
		event, e := eventMLS(room.Room, seq, rev, epoch, raw, hash)
		if e != nil {
			return nil, e
		}
		if event.Request.Target != "" && event.Request.Target != device && event.Request.Device != device {
			return nil, ErrForbidden
		}
		out = append(out, event)
	}
	return out, rows.Err()
}

// Exact top-level keys, including duplicates/case/Unicode aliases; no implicit
// zero-valued omitted fields. This endpoint's schema is flat except raw bytes.
func decodeMLS(w http.ResponseWriter, r *http.Request, out any, keys ...string) bool {
	if r.Header.Get("Content-Type") != "application/json" {
		http.Error(w, "application/json required", 415)
		return false
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 96*1024))
	tok, e := dec.Token()
	if e != nil || tok != json.Delim('{') {
		fail(w, ErrInvalid)
		return false
	}
	allowed := map[string]bool{}
	for _, k := range keys {
		allowed[k] = true
	}
	fields := map[string]json.RawMessage{}
	for dec.More() {
		tok, e = dec.Token()
		key, ok := tok.(string)
		if e != nil || !ok || !allowed[key] || fields[key] != nil {
			fail(w, ErrInvalid)
			return false
		}
		var value json.RawMessage
		if dec.Decode(&value) != nil || bytes.Equal(value, []byte("null")) {
			fail(w, ErrInvalid)
			return false
		}
		fields[key] = value
	}
	if _, e = dec.Token(); e != nil || len(fields) != len(keys) {
		fail(w, ErrInvalid)
		return false
	}
	if dec.Decode(new(any)) != io.EOF {
		fail(w, ErrInvalid)
		return false
	}
	raw, _ := json.Marshal(fields)
	if json.Unmarshal(raw, out) != nil {
		fail(w, ErrInvalid)
		return false
	}
	return true
}
func (a *API) mlsRoute(w http.ResponseWriter, r *http.Request, actor string, parts []string) {
	g, ok := r.Context().Value(grantKey{}).(*access.Grant)
	if !ok {
		fail(w, ErrForbidden)
		return
	}
	if len(parts) == 3 && parts[2] == "reservations" && r.Method == "POST" {
		if r.URL.RawQuery != "" {
			fail(w, ErrInvalid)
			return
		}
		var q struct {
			Room string `json:"room"`
			Peer string `json:"peer_actor"`
		}
		if !decodeMLS(w, r, &q, "room", "peer_actor") {
			return
		}
		a.store.mu.Lock()
		defer a.store.mu.Unlock()
		created, e := a.store.reserveMLS(q.Room, actor, q.Peer)
		if e != nil {
			fail(w, e)
			return
		}
		code := 200
		if created {
			code = 201
		}
		writeJSON(w, code, map[string]string{"room": q.Room, "phase": "reserved"})
		return
	}
	if len(parts) < 3 || parts[2] != "rooms" {
		http.NotFound(w, r)
		return
	}
	if len(parts) == 3 && r.Method == "POST" {
		if r.URL.RawQuery != "" {
			fail(w, ErrInvalid)
			return
		}
		var q mlsCreate
		if !decodeMLS(w, r, &q, "room", "group_id", "device_id", "peer_device") {
			return
		}
		a.store.mu.Lock()
		defer a.store.mu.Unlock()
		room, created, e := a.store.createMLS(q, actor, g.DeviceBindings())
		if e != nil {
			fail(w, e)
			return
		}
		status := 200
		if created {
			status = 201
		}
		writeJSON(w, status, room)
		return
	}
	if len(parts) != 5 || !validID(parts[3]) || (parts[4] != "log" && parts[4] != "status") {
		http.NotFound(w, r)
		return
	}
	device, e := singleHeader(r, "X-Family-Device")
	if e != nil {
		fail(w, e)
		return
	}
	// Body was bounded/read before outer Grant.Run. No network waits under locks.
	var q MLSRequest
	if r.Method == "POST" && parts[4] == "log" {
		if r.URL.RawQuery != "" {
			fail(w, ErrInvalid)
			return
		}
		if !decodeMLS(w, r, &q, "client_id", "device_id", "group_id", "kind", "expected_revision", "epoch", "target_device", "payload") {
			return
		}
		if q.Device != device {
			fail(w, ErrForbidden)
			return
		}
	}
	a.store.mu.Lock()
	defer a.store.mu.Unlock()
	room, e := a.store.mlsRoom(parts[3])
	if e == nil {
		e = a.store.mlsAdmit(room, actor, device, g.DeviceBindings())
	}
	if e != nil {
		fail(w, e)
		return
	}
	if r.Method == "GET" && parts[4] == "status" {
		if r.URL.RawQuery != "" {
			fail(w, ErrInvalid)
			return
		}
		writeJSON(w, 200, room)
		return
	}
	if r.Method == "GET" && parts[4] == "log" {
		after, e := cursor(r)
		if e != nil {
			fail(w, e)
			return
		}
		out, e := a.store.mlsHistory(room, device, after)
		if e != nil {
			fail(w, e)
			return
		}
		writeJSON(w, 200, out)
		return
	}
	if r.Method == "POST" && parts[4] == "log" {
		out, created, e := a.store.appendMLS(room, q)
		if e != nil {
			fail(w, e)
			return
		}
		status := 200
		if created {
			status = 201
		}
		writeJSON(w, status, out)
		return
	}
	http.NotFound(w, r)
}

// Reserve an explicitly MLS-only empty room before device key generation.
// It is never writable through the legacy message/media/membership routes.
func (s *Store) reserveMLS(room, actor, peer string) (bool, error) {
	if !validID(room) || !actors[actor] || !actors[peer] || actor == peer {
		return false, ErrInvalid
	}
	var n int
	if e := s.db.QueryRow("SELECT count(*) FROM rooms WHERE id=?", room).Scan(&n); e != nil {
		return false, e
	}
	if n != 0 {
		old, e := s.mlsRoom(room)
		if e != nil || old.Phase != "reserved" {
			return false, ErrConflict
		}
		var owner string
		if e = s.db.QueryRow("SELECT owner FROM rooms WHERE id=?", room).Scan(&owner); e != nil {
			return false, e
		}
		if owner != actor || s.member(room, peer) != nil {
			return false, ErrForbidden
		}
		return false, nil
	}
	if e := s.db.QueryRow("SELECT count(*) FROM rooms").Scan(&n); e != nil {
		return false, e
	}
	if n >= 32 {
		return false, ErrLimit
	}
	tx, e := s.db.Begin()
	if e != nil {
		return false, e
	}
	defer tx.Rollback()
	if _, e = tx.Exec("INSERT INTO rooms(id,owner) VALUES(?,?)", room, actor); e != nil {
		return false, e
	}
	for _, who := range []string{actor, peer} {
		if _, e = tx.Exec("INSERT INTO members VALUES(?,?)", room, who); e != nil {
			return false, e
		}
	}
	if _, e = tx.Exec("INSERT INTO mls_rooms VALUES(?,NULL,'','',?,0,0,'reserved',1)", room, []byte("[]")); e != nil {
		return false, e
	}
	return true, tx.Commit()
}
