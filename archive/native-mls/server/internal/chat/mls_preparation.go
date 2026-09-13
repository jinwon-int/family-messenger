package chat

// Public custody declarations, not cryptographic proof of private client state.
import (
	"database/sql"
	"encoding/json"
	"net/http"
	"reflect"
	"sort"

	"github.com/jinwon-int/family-messenger/server/internal/access"
)

type contextReservation struct {
	Room   string `json:"room"`
	Source string `json:"source_room"`
	Group  string `json:"source_group"`
}
type preparation struct {
	Device string `json:"device_id"`
	Intent string `json:"intent_id"`
}
type contextPreparation struct {
	Version  int           `json:"version"`
	Room     string        `json:"room"`
	Source   string        `json:"source_room"`
	Group    string        `json:"source_group"`
	Pins     []MLSPin      `json:"pins"`
	Prepared []preparation `json:"prepared"`
}

func migratePreparation(db *sql.DB, dir string, fresh bool) error {
	if !fresh {
		if e := snapshotSchema(db, dir, "v3-before-preparation-"); e != nil {
			return e
		}
	}
	_, e := db.Exec(`BEGIN IMMEDIATE;
 CREATE TABLE mls_preparations(room TEXT PRIMARY KEY REFERENCES mls_rooms(room), source_room TEXT NOT NULL REFERENCES mls_rooms(room), source_group TEXT NOT NULL, pins BLOB NOT NULL, prepared BLOB NOT NULL);
 ALTER TABLE mls_rooms ADD COLUMN custody_required INTEGER NOT NULL DEFAULT 0 CHECK(custody_required IN (0,1));
 PRAGMA user_version=4; COMMIT;`)
	return e
}

// All helpers are called under authority -> Store.mu. Missing table is an error,
// not a fallback to the old unguarded protocol.
func (s *Store) preparation(room string) (contextPreparation, bool, error) {
	p := contextPreparation{Version: 1, Room: room}
	var pins, ready []byte
	e := s.db.QueryRow("SELECT source_room,source_group,pins,prepared FROM mls_preparations WHERE room=?", room).Scan(&p.Source, &p.Group, &pins, &ready)
	if e == sql.ErrNoRows {
		return p, false, nil
	}
	if e != nil {
		return p, false, e
	}
	if !validID(p.Source) || p.Source == room || !canonicalGroup(p.Group) || len(pins) > 2048 || len(ready) > 1024 || json.Unmarshal(pins, &p.Pins) != nil || json.Unmarshal(ready, &p.Prepared) != nil || len(p.Pins) != 2 || p.Prepared == nil || len(p.Prepared) > 2 {
		return p, true, ErrIntegrity
	}
	if p.Pins[0].ID >= p.Pins[1].ID || p.Pins[0].Actor == p.Pins[1].Actor {
		return p, true, ErrIntegrity
	}
	seen := map[string]bool{}
	for _, v := range p.Prepared {
		if !validID(v.Intent) || seen[v.Device] || (v.Device != p.Pins[0].ID && v.Device != p.Pins[1].ID) {
			return p, true, ErrIntegrity
		}
		seen[v.Device] = true
	}
	// Canonical generated JSON rejects ambiguous, unknown and duplicated fields.
	x, _ := json.Marshal(p.Pins)
	y, _ := json.Marshal(p.Prepared)
	if string(x) != string(pins) || string(y) != string(ready) {
		return p, true, ErrIntegrity
	}
	return p, true, nil
}
func (s *Store) admitPreparation(p contextPreparation, actor, device string, devices []access.Device) error {
	source, e := s.mlsRoom(p.Source)
	if e != nil {
		return e
	}
	if e = s.mlsAdmit(source, actor, device, devices); e != nil {
		return e
	}
	if source.Group != p.Group || !reflect.DeepEqual(source.Pins, p.Pins) {
		return ErrForbidden
	}
	target, e := s.mlsRoom(p.Room)
	if e != nil {
		return e
	}
	target, e = s.mlsContext(target, actor, device, devices)
	if e != nil {
		return e
	}
	sort.Slice(target.Pins, func(i, j int) bool { return target.Pins[i].ID < target.Pins[j].ID })
	if !reflect.DeepEqual(target.Pins, p.Pins) {
		return ErrForbidden
	}
	return nil
}
func (s *Store) reserveContext(q contextReservation, actor, device string, devices []access.Device) (contextPreparation, bool, error) {
	if !validID(q.Room) || !validID(q.Source) || q.Room == q.Source || !canonicalGroup(q.Group) {
		return contextPreparation{}, false, ErrInvalid
	}
	source, e := s.mlsRoom(q.Source)
	if e != nil {
		return contextPreparation{}, false, e
	}
	if e = s.mlsAdmit(source, actor, device, devices); e != nil {
		return contextPreparation{}, false, e
	}
	// Existing native creation stores pins in canonical ID order. Do not copy a
	// corrupted source into an immutable target that the preparation reader
	// would reject. Preserve the source; never normalize it as a repair.
	if source.Pins[0].ID >= source.Pins[1].ID || source.Pins[0].Actor == source.Pins[1].Actor {
		return contextPreparation{}, false, ErrIntegrity
	}
	if source.Group != q.Group || source.Creator != device {
		return contextPreparation{}, false, ErrForbidden
	}
	old, exists, e := s.preparation(q.Room)
	if e != nil {
		return old, false, e
	}
	if exists {
		if old.Source != q.Source || old.Group != q.Group {
			return old, false, ErrConflict
		}
		return old, false, s.admitPreparation(old, actor, device, devices)
	}
	if source.Phase != "ready" {
		return old, false, ErrConflict
	}
	var count int
	if e = s.db.QueryRow("SELECT count(*) FROM rooms WHERE id=?", q.Room).Scan(&count); e != nil {
		return old, false, e
	}
	if count != 0 {
		return old, false, ErrConflict
	}
	if e = s.db.QueryRow("SELECT count(*) FROM rooms").Scan(&count); e != nil {
		return old, false, e
	}
	if count >= 32 {
		return old, false, ErrLimit
	}
	p := contextPreparation{1, q.Room, q.Source, q.Group, source.Pins, []preparation{}}
	raw, _ := json.Marshal(p.Pins)
	tx, e := s.db.Begin()
	if e != nil {
		return p, false, e
	}
	defer tx.Rollback()
	if _, e = tx.Exec("INSERT INTO rooms(id,owner) VALUES(?,?)", q.Room, actor); e != nil {
		return p, false, e
	}
	for _, pin := range p.Pins {
		if _, e = tx.Exec("INSERT INTO members VALUES(?,?)", q.Room, pin.Actor); e != nil {
			return p, false, e
		}
	}
	if _, e = tx.Exec("INSERT INTO mls_rooms VALUES(?,NULL,'','',?,0,0,'reserved',1,1)", q.Room, []byte("[]")); e != nil {
		return p, false, e
	}
	if _, e = tx.Exec("INSERT INTO mls_preparations VALUES(?,?,?,?,?)", q.Room, q.Source, q.Group, raw, []byte("[]")); e != nil {
		return p, false, e
	}
	return p, true, tx.Commit()
}
func (s *Store) prepareContext(p contextPreparation, device, intent string) (contextPreparation, bool, error) {
	if !validID(intent) {
		return p, false, ErrInvalid
	}
	for _, v := range p.Prepared {
		if v.Device == device {
			if v.Intent != intent {
				return p, false, ErrConflict
			}
			return p, false, nil
		}
	}
	target, e := s.mlsRoom(p.Room)
	if e != nil {
		return p, false, e
	}
	if target.Phase != "reserved" {
		return p, false, ErrConflict
	}
	p.Prepared = append(p.Prepared, preparation{device, intent})
	sort.Slice(p.Prepared, func(i, j int) bool { return p.Prepared[i].Device < p.Prepared[j].Device })
	raw, _ := json.Marshal(p.Prepared)
	_, e = s.db.Exec("UPDATE mls_preparations SET prepared=? WHERE room=?", raw, p.Room)
	return p, true, e
}

