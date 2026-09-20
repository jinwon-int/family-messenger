package chat

// A current persistent participant can close the target unilaterally, including
// after the original intent expires. Closure and message admission share Store.mu.
import (
	"bytes"
	"crypto/ed25519"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"github.com/jinwon-int/family-messenger/server/internal/access"
	"net/http"
)

type closureStatus struct {
	Version      int                `json:"version"`
	Enrollment   enrollmentRecord   `json:"enrollment"`
	Handshake    successorHandshake `json:"handshake"`
	Confirmation successorHandshake `json:"confirmation"`
	Closure      *leaseApproval     `json:"closure"`
}

func migrateSuccessorClosure(db *sql.DB, dir string, fresh bool) error {
	if !fresh {
		if e := snapshotSchema(db, dir, "v11-before-successor-closure-"); e != nil {
			return e
		}
	}
	_, e := db.Exec(`BEGIN IMMEDIATE;
 CREATE TABLE mls_successor_closures(intent TEXT PRIMARY KEY REFERENCES mls_successor_enrollments(intent), request BLOB CHECK(request IS NULL OR length(request)<=256));
 INSERT INTO mls_successor_closures SELECT intent,NULL FROM mls_successor_enrollments;
 PRAGMA user_version=12;COMMIT;`)
	return e
}
func closureFrame(v enrollmentRecord, role string) []byte {
	raw, _ := json.Marshal(v)
	frame, _ := json.Marshal([]any{"family-successor-closure", 1, "persistent-target", role, digestMLS(raw)})
	hash, _ := hex.DecodeString(digestMLS(frame))
	return append([]byte("family-successor-lease-v1\x00"), hash...)
}
func validClosure(p successorReservation, v enrollmentRecord, q leaseApproval) bool {
	pin := p.Context.Candidate
	if q.Role == "peer" {
		pin = p.Context.Peer
	} else if q.Role != "candidate" {
		return false
	}
	key, e := hex.DecodeString(pin.Key)
	return e == nil && len(key) == 32 && len(q.Signature) == 64 && ed25519.Verify(key, closureFrame(v, q.Role), q.Signature)
}
func (s *Store) closureRequest(p successorReservation, v enrollmentRecord) (*leaseApproval, error) {
	var raw []byte
	if e := s.db.QueryRow("SELECT request FROM mls_successor_closures WHERE intent=?", p.Context.Intent).Scan(&raw); e != nil {
		if e == sql.ErrNoRows {
			e = ErrIntegrity
		}
		return nil, e
	}
	if raw == nil {
		return nil, nil
	}
	var q leaseApproval
	if len(raw) > 256 || json.Unmarshal(raw, &q) != nil {
		return nil, ErrIntegrity
	}
	canonical, _ := json.Marshal(q)
	if len(v.Approvals) != 2 || !bytes.Equal(raw, canonical) || !validClosure(p, v, q) {
		return nil, ErrIntegrity
	}
	return &q, nil
}
func (s *Store) successorClosure(p successorReservation) (closureStatus, error) {
	v, e := s.enrollmentState(p)
	if e != nil {
		return closureStatus{}, e
	}
	if len(v.Enrollment.Approvals) != 2 {
		return closureStatus{}, ErrForbidden
	}
	q, e := s.closureRequest(p, v.Enrollment)
	return closureStatus{1, v.Enrollment, v.Handshake, v.Confirmation, q}, e
}
func (s *Store) closeSuccessor(p successorReservation, actor, device string, q leaseApproval) (closureStatus, bool, error) {
	v, e := s.successorClosure(p)
	if e != nil {
		return v, false, e
	}
	pin := p.Context.Candidate
	if q.Role == "peer" {
		pin = p.Context.Peer
	}
	if actor != pin.Actor || device != pin.ID || !validClosure(p, v.Enrollment, q) {
		return v, false, ErrForbidden
	}
	// Either valid participant observes the same immutable first winner.
	if v.Closure != nil {
		return v, false, nil
	}
	raw, _ := json.Marshal(q)
	res, e := s.db.Exec("UPDATE mls_successor_closures SET request=? WHERE intent=? AND request IS NULL", raw, p.Context.Intent)
	if e != nil {
		return v, false, e
	}
	n, e := res.RowsAffected()
	if e != nil {
		return v, false, e
	}
	if n != 1 {
		return v, false, ErrConflict
	}
	v.Closure = &q
	return v, true, nil
}
func (a *API) successorClosureRoute(w http.ResponseWriter, r *http.Request, actor string, g *access.Grant, intent string) {
	if (r.Method != "GET" && r.Method != "POST") || r.URL.RawQuery != "" || r.URL.ForceQuery {
		fail(w, ErrInvalid)
		return
	}
	device, e := singleHeader(r, "X-Family-Device")
	if e != nil || !validID(device) {
		fail(w, ErrInvalid)
		return
	}
	var q leaseApproval
	if r.Method == "POST" {
		r.Body = http.MaxBytesReader(w, r.Body, 512)
		if !decodeMLS(w, r, &q, "role", "signature") {
			return
		}
	}
	a.store.mu.Lock()
	defer a.store.mu.Unlock()
	i, digest, e := g.ActivatedSuccessor(intent)
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
	if e != nil || !exists {
		if e == nil {
			e = ErrForbidden
		}
		fail(w, e)
		return
	}
	v, e := a.store.successorClosure(p)
	if e != nil {
		fail(w, e)
		return
	}
	raw, _ := json.Marshal(v.Enrollment)
	if digest != digestMLS(raw) {
		fail(w, ErrForbidden)
		return
	}
	created := false
	if r.Method == "POST" {
		v, created, e = a.store.closeSuccessor(p, actor, device, q)
	}
	if e != nil {
		fail(w, e)
		return
	}
	code := 200
	if created {
		code = 201
	}
	writeJSON(w, code, v)
}
