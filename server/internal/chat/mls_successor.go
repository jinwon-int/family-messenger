package chat

// Read-only replacement preflight. This never grants native delivery permission,
// creates a room, changes a pin or restores an old sender.
import (
	"bytes"
	"encoding/json"
	"net/http"

	"github.com/jinwon-int/family-messenger/server/internal/access"
)

type successorContext struct {
	Version          int    `json:"version"`
	Intent           string `json:"intent_id"`
	DecisionRevision uint64 `json:"decision_revision"`
	ExpiresAt        int64  `json:"expires_at"`
	Source           string `json:"source_room"`
	Group            string `json:"source_group"`
	Target           string `json:"target_room"`
	Predecessor      MLSPin `json:"predecessor"`
	Candidate        MLSPin `json:"candidate"`
	Peer             MLSPin `json:"peer"`
	Fingerprint      string `json:"candidate_fingerprint"`
	Package          string `json:"package_sha256"`
	Admission        string `json:"admission"`
}

// Caller holds Grant.Run -> Store.mu. The single Store lock also guards every
// room reservation/bind; the response is an observation, NOT a lasting lease.
func (s *Store) successorContext(i access.SuccessorIntent, actor, device string, devices []access.Device) (successorContext, error) {
	deny := successorContext{}
	source, e := s.mlsRoom(i.PreviousRoom)
	if e != nil {
		return deny, e
	}
	if source.Group != i.PreviousGroup {
		return deny, ErrForbidden
	}
	// Only a completed fixed-pair handshake is qualified in this unit. Pending
	// local applications/updates do not change this row; an accepted unacked
	// update intentionally denies preflight until separately qualified.
	if source.Phase != "ready" {
		return deny, ErrForbidden
	}
	if len(source.Pins) != 2 || source.Pins[0].ID >= source.Pins[1].ID || source.Pins[0].Actor == source.Pins[1].Actor || source.Epoch < 1 || source.Epoch > MLSMaxRoomEvents || source.Revision != 2*source.Epoch+1 || source.Next <= source.Revision || source.Next > MLSMaxRoomEvents+1 {
		return deny, ErrIntegrity
	}
	var raw []byte
	if e = s.db.QueryRow("SELECT pins FROM mls_rooms WHERE room=?", source.Room).Scan(&raw); e != nil {
		return deny, e
	}
	canonical, _ := json.Marshal(source.Pins)
	if !bytes.Equal(raw, canonical) {
		return deny, ErrIntegrity
	}
	if !((source.Creator == source.Pins[0].ID && source.Peer == source.Pins[1].ID) || (source.Creator == source.Pins[1].ID && source.Peer == source.Pins[0].ID)) {
		return deny, ErrIntegrity
	}
	predecessor := MLSPin{i.Predecessor, i.Actor, i.PredecessorKey, i.PredecessorRevision}
	var peer MLSPin
	switch {
	case source.Pins[0] == predecessor:
		peer = source.Pins[1]
	case source.Pins[1] == predecessor:
		peer = source.Pins[0]
	default:
		return deny, ErrForbidden
	}
	retired := false
	for _, d := range devices {
		if d.ID == i.Predecessor && d.Actor == i.Actor && d.Subject == i.Subject && d.SigningKey == i.PredecessorKey && d.Status == "revoked" && d.Revision == 2 {
			retired = true
		}
		if d.ID == i.Candidate || d.SigningKey == i.SigningKey {
			return deny, ErrForbidden
		}
	}
	currentPeer, e := activePin(devices, peer.ID)
	if !retired || e != nil || currentPeer != peer {
		return deny, ErrForbidden
	}
	if !((actor == i.Actor && device == i.Candidate) || (actor == peer.Actor && device == peer.ID)) {
		return deny, ErrForbidden
	}
	var members int
	if e = s.db.QueryRow("SELECT count(*) FROM members WHERE room=?", source.Room).Scan(&members); e != nil {
		return deny, e
	}
	if members != 2 {
		return deny, ErrForbidden
	}
	for _, p := range source.Pins {
		if e = s.member(source.Room, p.Actor); e != nil {
			return deny, e
		}
	}
	return successorContext{1, i.ID, i.DecisionRevision, i.ExpiresAt, source.Room, source.Group, i.NextRoom, predecessor, MLSPin{i.Candidate, i.Actor, i.SigningKey, 1}, peer, i.Fingerprint, i.PackageSHA256, "preflight-only"}, nil
}

func (s *Store) successorTargetUnused(room string) error {
	var occupied int
	if e := s.db.QueryRow("SELECT count(*) FROM rooms WHERE id=?", room).Scan(&occupied); e != nil {
		return e
	}
	if occupied != 0 {
		return ErrConflict
	}
	return nil
}

func (a *API) successorContextRoute(w http.ResponseWriter, r *http.Request, actor string, g *access.Grant, parts []string) {
	if len(parts) == 5 && validID(parts[3]) && (parts[4] == "enrollment" || parts[4] == "enrolled-channel") {
		a.successorEnrollmentRoute(w, r, actor, g, parts[3], parts[4])
		return
	}
	if len(parts) == 5 && validID(parts[3]) && parts[4] == "retirement" {
		a.successorRetirementRoute(w, r, actor, g, parts[3])
		return
	}
	if len(parts) == 5 && validID(parts[3]) && (parts[4] == "lease" || parts[4] == "channel") {
		a.successorLeaseRoute(w, r, actor, g, parts[3], parts[4])
		return
	}
	if len(parts) == 5 && validID(parts[3]) && parts[4] == "confirmation" {
		a.successorConfirmationRoute(w, r, actor, g, parts[3])
		return
	}
	if len(parts) == 5 && validID(parts[3]) && parts[4] == "handshake" {
		a.successorHandshakeRoute(w, r, actor, g, parts[3])
		return
	}
	if len(parts) == 5 && validID(parts[3]) && parts[4] == "custody" {
		a.successorCustodyRoute(w, r, actor, g, parts[3])
		return
	}
	if len(parts) == 5 && validID(parts[3]) && parts[4] == "reservation" {
		a.successorReservationRoute(w, r, actor, g, parts[3])
		return
	}
	if len(parts) != 5 || !validID(parts[3]) || parts[4] != "context" {
		http.NotFound(w, r)
		return
	}
	if r.Method != "GET" || r.URL.RawQuery != "" || r.URL.ForceQuery {
		fail(w, ErrInvalid)
		return
	}
	device, e := singleHeader(r, "X-Family-Device")
	if e != nil || !validID(device) {
		fail(w, ErrInvalid)
		return
	}
	a.store.mu.Lock()
	defer a.store.mu.Unlock()
	i, e := g.AcceptedSuccessor(parts[3])
	if e != nil {
		fail(w, ErrForbidden)
		return
	}
	context, e := a.store.successorContext(i, actor, device, g.DeviceBindings())
	if e == nil {
		e = a.store.successorTargetUnused(context.Target)
	}
	if e != nil {
		fail(w, e)
		return
	}
	writeJSON(w, http.StatusOK, context)
}
