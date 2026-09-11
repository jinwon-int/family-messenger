package chat

// An immutable public reservation only. No private custody or new leaf is
// inferred from this record; candidate delivery stays disabled.
import (
	"bytes"
	"database/sql"
	"encoding/json"
	"net/http"

	"github.com/jinwon-int/family-messenger/server/internal/access"
)

type successorReservation struct {
	Version int              `json:"version"`
	ID      string           `json:"reservation_id"`
	Context successorContext `json:"context"`
	Phase   string           `json:"phase"`
}
type successorReservationRequest struct {
	ID         string `json:"reservation_id"`
	ContextSHA string `json:"context_sha256"`
}

func migrateSuccessorReservation(db *sql.DB, dir string, fresh bool) error {
	if !fresh {
		if e := snapshotSchema(db, dir, "v4-before-successor-reservation-"); e != nil {
			return e
		}
	}
	_, e := db.Exec(`BEGIN IMMEDIATE;
 CREATE TABLE mls_successor_reservations(intent TEXT PRIMARY KEY, room TEXT NOT NULL UNIQUE REFERENCES mls_rooms(room), reservation_id TEXT NOT NULL UNIQUE, context BLOB NOT NULL CHECK(length(context)<=4096));
 PRAGMA user_version=5; COMMIT;`)
	return e
}

// Caller holds current Grant.Run -> Store.mu throughout source validation,
// target check and transaction. HTTP body was already read outside authority.
func (s *Store) successorReservation(context successorContext) (successorReservation, bool, error) {
	p := successorReservation{Version: 1, Context: context, Phase: "reserved-inactive"}
	var room string
	var raw []byte
	e := s.db.QueryRow("SELECT room,reservation_id,context FROM mls_successor_reservations WHERE intent=?", context.Intent).Scan(&room, &p.ID, &raw)
	if e == sql.ErrNoRows {
		return p, false, nil
	}
	if e != nil {
		return p, false, e
	}
	expected, _ := json.Marshal(context)
	if !validID(p.ID) || room != context.Target || !bytes.Equal(raw, expected) {
		return p, true, ErrIntegrity
	}
	// No later target phase has been qualified yet. Do not treat a changed or
	// partially missing target as a fresh reservation, or repair it silently.
	r, e := s.loadMLSRoom(room, true)
	if e != nil {
		return p, true, e
	}
	var owner string
	var seq, required, members, events, preparations, messages, attachments int
	var noGroup bool
	if e = s.db.QueryRow("SELECT owner,next_seq FROM rooms WHERE id=?", room).Scan(&owner, &seq); e != nil {
		return p, true, e
	}
	if e = s.db.QueryRow("SELECT custody_required,group_id IS NULL FROM mls_rooms WHERE room=?", room).Scan(&required, &noGroup); e != nil {
		return p, true, e
	}
	for _, q := range []struct {
		sql string
		n   *int
	}{
		{"SELECT count(*) FROM members WHERE room=?", &members},
		{"SELECT count(*) FROM mls_events WHERE room=?", &events},
		{"SELECT count(*) FROM mls_preparations WHERE room=?", &preparations},
		{"SELECT count(*) FROM messages WHERE room=?", &messages},
		{"SELECT count(*) FROM attachments WHERE room=?", &attachments},
	} {
		if e = s.db.QueryRow(q.sql, room).Scan(q.n); e != nil {
			return p, true, e
		}
	}
	var pins []byte
	if e = s.db.QueryRow("SELECT pins FROM mls_rooms WHERE room=?", room).Scan(&pins); e != nil {
		return p, true, e
	}
	if !noGroup || owner != context.Candidate.Actor || seq != 1 || required != 1 || members != 2 || events != 0 || preparations != 0 || messages != 0 || attachments != 0 ||
		r.Group != "" || r.Creator != "" || r.Peer != "" || r.Revision != 0 || r.Epoch != 0 || r.Next != 1 || r.Phase != "reserved" || !bytes.Equal(pins, []byte("[]")) {
		return p, true, ErrIntegrity
	}
	for _, actor := range []string{context.Candidate.Actor, context.Peer.Actor} {
		if e = s.member(room, actor); e != nil {
			return p, true, e
		}
	}
	if _, _, e = s.successorCustody(p); e != nil {
		return p, true, e
	}
	if _, _, e = s.successorHandshake(p); e != nil {
		return p, true, e
	}
	return p, true, nil
}

