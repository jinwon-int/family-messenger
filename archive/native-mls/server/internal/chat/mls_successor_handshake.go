package chat

// Restricted opaque handshake relay. Even the final empty ack is a public
// declaration, not proof that the candidate decrypted a Welcome. Never activate
// a native room or enroll a device based on this transcript.
import (
	"bytes"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"net/http"

	"github.com/jinwon-int/family-messenger/server/internal/access"
)

const successorHandshakeMax = 192 * 1024

type successorHandshakeRequest struct {
	Reservation string `json:"reservation_id"`
	ContextSHA  string `json:"context_sha256"`
	Kind        string `json:"kind"`
	Group       string `json:"group_id"`
	Payload     []byte `json:"payload"`
}

// Payload is one canonical base64 string, never a numeric JSON array or an
// alias with ignored line breaks. The outer decoder already checks exact keys.
func (q *successorHandshakeRequest) UnmarshalJSON(raw []byte) error {
	type wire successorHandshakeRequest
	var v wire
	if e := json.Unmarshal(raw, &v); e != nil {
		return e
	}
	var field struct {
		Payload json.RawMessage `json:"payload"`
	}
	if e := json.Unmarshal(raw, &field); e != nil {
		return e
	}
	var text string
	if len(field.Payload) == 0 || field.Payload[0] != '"' || json.Unmarshal(field.Payload, &text) != nil || base64.StdEncoding.EncodeToString(v.Payload) != text {
		return ErrInvalid
	}
	*q = successorHandshakeRequest(v)
	return nil
}

type successorHandshakeRecord struct {
	Request successorHandshakeRequest `json:"request"`
	Device  string                    `json:"device_id"`
	SHA     string                    `json:"sha256"`
}
type successorHandshake struct {
	Version     int                        `json:"version"`
	Reservation string                     `json:"reservation_id"`
	ContextSHA  string                     `json:"context_sha256"`
	Revision    int                        `json:"revision"`
	Phase       string                     `json:"phase"`
	Records     []successorHandshakeRecord `json:"records"`
}

var successorHandshakeKinds = [...]string{"key_package", "welcome", "ack"}
var successorHandshakePhases = [...]string{"awaiting-key-package", "awaiting-welcome", "awaiting-ack", "exchange-recorded-inactive"}

func migrateSuccessorHandshake(db *sql.DB, dir string, fresh bool) error {
	if !fresh {
		if e := snapshotSchema(db, dir, "v6-before-successor-handshake-"); e != nil {
			return e
		}
	}
	_, e := db.Exec(`BEGIN IMMEDIATE;
 CREATE TABLE mls_successor_handshake(intent TEXT PRIMARY KEY REFERENCES mls_successor_reservations(intent), group_id TEXT UNIQUE, transcript BLOB NOT NULL CHECK(length(transcript)<=196608));
 INSERT INTO mls_successor_handshake SELECT intent, NULL, CAST('[]' AS BLOB) FROM mls_successor_reservations;
 PRAGMA user_version=7; COMMIT;`)
	return e
}
func handshakeIndex(kind string) int {
	for i, k := range successorHandshakeKinds {
		if k == kind {
			return i
		}
	}
	return -1
}
func handshakePin(p successorReservation, index int) MLSPin {
	if index == 1 {
		return p.Context.Peer
	}
	return p.Context.Candidate
}
func validHandshake(q successorHandshakeRequest, p successorReservation) bool {
	if q.Payload == nil || len(q.Payload) > MLSMaxWire {
		return false
	}
	switch q.Kind {
	case "key_package":
		return q.Group == "" && len(q.Payload) > 0 && digestMLS(q.Payload) == p.Context.Package
	case "welcome":
		return canonicalGroup(q.Group) && q.Group != p.Context.Group && len(q.Payload) > 0
	case "ack":
		return canonicalGroup(q.Group) && q.Group != p.Context.Group && len(q.Payload) == 0
	}
	return false
}

