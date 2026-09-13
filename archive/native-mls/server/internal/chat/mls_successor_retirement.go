package chat

// Permanent target-only closure. No device enrollment, policy mutation or key
// deletion: one participant can retire a channel; nobody can reopen it.
import (
	"bytes"
	"crypto/ed25519"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"github.com/jinwon-int/family-messenger/server/internal/access"
	"net/http"
	"time"
)

type successorRetirement struct {
	Version      int                `json:"version"`
	Lease        successorLease     `json:"lease"`
	Handshake    successorHandshake `json:"handshake"`
	Confirmation successorHandshake `json:"confirmation"`
	Retirement   *leaseApproval     `json:"retirement"`
}

func migrateSuccessorRetirement(db *sql.DB, dir string, fresh bool) error {
	if !fresh {
		if e := snapshotSchema(db, dir, "v9-before-successor-retirement-"); e != nil {
			return e
		}
	}
	_, e := db.Exec(`BEGIN IMMEDIATE;
 CREATE TABLE mls_successor_retirements(intent TEXT PRIMARY KEY REFERENCES mls_successor_leases(intent), request BLOB CHECK(request IS NULL OR length(request)<=256));
 INSERT INTO mls_successor_retirements SELECT intent,NULL FROM mls_successor_leases;
 PRAGMA user_version=10; COMMIT;`)
	return e
}

// Distinct semantic domain inside the existing dedicated lease signer. Lease
// approvals cannot verify here, nor can retirement verify as a lease approval.
func retirementFrame(v successorLease, role string) []byte {
	raw, _ := json.Marshal([]any{"family-successor-retirement", 1, role, v.Reservation, v.Context, v.Handshake, v.Confirmation, v.Group, v.Expires})
	hash, _ := hex.DecodeString(digestMLS(raw))
	return append([]byte("family-successor-lease-v1\x00"), hash...)
}
func validRetirement(p successorReservation, v successorLease, q leaseApproval) bool {
	pin := p.Context.Candidate
	if q.Role == "peer" {
		pin = p.Context.Peer
	} else if q.Role != "candidate" {
		return false
	}
	key, e := hex.DecodeString(pin.Key)
	return e == nil && len(key) == 32 && len(q.Signature) == 64 && ed25519.Verify(key, retirementFrame(v, q.Role), q.Signature)
}
func (s *Store) retirementRequest(p successorReservation) (*leaseApproval, error) {
	var raw []byte
	if e := s.db.QueryRow("SELECT request FROM mls_successor_retirements WHERE intent=?", p.Context.Intent).Scan(&raw); e != nil {
		if e == sql.ErrNoRows {
			return nil, ErrIntegrity
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
	v, _, e := s.successorLease(p)
	if e != nil {
		return nil, e
	}
	if !bytes.Equal(raw, canonical) || v.Phase != "leased" || !validRetirement(p, v, q) {
		return nil, ErrIntegrity
	}
	return &q, nil
}
func (s *Store) successorRetirement(p successorReservation) (successorRetirement, error) {
	v := successorRetirement{Version: 1}
	var e error
	v.Lease, _, e = s.successorLease(p)
	if e != nil {
		return v, e
	}
	if v.Lease.Phase != "leased" {
		return v, ErrForbidden
	}
	v.Handshake, _, e = s.successorHandshake(p)
	if e != nil {
		return v, e
	}
	v.Confirmation, _, e = s.successorConfirmation(p)
	if e != nil {
		return v, e
	}
	v.Retirement, e = s.retirementRequest(p)
	return v, e
}
func (s *Store) retireSuccessor(p successorReservation, actor, device string, q leaseApproval) (successorRetirement, bool, error) {
	v, e := s.successorRetirement(p)
	if e != nil {
		return v, false, e
	}
	pin := p.Context.Candidate
	if q.Role == "peer" {
		pin = p.Context.Peer
	}
	if actor != pin.Actor || device != pin.ID || !validRetirement(p, v.Lease, q) {
		return v, false, ErrForbidden
	}
	// A valid other-participant retry observes the original immutable winner.
	if v.Retirement != nil {
		return v, false, nil
	}
	if time.Now().Unix() >= p.Context.ExpiresAt {
		return v, false, ErrForbidden
	}
	raw, _ := json.Marshal(q)
	res, e := s.db.Exec("UPDATE mls_successor_retirements SET request=? WHERE intent=? AND request IS NULL", raw, p.Context.Intent)
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
	v.Retirement = &q
	return v, true, nil
}
func (a *API) successorRetirementRoute(w http.ResponseWriter, r *http.Request, actor string, g *access.Grant, intent string) {
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
	var i access.SuccessorIntent
	if r.Method == "GET" {
		i, e = g.SuccessorRetirementHistory(intent)
	} else {
		i, e = g.AcceptedSuccessor(intent)
	}
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
	var v successorRetirement
	created := false
	if r.Method == "POST" {
		v, created, e = a.store.retireSuccessor(p, actor, device, q)
	} else {
		v, e = a.store.successorRetirement(p)
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