func (s *Store) reserveSuccessor(context successorContext, q successorReservationRequest) (successorReservation, bool, error) {
	p := successorReservation{}
	if !validID(q.ID) {
		return p, false, ErrInvalid
	}
	raw, _ := json.Marshal(context)
	if len(raw) > 4096 {
		return p, false, ErrLimit
	}
	if q.ContextSHA != digestMLS(raw) {
		return p, false, ErrConflict
	}
	p, exists, e := s.successorReservation(context)
	if e != nil {
		return p, false, e
	}
	if exists {
		if p.ID != q.ID {
			return p, false, ErrConflict
		}
		return p, false, nil
	}
	if e = s.successorTargetUnused(context.Target); e != nil {
		return p, false, e
	}
	var rooms, reservations, ids int
	if e = s.db.QueryRow("SELECT count(*) FROM rooms").Scan(&rooms); e != nil {
		return p, false, e
	}
	if e = s.db.QueryRow("SELECT count(*) FROM mls_successor_reservations").Scan(&reservations); e != nil {
		return p, false, e
	}
	if rooms >= 32 || reservations >= 16 {
		return p, false, ErrLimit
	}
	if e = s.db.QueryRow("SELECT count(*) FROM mls_successor_reservations WHERE reservation_id=?", q.ID).Scan(&ids); e != nil {
		return p, false, e
	}
	if ids != 0 {
		return p, false, ErrConflict
	}
	tx, e := s.db.Begin()
	if e != nil {
		return p, false, e
	}
	defer tx.Rollback()
	if _, e = tx.Exec("INSERT INTO rooms(id,owner) VALUES(?,?)", context.Target, context.Candidate.Actor); e != nil {
		return p, false, e
	}
	for _, actor := range []string{context.Candidate.Actor, context.Peer.Actor} {
		if _, e = tx.Exec("INSERT INTO members VALUES(?,?)", context.Target, actor); e != nil {
			return p, false, e
		}
	}
	if _, e = tx.Exec("INSERT INTO mls_rooms VALUES(?,NULL,'','',?,0,0,'reserved',1,1)", context.Target, []byte("[]")); e != nil {
		return p, false, e
	}
	if _, e = tx.Exec("INSERT INTO mls_successor_reservations VALUES(?,?,?,?)", context.Intent, context.Target, q.ID, raw); e != nil {
		return p, false, e
	}
	if _, e = tx.Exec("INSERT INTO mls_successor_custody VALUES(?,?)", context.Intent, []byte("[]")); e != nil {
		return p, false, e
	}
	if _, e = tx.Exec("INSERT INTO mls_successor_leases VALUES(?,?)", context.Intent, []byte("[]")); e != nil {
		return p, false, e
	}
	if _, e = tx.Exec("INSERT INTO mls_successor_enrollments VALUES(?,CAST('[]' AS BLOB))", context.Intent); e != nil {
		return p, false, e
	}
	if _, e = tx.Exec("INSERT INTO mls_successor_retirements VALUES(?,NULL)", context.Intent); e != nil {
		return p, false, e
	}
	if _, e = tx.Exec("INSERT INTO mls_successor_confirmation VALUES(?,?)", context.Intent, []byte("[]")); e != nil {
		return p, false, e
	}
	if _, e = tx.Exec("INSERT INTO mls_successor_handshake VALUES(?,NULL,?)", context.Intent, []byte("[]")); e != nil {
		return p, false, e
	}
	p.ID = q.ID
	return p, true, tx.Commit()
}

func (a *API) successorReservationRoute(w http.ResponseWriter, r *http.Request, actor string, g *access.Grant, intent string) {
	if (r.Method != "GET" && r.Method != "POST") || r.URL.RawQuery != "" || r.URL.ForceQuery {
		fail(w, ErrInvalid)
		return
	}
	device, e := singleHeader(r, "X-Family-Device")
	if e != nil || !validID(device) {
		fail(w, ErrInvalid)
		return
	}
	var q successorReservationRequest
	r.Body = http.MaxBytesReader(w, r.Body, 1024)
	if r.Method == "POST" && !decodeMLS(w, r, &q, "reservation_id", "context_sha256") {
		return
	}
	a.store.mu.Lock()
	defer a.store.mu.Unlock()
	i, e := g.AcceptedSuccessor(intent)
	if e != nil {
		fail(w, ErrForbidden)
		return
	}
	c, e := a.store.successorContext(i, actor, device, g.DeviceBindings())
	if e != nil {
		fail(w, e)
		return
	}
	var p successorReservation
	code := 200
	if r.Method == "POST" {
		var created bool
		p, created, e = a.store.reserveSuccessor(c, q)
		if created {
			code = 201
		}
	} else {
		var exists bool
		p, exists, e = a.store.successorReservation(c)
		if e == nil && !exists {
			e = ErrForbidden
		}
	}
	if e != nil {
		fail(w, e)
		return
	}
	writeJSON(w, code, p)
}
