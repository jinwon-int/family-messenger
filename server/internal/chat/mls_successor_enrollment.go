package chat

// Persistent enrollment is confined to an unused successor target. Two fresh
// signed consents and a separate current administrator policy digest are required.
import (
	"bytes"
	"crypto/ed25519"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"github.com/jinwon-int/family-messenger/server/internal/access"
	"net/http"
	"sort"
	"time"
)

type enrollmentRecord struct {
	Version   int             `json:"version"`
	Lease     successorLease  `json:"lease"`
	Approvals []leaseApproval `json:"approvals"`
}
type enrollmentStatus struct {
	Version      int                `json:"version"`
	Enrollment   enrollmentRecord   `json:"enrollment"`
	Handshake    successorHandshake `json:"handshake"`
	Confirmation successorHandshake `json:"confirmation"`
	Active       bool               `json:"active"`
}

func migrateSuccessorEnrollment(db *sql.DB, dir string, fresh bool) error {
	if !fresh {
		if e := snapshotSchema(db, dir, "v10-before-successor-enrollment-"); e != nil {
			return e
		}
	}
	_, e := db.Exec(`BEGIN IMMEDIATE;
 CREATE TABLE mls_successor_enrollments(intent TEXT PRIMARY KEY REFERENCES mls_successor_leases(intent), approvals BLOB NOT NULL CHECK(length(approvals)<=512));
 INSERT INTO mls_successor_enrollments SELECT intent,CAST('[]' AS BLOB) FROM mls_successor_leases;
 CREATE TABLE mls_successor_enrolled_events(intent TEXT NOT NULL REFERENCES mls_successor_enrollments(intent), seq INTEGER NOT NULL, device TEXT NOT NULL, client_id TEXT NOT NULL, message BLOB NOT NULL CHECK(length(message)<=8192), PRIMARY KEY(intent,seq), UNIQUE(intent,device,client_id));
 PRAGMA user_version=11;COMMIT;`)
	return e
}
func enrollmentFrame(v successorLease, role string) []byte {
	raw, _ := json.Marshal([]any{"family-successor-enrollment", 1, "persistent-unused-target", role, v.Reservation, v.Context, v.Handshake, v.Confirmation, v.Group, v.Expires})
	hash, _ := hex.DecodeString(digestMLS(raw))
	return append([]byte("family-successor-lease-v1\x00"), hash...)
}
func validEnrollment(p successorReservation, v successorLease, q leaseApproval) bool {
	pin := p.Context.Candidate
	if q.Role == "peer" {
		pin = p.Context.Peer
	} else if q.Role != "candidate" {
		return false
	}
	key, e := hex.DecodeString(pin.Key)
	return e == nil && len(key) == 32 && len(q.Signature) == 64 && ed25519.Verify(key, enrollmentFrame(v, q.Role), q.Signature)
}
func (s *Store) enrollmentApprovals(p successorReservation) ([]leaseApproval, error) {
	var raw []byte
	if e := s.db.QueryRow("SELECT approvals FROM mls_successor_enrollments WHERE intent=?", p.Context.Intent).Scan(&raw); e != nil {
		if e == sql.ErrNoRows {
			e = ErrIntegrity
		}
		return nil, e
	}
	var qs []leaseApproval
	if len(raw) > 512 || json.Unmarshal(raw, &qs) != nil || qs == nil || len(qs) > 2 {
		return nil, ErrIntegrity
	}
	if len(qs) > 0 {
		v, _, e := s.successorLease(p)
		if e != nil {
			return nil, e
		}
		last := ""
		for _, q := range qs {
			if q.Role <= last || !validEnrollment(p, v, q) {
				return nil, ErrIntegrity
			}
			last = q.Role
		}
	}
	canonical, _ := json.Marshal(qs)
	if !bytes.Equal(raw, canonical) {
		return nil, ErrIntegrity
	}
	return qs, nil
}
func (s *Store) enrollmentStatus(p successorReservation) (enrollmentStatus, error) {
	var out enrollmentStatus
	v, _, e := s.successorLease(p)
	if e != nil {
		return out, e
	}
	if v.Phase != "leased" {
		return out, ErrForbidden
	}
	retired, e := s.retirementRequest(p)
	if e != nil {
		return out, e
	}
	if retired != nil {
		return out, ErrForbidden
	}
	old, e := s.leaseHistory(p)
	if e != nil {
		return out, e
	}
	if len(old) != 0 {
		return out, ErrForbidden
	}
	qs, e := s.enrollmentApprovals(p)
	if e != nil {
		return out, e
	}
	h, _, e := s.successorHandshake(p)
	if e != nil {
		return out, e
	}
	c, _, e := s.successorConfirmation(p)
	if e != nil {
		return out, e
	}
	return enrollmentStatus{1, enrollmentRecord{1, v, qs}, h, c, false}, nil
}
func (s *Store) approveEnrollment(p successorReservation, actor, device string, q leaseApproval) (enrollmentStatus, bool, error) {
	out, e := s.enrollmentStatus(p)
	if e != nil {
		return out, false, e
	}
	pin := p.Context.Candidate
	if q.Role == "peer" {
		pin = p.Context.Peer
	}
	if actor != pin.Actor || device != pin.ID || !validEnrollment(p, out.Enrollment.Lease, q) {
		return out, false, ErrForbidden
	}
	for _, old := range out.Enrollment.Approvals {
		if old.Role == q.Role {
			if !bytes.Equal(old.Signature, q.Signature) {
				return out, false, ErrConflict
			}
			return out, false, nil
		}
	}
	if time.Now().Unix() >= p.Context.ExpiresAt {
		return out, false, ErrForbidden
	}
	out.Enrollment.Approvals = append(out.Enrollment.Approvals, q)
	sort.Slice(out.Enrollment.Approvals, func(i, j int) bool { return out.Enrollment.Approvals[i].Role < out.Enrollment.Approvals[j].Role })
	raw, _ := json.Marshal(out.Enrollment.Approvals)
	_, e = s.db.Exec("UPDATE mls_successor_enrollments SET approvals=? WHERE intent=?", raw, p.Context.Intent)
	return out, e == nil, e
}
func (a *API) successorEnrollmentRoute(w http.ResponseWriter, r *http.Request, actor string, g *access.Grant, intent, action string) {
	if (r.Method != "GET" && r.Method != "POST") || r.URL.RawQuery != "" || r.URL.ForceQuery {
		fail(w, ErrInvalid)
		return
	}
	device, e := singleHeader(r, "X-Family-Device")
	if e != nil || !validID(device) {
		fail(w, ErrInvalid)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 8192)
	var q leaseApproval
	var message leaseMessage
	if r.Method == "POST" {
		if action == "enrollment" {
			if !decodeMLS(w, r, &q, "role", "signature") {
				return
			}
		} else {
			if !decodeMLS(w, r, &message, "client_id", "device_id", "payload") {
				return
			}
			if message.Device != device {
				fail(w, ErrForbidden)
				return
			}
		}
	}
	a.store.mu.Lock()
	defer a.store.mu.Unlock()
	if g.ActivationRevoked(intent) {
		fail(w, ErrForbidden)
		return
	}
	i, digest, e := g.ActivatedSuccessor(intent)
	if e != nil {
		i, e = g.AcceptedSuccessor(intent)
		digest = ""
	}
	if e != nil {
		fail(w, ErrForbidden)
		return
	}
	context, e := a.store.successorContext(i, actor, device, g.DeviceBindings())
	if e != nil {
		fail(w, e)
		return
	}
	p, exists, e := a.store.successorReservation(context)
	if e != nil || !exists {
		if e == nil {
			e = ErrForbidden
		}
		fail(w, e)
		return
	}
	out, e := a.store.enrollmentStatus(p)
	if e != nil {
		fail(w, e)
		return
	}
	active := func(v enrollmentStatus) bool {
		raw, _ := json.Marshal(v.Enrollment)
		return len(v.Enrollment.Approvals) == 2 && digest != "" && digest == digestMLS(raw)
	}
	if action == "enrollment" {
		created := false
		if r.Method == "POST" {
			if time.Now().Unix() >= i.ExpiresAt {
				fail(w, ErrForbidden)
				return
			}
			out, created, e = a.store.approveEnrollment(p, actor, device, q)
		}
		if e != nil {
			fail(w, e)
			return
		}
		out.Active = active(out)
		code := 200
		if created {
			code = 201
		}
		writeJSON(w, code, out)
		return
	}
	if !active(out) {
		fail(w, ErrForbidden)
		return
	}
	if r.Method == "GET" {
		events, e := a.store.enrolledHistory(p)
		if e != nil {
			fail(w, e)
			return
		}
		writeJSON(w, 200, events)
	} else {
		ev, created, e := a.store.appendEnrolledMessage(p, message)
		if e != nil {
			fail(w, e)
			return
		}
		code := 200
		if created {
			code = 201
		}
		writeJSON(w, code, ev)
	}
}
func (s *Store) enrolledHistory(p successorReservation) ([]leaseEvent, error) {
	rows, e := s.db.Query("SELECT seq,device,client_id,message FROM mls_successor_enrolled_events WHERE intent=? ORDER BY seq LIMIT 65", p.Context.Intent)
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	out := []leaseEvent{}
	for rows.Next() {
		var ev leaseEvent
		var dev, id string
		var raw []byte
		if e = rows.Scan(&ev.Seq, &dev, &id, &raw); e != nil {
			return nil, e
		}
		if len(raw) > 8192 || json.Unmarshal(raw, &ev.Message) != nil {
			return nil, ErrIntegrity
		}
		q := ev.Message
		canonical, _ := json.Marshal(q)
		if ev.Seq != len(out)+1 || ev.Seq > 64 || q.Device != dev || q.ID != id || !validID(id) || len(q.Payload) < 1 || len(q.Payload) > 4096 || !bytes.Equal(raw, canonical) || (dev != p.Context.Candidate.ID && dev != p.Context.Peer.ID) {
			return nil, ErrIntegrity
		}
		ev.SHA = digestMLS(raw)
		out = append(out, ev)
	}
	return out, rows.Err()
}
func (s *Store) appendEnrolledMessage(p successorReservation, q leaseMessage) (leaseEvent, bool, error) {
	events, e := s.enrolledHistory(p)
	if e != nil {
		return leaseEvent{}, false, e
	}
	if !validID(q.ID) || len(q.Payload) < 1 || len(q.Payload) > 4096 {
		return leaseEvent{}, false, ErrInvalid
	}
	raw, _ := json.Marshal(q)
	for _, ev := range events {
		if ev.Message.Device == q.Device && ev.Message.ID == q.ID {
			prior, _ := json.Marshal(ev.Message)
			if !bytes.Equal(raw, prior) {
				return ev, false, ErrConflict
			}
			return ev, false, nil
		}
	}
	if len(events) >= 64 {
		return leaseEvent{}, false, ErrLimit
	}
	seq := len(events) + 1
	_, e = s.db.Exec("INSERT INTO mls_successor_enrolled_events VALUES(?,?,?,?,?)", p.Context.Intent, seq, q.Device, q.ID, raw)
	return leaseEvent{seq, q, digestMLS(raw)}, e == nil, e
}