// The existing bind route also enforces this gate under its Store lock.
func (s *Store) preparationBind(room, actor, device string, devices []access.Device) error {
	var successor int
	if e := s.db.QueryRow("SELECT count(*) FROM mls_successor_reservations WHERE room=?", room).Scan(&successor); e != nil {
		return e
	}
	if successor != 0 {
		return ErrForbidden
	} // no successor activation in this protocol version
	p, exists, e := s.preparation(room)
	if e != nil {
		return e
	}
	if !exists {
		var required bool
		e = s.db.QueryRow("SELECT custody_required FROM mls_rooms WHERE room=?", room).Scan(&required)
		if e != nil && e != sql.ErrNoRows {
			return e
		}
		if required {
			return ErrIntegrity
		}
		return nil
	}
	if e = s.admitPreparation(p, actor, device, devices); e != nil {
		return e
	}
	if len(p.Prepared) != 2 {
		return ErrConflict
	}
	return nil
}
func (a *API) preparationRoute(w http.ResponseWriter, r *http.Request, actor string, g *access.Grant, parts []string) {
	device, e := singleHeader(r, "X-Family-Device")
	if e != nil {
		fail(w, e)
		return
	}
	if r.URL.RawQuery != "" {
		fail(w, ErrInvalid)
		return
	}
	if len(parts) == 3 && parts[2] == "context-reservations" && r.Method == "POST" {
		var q contextReservation
		if !decodeMLS(w, r, &q, "room", "source_room", "source_group") {
			return
		}
		a.store.mu.Lock()
		defer a.store.mu.Unlock()
		p, created, e := a.store.reserveContext(q, actor, device, g.DeviceBindings())
		if e != nil {
			fail(w, e)
			return
		}
		code := 200
		if created {
			code = 201
		}
		writeJSON(w, code, p)
		return
	}
	if len(parts) != 5 || parts[2] != "rooms" || !validID(parts[3]) || parts[4] != "preparation" || (r.Method != "GET" && r.Method != "POST") {
		http.NotFound(w, r)
		return
	}
	var q struct {
		Source string `json:"source_room"`
		Group  string `json:"source_group"`
		Intent string `json:"intent_id"`
	}
	if r.Method == "POST" && !decodeMLS(w, r, &q, "source_room", "source_group", "intent_id") {
		return
	}
	a.store.mu.Lock()
	defer a.store.mu.Unlock()
	p, exists, e := a.store.preparation(parts[3])
	if e == nil && !exists {
		e = ErrForbidden
	}
	if e == nil {
		e = a.store.admitPreparation(p, actor, device, g.DeviceBindings())
	}
	if e != nil {
		fail(w, e)
		return
	}
	code := 200
	if r.Method == "POST" {
		if q.Source != p.Source || q.Group != p.Group {
			fail(w, ErrConflict)
			return
		}
		var created bool
		p, created, e = a.store.prepareContext(p, device, q.Intent)
		if e != nil {
			fail(w, e)
			return
		}
		if created {
			code = 201
		}
	}
	writeJSON(w, code, p)
}
