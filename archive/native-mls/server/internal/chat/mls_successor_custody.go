package chat

// Public per-role declarations only. A pair of declarations neither proves
// private storage nor activates a candidate, target group or native sender.
import (
	"bytes"
	"database/sql"
	"encoding/json"
	"net/http"
	"sort"

	"github.com/jinwon-int/family-messenger/server/internal/access"
)

type successorDeclaration struct {
	Role        string `json:"role"`
	ID          string `json:"declaration_id"`
	Device      string `json:"device_id"`
	Reservation string `json:"reservation_id"`
	ContextSHA  string `json:"context_sha256"`
}
type successorCustody struct {
	Version      int                    `json:"version"`
	Reservation  string                 `json:"reservation_id"`
	ContextSHA   string                 `json:"context_sha256"`
	Revision     int                    `json:"revision"`
	Phase        string                 `json:"phase"`
	Declarations []successorDeclaration `json:"declarations"`
}
type successorDeclarationRequest struct {
	Reservation string `json:"reservation_id"`
	ContextSHA  string `json:"context_sha256"`
	Role        string `json:"role"`
	ID          string `json:"declaration_id"`
}

func migrateSuccessorCustody(db *sql.DB, dir string, fresh bool) error {
	if !fresh {
		if e := snapshotSchema(db, dir, "v5-before-successor-custody-"); e != nil {
			return e
		}
	}
	_, e := db.Exec(`BEGIN IMMEDIATE;
 CREATE TABLE mls_successor_custody(intent TEXT PRIMARY KEY REFERENCES mls_successor_reservations(intent), declarations BLOB NOT NULL CHECK(length(declarations)<=1024));
 INSERT INTO mls_successor_custody SELECT intent, CAST('[]' AS BLOB) FROM mls_successor_reservations;
 PRAGMA user_version=6; COMMIT;`)
	return e
}

// Caller holds Grant.Run -> Store.mu and has validated the immutable reservation
// and empty target. Never infer an empty declaration slot from a missing row.
func (s *Store) successorCustody(p successorReservation) (successorCustody, []byte, error) {
	context, _ := json.Marshal(p.Context)
	v := successorCustody{Version: 1, Reservation: p.ID, ContextSHA: digestMLS(context), Phase: "custody-pending"}
	var raw []byte
	if e := s.db.QueryRow("SELECT declarations FROM mls_successor_custody WHERE intent=?", p.Context.Intent).Scan(&raw); e != nil {
		if e == sql.ErrNoRows {
			e = ErrIntegrity
		}
		return v, nil, e
	}
	if len(raw) > 1024 || json.Unmarshal(raw, &v.Declarations) != nil || v.Declarations == nil || len(v.Declarations) > 2 {
		return v, nil, ErrIntegrity
	}
	last := ""
	for _, d := range v.Declarations {
		pin := p.Context.Candidate
		if d.Role == "peer" {
			pin = p.Context.Peer
		} else if d.Role != "candidate" {
			return v, nil, ErrIntegrity
		}
		if d.Role <= last || !validID(d.ID) || d.Device != pin.ID || d.Reservation != p.ID || d.ContextSHA != v.ContextSHA {
			return v, nil, ErrIntegrity
		}
		last = d.Role
	}
	canonical, _ := json.Marshal(v.Declarations)
	if !bytes.Equal(raw, canonical) {
		return v, nil, ErrIntegrity
	}
	v.Revision = len(v.Declarations)
	if v.Revision == 2 {
		v.Phase = "pair-declared-inactive"
	}
	return v, raw, nil
}

// Context CAS binds both public keys, candidate package hash, policy decision,
// target and intent. Each role has its own immutable empty->declared slot. The
// two roles can race without retrying with a new ID or overwriting each other.
func (s *Store) declareSuccessor(p successorReservation, actor, device string, q successorDeclarationRequest) (successorCustody, bool, error) {
	v, prior, e := s.successorCustody(p)
	if e != nil {
		return v, false, e
	}
	if !validID(q.ID) || (q.Role != "candidate" && q.Role != "peer") {
		return v, false, ErrInvalid
	}
	pin := p.Context.Candidate
	if q.Role == "peer" {
		pin = p.Context.Peer
	}
	if actor != pin.Actor || device != pin.ID {
		return v, false, ErrForbidden
	}
	if q.Reservation != p.ID || q.ContextSHA != v.ContextSHA {
		return v, false, ErrConflict
	}
	for _, d := range v.Declarations {
		if d.Role == q.Role {
			if d.ID != q.ID {
				return v, false, ErrConflict
			}
			return v, false, nil
		}
	}
	v.Declarations = append(v.Declarations, successorDeclaration{q.Role, q.ID, device, p.ID, v.ContextSHA})
	sort.Slice(v.Declarations, func(i, j int) bool { return v.Declarations[i].Role < v.Declarations[j].Role })
	next, _ := json.Marshal(v.Declarations)
	result, e := s.db.Exec("UPDATE mls_successor_custody SET declarations=? WHERE intent=? AND declarations=?", next, p.Context.Intent, prior)
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
	v.Revision = len(v.Declarations)
	if v.Revision == 2 {
		v.Phase = "pair-declared-inactive"
	}
	return v, true, nil
}

func (a *API) successorCustodyRoute(w http.ResponseWriter, r *http.Request, actor string, g *access.Grant, intent string) {
	if (r.Method != "GET" && r.Method != "POST") || r.URL.RawQuery != "" || r.URL.ForceQuery {
		fail(w, ErrInvalid)
		return
	}
	device, e := singleHeader(r, "X-Family-Device")
	if e != nil || !validID(device) {
		fail(w, ErrInvalid)
		return
	}
	var q successorDeclarationRequest
	r.Body = http.MaxBytesReader(w, r.Body, 1024)
	if r.Method == "POST" && !decodeMLS(w, r, &q, "reservation_id", "context_sha256", "role", "declaration_id") {
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
	var v successorCustody
	code := 200
	if r.Method == "POST" {
		var created bool
		v, created, e = a.store.declareSuccessor(p, actor, device, q)
		if created {
			code = 201
		}
	} else {
		v, _, e = a.store.successorCustody(p)
	}
	if e != nil {
		fail(w, e)
		return
	}
	writeJSON(w, code, v)
}