// Caller holds Grant.Run -> Store.mu. Missing/corrupt committed rows are never
// replaced by an empty transcript. The original target stays an empty sentinel.
func (s *Store) successorHandshake(p successorReservation) (successorHandshake, []byte, error) {
	context, _ := json.Marshal(p.Context)
	v := successorHandshake{Version: 1, Reservation: p.ID, ContextSHA: digestMLS(context), Phase: successorHandshakePhases[0]}
	var raw []byte
	var group sql.NullString
	if e := s.db.QueryRow("SELECT group_id,transcript FROM mls_successor_handshake WHERE intent=?", p.Context.Intent).Scan(&group, &raw); e != nil {
		if e == sql.ErrNoRows {
			e = ErrIntegrity
		}
		return v, nil, e
	}
	if len(raw) > successorHandshakeMax || json.Unmarshal(raw, &v.Records) != nil || v.Records == nil || len(v.Records) > 3 {
		return v, nil, ErrIntegrity
	}
	for i, r := range v.Records {
		q := r.Request
		wire, _ := json.Marshal(q)
		if q.Kind != successorHandshakeKinds[i] || q.Reservation != p.ID || q.ContextSHA != v.ContextSHA || !validHandshake(q, p) || r.Device != handshakePin(p, i).ID || r.SHA != digestMLS(wire) {
			return v, nil, ErrIntegrity
		}
		if i == 2 && q.Group != v.Records[1].Request.Group {
			return v, nil, ErrIntegrity
		}
	}
	if len(v.Records) < 2 {
		if group.Valid {
			return v, nil, ErrIntegrity
		}
	} else {
		if !group.Valid || group.String != v.Records[1].Request.Group {
			return v, nil, ErrIntegrity
		}
		var used int
		if e := s.db.QueryRow("SELECT count(*) FROM mls_rooms WHERE group_id=?", group.String).Scan(&used); e != nil {
			return v, nil, e
		}
		if used != 0 {
			return v, nil, ErrIntegrity
		}
	}
	canonical, _ := json.Marshal(v.Records)
	if !bytes.Equal(raw, canonical) {
		return v, nil, ErrIntegrity
	}
	if len(v.Records) > 0 {
		custody, _, e := s.successorCustody(p)
		if e != nil {
			return v, nil, e
		}
		if custody.Revision != 2 {
			return v, nil, ErrIntegrity
		}
	}
	v.Revision = len(v.Records)
	v.Phase = successorHandshakePhases[v.Revision]
	return v, raw, nil
}
func (s *Store) appendSuccessorHandshake(p successorReservation, actor, device string, q successorHandshakeRequest) (successorHandshake, bool, error) {
	v, prior, e := s.successorHandshake(p)
	if e != nil {
		return v, false, e
	}
	custody, _, e := s.successorCustody(p)
	if e != nil {
		return v, false, e
	}
	if custody.Revision != 2 {
		return v, false, ErrForbidden
	}
	index := handshakeIndex(q.Kind)
	if index < 0 || !validHandshake(q, p) {
		return v, false, ErrInvalid
	}
	pin := handshakePin(p, index)
	if actor != pin.Actor || device != pin.ID {
		return v, false, ErrForbidden
	}
	if q.Reservation != p.ID || q.ContextSHA != v.ContextSHA {
		return v, false, ErrConflict
	}
	wire, _ := json.Marshal(q)
	if index < len(v.Records) {
		old, _ := json.Marshal(v.Records[index].Request)
		if !bytes.Equal(old, wire) {
			return v, false, ErrConflict
		}
		return v, false, nil
	}
	if index != len(v.Records) || (index == 2 && q.Group != v.Records[1].Request.Group) {
		return v, false, ErrConflict
	}
	var group any
	if index >= 1 {
		group = q.Group
		if index == 1 {
			var used int
			if e := s.db.QueryRow("SELECT (SELECT count(*) FROM mls_rooms WHERE group_id=?)+(SELECT count(*) FROM mls_successor_handshake WHERE group_id=?)", q.Group, q.Group).Scan(&used); e != nil {
				return v, false, e
			}
			if used != 0 {
				return v, false, ErrConflict
			}
		}
	}
	v.Records = append(v.Records, successorHandshakeRecord{q, device, digestMLS(wire)})
	next, _ := json.Marshal(v.Records)
	if len(next) > successorHandshakeMax {
		return v, false, ErrLimit
	}
	result, e := s.db.Exec("UPDATE mls_successor_handshake SET group_id=?,transcript=? WHERE intent=? AND transcript=?", group, next, p.Context.Intent, prior)
	if e != nil {
		return v, false, e
	}
	n, e := result.RowsAffected()
	if e != nil {
		return v, false, e
	}
	if n != 1 {
		return v, false, ErrConflict
	}
	v.Revision = len(v.Records)
	v.Phase = successorHandshakePhases[v.Revision]
	return v, true, nil
}
func (a *API) successorHandshakeRoute(w http.ResponseWriter, r *http.Request, actor string, g *access.Grant, intent string) {
	if (r.Method != "GET" && r.Method != "POST") || r.URL.RawQuery != "" || r.URL.ForceQuery {
		fail(w, ErrInvalid)
		return
	}
	device, e := singleHeader(r, "X-Family-Device")
	if e != nil || !validID(device) {
		fail(w, ErrInvalid)
		return
	}
	var q successorHandshakeRequest
	if r.Method == "POST" && !decodeMLS(w, r, &q, "reservation_id", "context_sha256", "kind", "group_id", "payload") {
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
	p, exists, e := a.store.successorReservation(c)
	if e == nil && !exists {
		e = ErrForbidden
	}
	if e != nil {
		fail(w, e)
		return
	}
	custody, _, e := a.store.successorCustody(p)
	if e == nil && custody.Revision != 2 {
		e = ErrForbidden
	}
	if e != nil {
		fail(w, e)
		return
	}
	var v successorHandshake
	code := 200
	if r.Method == "POST" {
		var created bool
		v, created, e = a.store.appendSuccessorHandshake(p, actor, device, q)
		if created {
			code = 201
		}
	} else {
		v, _, e = a.store.successorHandshake(p)
	}
	if e != nil {
		fail(w, e)
		return
	}
	writeJSON(w, code, v)
}
