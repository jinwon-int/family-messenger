package chat

// Explicit target-scoped, expiring synthetic channel. This does not change
// Devices, reactivate tombstones, or admit the target through ordinary routes.
import (
	"bytes"
	"crypto/ed25519"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"github.com/jinwon-int/family-messenger/server/internal/access"
	"net/http"
	"sort"
	"time"
)

type leaseApproval struct {
	Role      string `json:"role"`
	Signature []byte `json:"signature"`
}
type successorLease struct {
	Version      int             `json:"version"`
	Reservation  string          `json:"reservation_id"`
	Context      string          `json:"context_sha256"`
	Handshake    string          `json:"handshake_sha256"`
	Confirmation string          `json:"confirmation_sha256"`
	Group        string          `json:"group_id"`
	Expires      int64           `json:"expires_at"`
	Phase        string          `json:"phase"`
	Approvals    []leaseApproval `json:"approvals"`
}
type leaseMessage struct {
	ID      string `json:"client_id"`
	Device  string `json:"device_id"`
	Payload []byte `json:"payload"`
}
type leaseEvent struct {
	Seq     int          `json:"seq"`
	Message leaseMessage `json:"message"`
	SHA     string       `json:"sha256"`
}

func migrateSuccessorLease(db *sql.DB, dir string, fresh bool) error {
	if !fresh {
		if e := snapshotSchema(db, dir, "v8-before-successor-lease-"); e != nil {
			return e
		}
	}
	_, e := db.Exec(`BEGIN IMMEDIATE;
 CREATE TABLE mls_successor_leases(intent TEXT PRIMARY KEY REFERENCES mls_successor_reservations(intent), approvals BLOB NOT NULL CHECK(length(approvals)<=512));
 INSERT INTO mls_successor_leases SELECT intent,CAST('[]' AS BLOB) FROM mls_successor_reservations;
 CREATE TABLE mls_successor_lease_events(intent TEXT NOT NULL REFERENCES mls_successor_leases(intent), seq INTEGER NOT NULL, device TEXT NOT NULL, client_id TEXT NOT NULL, message BLOB NOT NULL CHECK(length(message)<=8192), PRIMARY KEY(intent,seq), UNIQUE(intent,device,client_id));
 PRAGMA user_version=9; COMMIT;`)
	return e
}
func leaseFrame(v successorLease, role string) []byte {
	raw, _ := json.Marshal([]any{"family-successor-lease", 1, role, v.Reservation, v.Context, v.Handshake, v.Confirmation, v.Group, v.Expires})
	hash, _ := hex.DecodeString(digestMLS(raw))
	return append([]byte("family-successor-lease-v1\x00"), hash...)
}
func (s *Store) successorLease(p successorReservation) (successorLease, []byte, error) {
	raw, _ := json.Marshal(p.Context)
	v := successorLease{Version: 1, Reservation: p.ID, Context: digestMLS(raw), Expires: p.Context.ExpiresAt, Phase: "awaiting-pair"}
	h, _, e := s.successorHandshake(p)
	if e != nil {
		return v, nil, e
	}
	c, _, e := s.successorConfirmation(p)
	if e != nil {
		return v, nil, e
	}
	if h.Revision != 3 || c.Revision != 2 {
		return v, nil, ErrForbidden
	}
	raw, _ = json.Marshal(h)
	v.Handshake = digestMLS(raw)
	raw, _ = json.Marshal(c)
	v.Confirmation = digestMLS(raw)
	v.Group = h.Records[1].Request.Group
	if e = s.db.QueryRow("SELECT approvals FROM mls_successor_leases WHERE intent=?", p.Context.Intent).Scan(&raw); e != nil {
		if e == sql.ErrNoRows {
			e = ErrIntegrity
		}
		return v, nil, e
	}
	if len(raw) > 512 || json.Unmarshal(raw, &v.Approvals) != nil || v.Approvals == nil || len(v.Approvals) > 2 {
		return v, nil, ErrIntegrity
	}
	last := ""
	for _, q := range v.Approvals {
		if q.Role <= last || !validLeaseApproval(p, v, q) {
			return v, nil, ErrIntegrity
		}
		last = q.Role
	}
	canonical, _ := json.Marshal(v.Approvals)
	if !bytes.Equal(raw, canonical) {
		return v, nil, ErrIntegrity
	}
	if len(v.Approvals) == 2 {
		v.Phase = "leased"
	}
	return v, raw, nil
}
func validLeaseApproval(p successorReservation, v successorLease, q leaseApproval) bool {
	pin := p.Context.Candidate
	if q.Role == "peer" {
		pin = p.Context.Peer
	} else if q.Role != "candidate" {
		return false
	}
	key, e := hex.DecodeString(pin.Key)
	return e == nil && len(key) == 32 && len(q.Signature) == 64 && ed25519.Verify(key, leaseFrame(v, q.Role), q.Signature)
}
func (s *Store) approveLease(p successorReservation, actor, device string, q leaseApproval) (successorLease, bool, error) {
	v, prior, e := s.successorLease(p)
	if e != nil {
		return v, false, e
	}
	pin := p.Context.Candidate
	if q.Role == "peer" {
		pin = p.Context.Peer
	}
	if actor != pin.Actor || device != pin.ID || !validLeaseApproval(p, v, q) {
		return v, false, ErrForbidden
	}
	for _, old := range v.Approvals {
		if old.Role == q.Role {
			if !bytes.Equal(old.Signature, q.Signature) {
				return v, false, ErrConflict
			}
			return v, false, nil
		}
	}
	v.Approvals = append(v.Approvals, q)
	sort.Slice(v.Approvals, func(i, j int) bool { return v.Approvals[i].Role < v.Approvals[j].Role })
	next, _ := json.Marshal(v.Approvals)
	if time.Now().Unix() >= p.Context.ExpiresAt {
		return v, false, ErrForbidden
	}
	result, e := s.db.Exec("UPDATE mls_successor_leases SET approvals=? WHERE intent=? AND approvals=?", next, p.Context.Intent, prior)
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
	if len(v.Approvals) == 2 {
		v.Phase = "leased"
	}
	return v, true, nil
}
func (s *Store) leaseHistory(p successorReservation) ([]leaseEvent, error) {
	rows, e := s.db.Query("SELECT seq,device,client_id,message FROM mls_successor_lease_events WHERE intent=? ORDER BY seq LIMIT 65", p.Context.Intent)
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
func (s *Store) appendLeaseMessage(p successorReservation, q leaseMessage) (leaseEvent, bool, error) {
	events, e := s.leaseHistory(p)
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
	if time.Now().Unix() >= p.Context.ExpiresAt {
		return leaseEvent{}, false, ErrForbidden
	}
	seq := len(events) + 1
	_, e = s.db.Exec("INSERT INTO mls_successor_lease_events VALUES(?,?,?,?,?)", p.Context.Intent, seq, q.Device, q.ID, raw)
	return leaseEvent{seq, q, digestMLS(raw)}, e == nil, e
}
func (a *API) successorLeaseRoute(w http.ResponseWriter, r *http.Request, actor string, g *access.Grant, intent, action string) {
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
	var approval leaseApproval
	var message leaseMessage
	if r.Method == "POST" {
		if action == "lease" {
			if !decodeMLS(w, r, &approval, "role", "signature") {
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
	if e != nil || !exists {
		if e == nil {
			e = ErrForbidden
		}
		fail(w, e)
		return
	}
	retired, e := a.store.retirementRequest(p)
	if e != nil || retired != nil {
		if e == nil {
			e = ErrForbidden
		}
		fail(w, e)
		return
	}
	if action == "lease" {
		var v successorLease
		created := false
		if r.Method == "POST" {
			v, created, e = a.store.approveLease(p, actor, device, approval)
		} else {
			v, _, e = a.store.successorLease(p)
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
		return
	}
	v, _, e := a.store.successorLease(p)
	if e != nil || v.Phase != "leased" {
		if e == nil {
			e = ErrForbidden
		}
		fail(w, e)
		return
	}
	if r.Method == "GET" {
		out, e := a.store.leaseHistory(p)
		if e != nil {
			fail(w, e)
			return
		}
		writeJSON(w, 200, out)
	} else {
		out, created, e := a.store.appendLeaseMessage(p, message)
		if e != nil {
			fail(w, e)
			return
		}
		code := 200
		if created {
			code = 201
		}
		writeJSON(w, code, out)
	}
}

func (q *leaseApproval) UnmarshalJSON(raw []byte) error {
	type wire leaseApproval
	var v wire
	if e := json.Unmarshal(raw, &v); e != nil {
		return e
	}
	var f struct {
		Signature json.RawMessage `json:"signature"`
	}
	if e := json.Unmarshal(raw, &f); e != nil {
		return e
	}
	var text string
	if len(f.Signature) == 0 || f.Signature[0] != '"' || json.Unmarshal(f.Signature, &text) != nil || base64.StdEncoding.EncodeToString(v.Signature) != text {
		return ErrInvalid
	}
	*q = leaseApproval(v)
	return nil
}
func (q *leaseMessage) UnmarshalJSON(raw []byte) error {
	type wire leaseMessage
	var v wire
	if e := json.Unmarshal(raw, &v); e != nil {
		return e
	}
	var f struct {
		Payload json.RawMessage `json:"payload"`
	}
	if e := json.Unmarshal(raw, &f); e != nil {
		return e
	}
	var text string
	if len(f.Payload) == 0 || f.Payload[0] != '"' || json.Unmarshal(f.Payload, &text) != nil || base64.StdEncoding.EncodeToString(v.Payload) != text {
		return ErrInvalid
	}
	*q = leaseMessage(v)
	return nil
}
