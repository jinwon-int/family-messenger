package chat

// Two opaque MLS application confirmations, separate from the immutable
// Welcome transcript. Only the protected peer worker verifies possession.
// Recording ciphertext never grants device admission or native delivery.
import (
	"bytes"
	"database/sql"
	"encoding/json"
	"github.com/jinwon-int/family-messenger/server/internal/access"
	"net/http"
)

const successorConfirmationMax = 16384

var successorConfirmationKinds = [...]string{"candidate_proof", "peer_proof"}
var successorConfirmationPhases = [...]string{"awaiting-candidate-proof", "awaiting-peer-proof", "confirmations-recorded-inactive"}

func migrateSuccessorConfirmation(db *sql.DB, dir string, fresh bool) error {
	if !fresh {
		if e := snapshotSchema(db, dir, "v7-before-successor-confirmation-"); e != nil {
			return e
		}
	}
	_, e := db.Exec(`BEGIN IMMEDIATE;
 CREATE TABLE mls_successor_confirmation(intent TEXT PRIMARY KEY REFERENCES mls_successor_reservations(intent), transcript BLOB NOT NULL CHECK(length(transcript)<=16384));
 INSERT INTO mls_successor_confirmation SELECT intent, CAST('[]' AS BLOB) FROM mls_successor_reservations;
 PRAGMA user_version=8; COMMIT;`)
	return e
}
func confirmationIndex(kind string) int {
	for i, k := range successorConfirmationKinds {
		if kind == k {
			return i
		}
	}
	return -1
}
func validConfirmation(q successorHandshakeRequest, p successorReservation, h successorHandshake) bool {
	return confirmationIndex(q.Kind) >= 0 && q.Reservation == p.ID && q.ContextSHA == h.ContextSHA && h.Revision == 3 && q.Group == h.Records[1].Request.Group && len(q.Payload) > 0 && len(q.Payload) <= 4096
}
func (s *Store) successorConfirmation(p successorReservation) (successorHandshake, []byte, error) {
	h, _, e := s.successorHandshake(p)
	v := successorHandshake{Version: 1, Reservation: p.ID, ContextSHA: h.ContextSHA, Phase: successorConfirmationPhases[0]}
	if e != nil {
		return v, nil, e
	}
	if h.Revision != 3 {
		return v, nil, ErrForbidden
	}
	var raw []byte
	if e = s.db.QueryRow("SELECT transcript FROM mls_successor_confirmation WHERE intent=?", p.Context.Intent).Scan(&raw); e != nil {
		if e == sql.ErrNoRows {
			e = ErrIntegrity
		}
		return v, nil, e
	}
	if len(raw) > successorConfirmationMax || json.Unmarshal(raw, &v.Records) != nil || v.Records == nil || len(v.Records) > 2 {
		return v, nil, ErrIntegrity
	}
	for i, r := range v.Records {
		wire, _ := json.Marshal(r.Request)
		if r.Request.Kind != successorConfirmationKinds[i] || !validConfirmation(r.Request, p, h) || r.Device != handshakePin(p, i).ID || r.SHA != digestMLS(wire) {
			return v, nil, ErrIntegrity
		}
	}
	canonical, _ := json.Marshal(v.Records)
	if !bytes.Equal(raw, canonical) {
		return v, nil, ErrIntegrity
	}
	v.Revision = len(v.Records)
	v.Phase = successorConfirmationPhases[v.Revision]
	return v, raw, nil
}
func (s *Store) appendSuccessorConfirmation(p successorReservation, actor, device string, q successorHandshakeRequest) (successorHandshake, bool, error) {
	v, prior, e := s.successorConfirmation(p)
	if e != nil {
		return v, false, e
	}
	h, _, e := s.successorHandshake(p)
	if e != nil {
		return v, false, e
	}
	index := confirmationIndex(q.Kind)
	if index < 0 || len(q.Payload) == 0 || len(q.Payload) > 4096 {
		return v, false, ErrInvalid
	}
	pin := handshakePin(p, index)
	if actor != pin.Actor || device != pin.ID {
		return v, false, ErrForbidden
	}
	if !validConfirmation(q, p, h) {
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
	if index != len(v.Records) {
		return v, false, ErrConflict
	}
	v.Records = append(v.Records, successorHandshakeRecord{q, device, digestMLS(wire)})
	next, _ := json.Marshal(v.Records)
	if len(next) > successorConfirmationMax {
		return v, false, ErrLimit
	}
	result, e := s.db.Exec("UPDATE mls_successor_confirmation SET transcript=? WHERE intent=? AND transcript=?", next, p.Context.Intent, prior)
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
	v.Phase = successorConfirmationPhases[v.Revision]
	return v, true, nil
}
func (a *API) successorConfirmationRoute(w http.ResponseWriter, r *http.Request, actor string, g *access.Grant, intent string) {
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
	var v successorHandshake
	code := 200
	if r.Method == "POST" {
		var created bool
		v, created, e = a.store.appendSuccessorConfirmation(p, actor, device, q)
		if created {
			code = 201
		}
	} else {
		v, _, e = a.store.successorConfirmation(p)
	}
	if e != nil {
		fail(w, e)
		return
	}
	writeJSON(w, code, v)
}
